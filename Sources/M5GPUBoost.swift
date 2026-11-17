import AppKit
import CoreGraphics
import IOKit.ps
import Metal
import SwiftUI

enum BoostActivity: Equatable {
    case scroll
    case drag
    case transition
    /// Pointer movement with no button held. Only "While in use" acts on it,
    /// so the GPU is already at speed by the time a drag or scroll begins.
    case pointer

    var label: String {
        switch self {
        case .scroll: return "scrolling"
        case .drag: return "dragging"
        case .transition: return "UI activity"
        case .pointer: return "moving the pointer"
        }
    }
}

enum BoostMode: String, CaseIterable, Identifiable {
    case off
    case onScroll = "on_scroll"
    case onInteraction = "on_interaction"
    case whileInUse = "while_in_use"
    case alwaysDocked = "always_docked"
    case whileDocked = "while_docked"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .onScroll: return "On scroll"
        case .onInteraction: return "On activity"
        case .whileInUse: return "While in use (pointer movement too)"
        case .alwaysDocked: return "Always while docked (video too, highest cost)"
        case .whileDocked: return "All-motion test (60 seconds)"
        }
    }

    func allows(_ activity: BoostActivity) -> Bool {
        switch self {
        case .off, .whileDocked, .alwaysDocked: return false
        case .onScroll: return activity == .scroll
        case .onInteraction: return activity != .pointer
        case .whileInUse: return true
        }
    }

    /// How long boosting continues after the last accepted activity.
    var tailSeconds: Double { self == .whileInUse ? 2.0 : 0.9 }

    var monitorsPointerMovement: Bool { self == .whileInUse }

    static func restored(from value: String?) -> BoostMode {
        // A timed diagnostic must never become an always-on login setting.
        if value == "while_docked" { return .onInteraction }
        if let value, let mode = Self(rawValue: value) { return mode }
        if value == "Scroll & drag" { return .onInteraction }
        // Retired modes, including Continuous, use activity-triggered work.
        return allCases.first(where: { $0 != .whileDocked && $0.label == value }) ?? .onInteraction
    }
}

enum BoostStrength: String, CaseIterable, Identifiable {
    case gentle
    case balanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: return "Gentle"
        case .balanced: return "Balanced"
        }
    }

    static func restored(from value: String?) -> BoostStrength {
        if let value, let strength = Self(rawValue: value) { return strength }
        switch value {
        case "Gentle", "Gentle [blit 4B, 3-deep]": return .gentle
        case "Balanced", "Balanced [sin/cos 4K, 3-deep]": return .balanced
        case "strong", "Strong": return .balanced
        default: return .gentle
        }
    }

    var threadCount: Int {
        switch self {
        case .gentle: return 4_096
        case .balanced: return 8_192
        }
    }

    var iterations: UInt32 {
        switch self {
        case .gentle: return 64
        case .balanced: return 128
        }
    }

    var queuedBufferCount: Int {
        switch self {
        case .gentle, .balanced: return 3
        }
    }

    /// Gentle submits a four-byte blit; Balanced uses compute.
    /// All profiles retain three queued buffers with no sleep between
    /// submissions. Earlier compute-based Gentle measurements do not
    /// validate this experimental blit profile.
    var isBlit: Bool {
        switch self {
        case .gentle: return true
        case .balanced: return false
        }
    }
}

private struct DisplayInfo {
    let id: CGDirectDisplayID
    let isBuiltin: Bool
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var isTarget: Bool {
        guard !isBuiltin else { return false }

        // Include 5120x2160 ultrawides and their intermediate HiDPI modes.
        let isFiveK = pixelWidth >= 5_000 && pixelHeight >= 2_000
        let isHighRefresh = refreshRate >= 100
        let isStudioDisplayXDR = name.localizedCaseInsensitiveContains("Studio Display XDR")

        // Some adaptive modes report 0 Hz through CoreGraphics. Keep the exact
        // Studio Display XDR name as a fallback, while requiring 5K dimensions.
        return isFiveK && (isHighRefresh || (refreshRate == 0 && isStudioDisplayXDR))
    }

    var summary: String {
        let rate = refreshRate > 0 ? String(format: "%.0f Hz", refreshRate) : "adaptive rate"
        return "\(name): \(pixelWidth)×\(pixelHeight), \(rate)"
    }
}

private struct BoostLease {
    private(set) var deadline: UInt64 = 0

    mutating func renew(at now: UInt64) {
        deadline = now + 3_000_000_000
    }

    func isValid(at now: UInt64) -> Bool { now < deadline }
}

private struct BoostEnvironment {
    let mode: BoostMode
    let screensAreAwake: Bool
    let screenIsLocked: Bool
    let usingACPower: Bool
    let thermalState: ProcessInfo.ThermalState
    let hasTargetDisplay: Bool

    var pauseReason: String? {
        if mode == .off { return "Off" }
        if !screensAreAwake { return "Paused while displays sleep" }
        if screenIsLocked { return "Paused while the screen is locked" }
        if !usingACPower { return "Paused while running on battery" }
        switch thermalState {
        case .serious, .critical: return "Paused because of thermal pressure"
        case .nominal, .fair: break
        @unknown default: return "Paused because thermal state is unknown"
        }
        if !hasTargetDisplay { return "No external 5K/5K2K high-refresh display detected" }
        return nil
    }
}

private enum MetalBoostError: LocalizedError {
    case noDevice
    case noQueue
    case shaderCompilation(String)
    case noFunction
    case noBuffer

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "Metal is unavailable."
        case .noQueue:
            return "The Metal command queue could not be created."
        case .shaderCompilation(let message):
            return "The Metal shader could not be compiled: \(message)"
        case .noFunction:
            return "The Metal keep-alive function is missing."
        case .noBuffer:
            return "The Metal work buffer could not be allocated."
        }
    }
}

/// Controller-facing routing stays on the main thread; each backend serializes
/// its own GPU state. Keep the known-working backend for Balanced and fallback.
private final class MetalBoostEngine {
    private let legacy: LegacyMetalBoostEngine
    private let reusable: ReusableBlitEngine?
    private var requestedActive = false

    var backendDescription: String {
        reusable == nil ? "original Metal" : "Metal 4 reusable Gentle; original Balanced"
    }

    init(useReusableBlits: Bool = true) throws {
        legacy = try LegacyMetalBoostEngine()
        reusable = useReusableBlits ? try? ReusableBlitEngine() : nil
    }

    func setTelemetryHandler(_ handler: @escaping (Double) -> Void) {
        legacy.setTelemetryHandler(handler)
        reusable?.setTelemetryHandler(handler)
    }

    func setFailureHandler(_ handler: @escaping (String) -> Void) {
        reusable?.setFailureHandler(handler)
    }

    func start(strength: BoostStrength) {
        requestedActive = true
        if strength.isBlit, let reusable {
            legacy.stop()
            reusable.start()
        } else {
            reusable?.stop()
            legacy.start(strength: strength)
        }
    }

    func updateStrength(_ strength: BoostStrength) {
        if requestedActive {
            start(strength: strength)
        }
    }

    func stop() {
        requestedActive = false
        reusable?.stop()
        legacy.stop()
    }
}

/// Same four-byte fills and three continuously replenished lanes as Gentle,
/// with command buffers and encoding memory reused after GPU completion.
private final class ReusableBlitEngine {
    private struct Resources {
        let queue: MTL4CommandQueue
        let allocator: MTL4CommandAllocator
        let commandBuffer: MTL4CommandBuffer
        let buffer: MTLBuffer
        let residency: MTLResidencySet
    }

    private final class Lane {
        let resources: Resources
        let commands: [MTL4CommandBuffer]
        var busy = false
        var generation: UInt64 = 0

        init(resources: Resources) {
            self.resources = resources
            commands = [resources.commandBuffer]
        }
    }

    private let worker = DispatchQueue(label: "io.github.impulsepie.M5GPUBoost.reusable", qos: .userInitiated)
    private let queue: MTL4CommandQueue
    private var lanes: [Lane] = []
    private var active = false
    private var generation: UInt64 = 0
    private var lease = BoostLease()
    private var sampleTotalMilliseconds = 0.0
    private var sampleCount = 0
    private var sampleWindowStart = DispatchTime.now().uptimeNanoseconds
    private var telemetryHandler: ((Double) -> Void)?
    private var failureHandler: ((String) -> Void)?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
            throw MetalBoostError.noDevice
        }
        // Leave feedback on Metal's default queue; serialize state on worker.
        // Feedback options are single-submission objects, not reusable lanes.
        queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
        for _ in 0..<BoostStrength.gentle.queuedBufferCount {
            guard let allocator = device.makeCommandAllocator(),
                  let commandBuffer = device.makeCommandBuffer(),
                  let buffer = device.makeBuffer(length: 4_096, options: .storageModeShared) else {
                throw MetalBoostError.noBuffer
            }
            // Independent buffers avoid overlapping writes between lanes in
            // Metal 4, which doesn't provide automatic resource hazard tracking.
            let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
            residency.addAllocation(buffer)
            residency.commit()
            lanes.append(Lane(resources: Resources(queue: queue, allocator: allocator,
                commandBuffer: commandBuffer, buffer: buffer, residency: residency)))
        }
    }

    func setTelemetryHandler(_ handler: @escaping (Double) -> Void) {
        worker.async { [weak self] in self?.telemetryHandler = handler }
    }

    func setFailureHandler(_ handler: @escaping (String) -> Void) {
        worker.async { [weak self] in self?.failureHandler = handler }
    }

    func start() {
        worker.async { [weak self] in
            guard let self else { return }
            self.lease.renew(at: DispatchTime.now().uptimeNanoseconds)
            guard !self.active else { return }
            self.active = true
            self.generation &+= 1
            self.resetTelemetryWindow()
            for index in self.lanes.indices { self.submit(index: index) }
        }
    }

    func stop() {
        worker.async { [weak self] in
            guard let self, self.active else { return }
            self.active = false
            self.generation &+= 1
            self.resetTelemetryWindow()
        }
    }

    private func resetTelemetryWindow() {
        sampleTotalMilliseconds = 0
        sampleCount = 0
        sampleWindowStart = DispatchTime.now().uptimeNanoseconds
    }

    private func fail(_ message: String) {
        active = false
        generation &+= 1
        resetTelemetryWindow()
        failureHandler?(message)
    }

    private func submit(index: Int) {
        guard active else { return }
        guard lease.isValid(at: DispatchTime.now().uptimeNanoseconds) else {
            active = false
            generation &+= 1
            resetTelemetryWindow()
            return
        }
        let lane = lanes[index]
        // A rapid stop/restart may still have old GPU work outstanding. Only
        // its completion can clear busy and make this allocator safe to reset.
        guard !lane.busy else { return }
        autoreleasepool {
            let resources = lane.resources
            resources.allocator.reset()
            resources.commandBuffer.beginCommandBuffer(allocator: resources.allocator)
            resources.commandBuffer.useResidencySet(resources.residency)
            guard let encoder = resources.commandBuffer.makeComputeCommandEncoder() else {
                fail("The Metal 4 blit encoder could not be created.")
                return
            }
            encoder.fill(buffer: resources.buffer, range: 0..<4, value: 0)
            encoder.endEncoding()
            resources.commandBuffer.endCommandBuffer()
            lane.busy = true
            lane.generation = generation
            let options = MTL4CommitOptions()
            options.addFeedbackHandler { [weak self, resources] feedback in
                // Metal 4 doesn't retain resource references. Keep command
                // memory, buffers, residency and queue alive through completion.
                self?.worker.async { [weak self, resources] in
                    withExtendedLifetime(resources) {
                        self?.completed(index: index, feedback: feedback)
                    }
                }
            }
            queue.commit(lane.commands, options: options)
        }
    }

    private func completed(index: Int, feedback: MTL4CommitFeedback) {
        let lane = lanes[index]
        lane.busy = false
        guard active else { return }
        if let error = feedback.error {
            fail("Metal 4 submission failed: \(error.localizedDescription)")
            return
        }
        if lane.generation == generation {
            let milliseconds = max(0, (feedback.gpuEndTime - feedback.gpuStartTime) * 1_000)
            if milliseconds > 0 {
                sampleTotalMilliseconds += milliseconds
                sampleCount += 1
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- sampleWindowStart >= 750_000_000 {
                    let average = sampleTotalMilliseconds / Double(sampleCount)
                    resetTelemetryWindow()
                    telemetryHandler?(average)
                }
            }
        }
        // A completion from an earlier burst may now refill its lane for the
        // current generation; it must never renew the controller's lease.
        submit(index: index)
    }
}

/// Keeps a few short command buffers queued instead of submitting one long
/// dispatch. The GPU can yield at command-buffer boundaries frequently, which
/// reduces the chance of blocking WindowServer for an entire 8.33 ms frame.
private final class LegacyMetalBoostEngine {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void dvfsKeepAlive(
        device float *values [[buffer(0)]],
        constant uint &iterations [[buffer(1)]],
        uint id [[thread_position_in_grid]])
    {
        float value = values[id];

        // A dependent recurrence prevents the compiler from removing the ALU
        // work. It intentionally mirrors the workload that improved the trace,
        // but each dispatch is much shorter.
        for (uint index = 0; index < iterations; ++index) {
            value = sin(value) * cos(value) + 0.001f;
        }

        values[id] = value;
    }
    """

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private let worker = DispatchQueue(
        label: "io.github.impulsepie.M5GPUBoost.legacy",
        qos: .userInitiated
    )

    private var active = false
    private var lease = BoostLease()
    private var generation: UInt64 = 0
    private var strength: BoostStrength = .balanced
    private var sampleTotalMilliseconds = 0.0
    private var sampleCount = 0
    private var sampleWindowStart = DispatchTime.now().uptimeNanoseconds
    private let telemetryIntervalNanoseconds: UInt64 = 750_000_000
    private var telemetryHandler: ((Double) -> Void)?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalBoostError.noDevice
        }
        guard let queue = device.makeCommandQueue(maxCommandBufferCount: 8) else {
            throw MetalBoostError.noQueue
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalBoostError.shaderCompilation(error.localizedDescription)
        }

        guard let function = library.makeFunction(name: "dvfsKeepAlive") else {
            throw MetalBoostError.noFunction
        }

        self.commandQueue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)

        let elementCount = 16_384
        let byteCount = elementCount * MemoryLayout<Float>.stride
        guard let workBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw MetalBoostError.noBuffer
        }
        self.buffer = workBuffer

        let values = workBuffer.contents().bindMemory(to: Float.self, capacity: elementCount)
        for index in 0..<elementCount {
            values[index] = Float(index + 1) * 0.0001
        }
    }

    func setTelemetryHandler(_ handler: @escaping (Double) -> Void) {
        worker.async { [weak self] in
            self?.telemetryHandler = handler
        }
    }

    func start(strength requestedStrength: BoostStrength) {
        worker.async { [weak self] in
            guard let self else { return }
            let laneCountChanged = self.strength.queuedBufferCount != requestedStrength.queuedBufferCount
            self.strength = requestedStrength
            self.lease.renew(at: DispatchTime.now().uptimeNanoseconds)

            if self.active {
                if laneCountChanged {
                    self.restartSubmissionLanes()
                }
                return
            }

            self.active = true
            self.resetTelemetryWindow()
            self.generation &+= 1
            let token = self.generation

            for _ in 0..<requestedStrength.queuedBufferCount {
                self.submit(token: token)
            }
        }
    }

    func updateStrength(_ requestedStrength: BoostStrength) {
        worker.async { [weak self] in
            guard let self else { return }
            let laneCountChanged = self.strength.queuedBufferCount != requestedStrength.queuedBufferCount
            self.strength = requestedStrength
            self.resetTelemetryWindow()

            if self.active && laneCountChanged {
                self.restartSubmissionLanes()
            }
        }
    }

    func stop() {
        worker.async { [weak self] in
            guard let self, self.active else { return }
            self.active = false
            self.generation &+= 1
            self.resetTelemetryWindow()
        }
    }

    private func restartSubmissionLanes() {
        generation &+= 1
        let token = generation

        for _ in 0..<strength.queuedBufferCount {
            submit(token: token)
        }
    }

    private func resetTelemetryWindow() {
        sampleTotalMilliseconds = 0
        sampleCount = 0
        sampleWindowStart = DispatchTime.now().uptimeNanoseconds
    }

    private func submit(token: UInt64) {
        guard active, token == generation else { return }
        // A stalled controller cannot leave the GPU submission loop running.
        guard lease.isValid(at: DispatchTime.now().uptimeNanoseconds) else {
            active = false
            generation &+= 1
            resetTelemetryWindow()
            return
        }

        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            let currentStrength = strength

            if currentStrength.isBlit {
                guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                    return
                }
                encoder.fill(buffer: buffer, range: 0..<4, value: 0)
                encoder.endEncoding()
            } else {
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    return
                }

                var iterations = currentStrength.iterations

                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.setBytes(
                    &iterations,
                    length: MemoryLayout<UInt32>.stride,
                    index: 1
                )

                let grid = MTLSize(width: currentStrength.threadCount, height: 1, depth: 1)
                let groupWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
                let group = MTLSize(width: groupWidth, height: 1, depth: 1)
                encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
                encoder.endEncoding()
            }

            commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                guard let self else { return }
                let milliseconds = max(
                    0,
                    (completedBuffer.gpuEndTime - completedBuffer.gpuStartTime) * 1_000
                )

                self.worker.async { [weak self] in
                    self?.completed(token: token, milliseconds: milliseconds)
                }
            }

            commandBuffer.commit()
        }
    }

    private func completed(token: UInt64, milliseconds: Double) {
        guard active, token == generation else { return }

        if milliseconds > 0 {
            sampleTotalMilliseconds += milliseconds
            sampleCount += 1

            let now = DispatchTime.now().uptimeNanoseconds
            if now &- sampleWindowStart >= telemetryIntervalNanoseconds {
                let average = sampleTotalMilliseconds / Double(sampleCount)
                sampleTotalMilliseconds = 0
                sampleCount = 0
                sampleWindowStart = now
                telemetryHandler?(average)
            }
        }

        submit(token: token)
    }
}

final class BoostController: ObservableObject {
    static let appVersion = "v1.0.0"
    @Published var mode: BoostMode {
        didSet {
            dockedTestWorkItem?.cancel()
            dockedTestDeadline = nil
            if mode == .whileDocked {
                dockedTestDeadline = ProcessInfo.processInfo.systemUptime + 60
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.mode == .whileDocked else { return }
                    self.mode = .onInteraction
                }
                dockedTestWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
            }
            let savedMode = mode == .whileDocked ? BoostMode.onInteraction : mode
            UserDefaults.standard.set(savedMode.rawValue, forKey: "boostMode")
            // The event mask depends on the mode; reevaluate reinstalls it.
            removeEventMonitor()
            reevaluate()
        }
    }

    @Published var strength: BoostStrength {
        didSet {
            UserDefaults.standard.set(strength.rawValue, forKey: "boostStrength")
            engine?.updateStrength(strength)
        }
    }

    /// Real state, used for every decision. Deliberately not published: each
    /// published change redraws the menu-bar item, and a burst starts and
    /// stops far more often than the menu needs to show.
    private(set) var isBoosting = false
    private var currentStatus = "Starting…"

    /// What the menu bar shows. Turns on with the first boost and returns to
    /// idle only after `indicatorHoldSeconds` without another one.
    @Published private(set) var showsBoosting = false
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var displayText = "Checking displays…"
    @Published private(set) var timingText = ""
    @Published private(set) var hasTargetDisplay = false

    private var engine: MetalBoostEngine?
    private var engineError: String?
    private var interactionMonitor: Any?
    private var stopBurstWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var displayRefreshWorkItem: DispatchWorkItem?
    private var dockedTestWorkItem: DispatchWorkItem?
    private var dockedTestDeadline: Double?
    private var screensAreAwake = true
    private var indicatorSettleWorkItem: DispatchWorkItem?
    private var continuousActivity: NSObjectProtocol?
    /// Refreshed in reevaluate, never on the per-event path.
    private var screenIsLocked = false
    private var lockPollTimer: Timer?
    private var lockStateProvider: () -> Bool = BoostController.sessionIsLocked
    private let indicatorHoldSeconds = 3.0
    private var lastInteractionCheck = -Double.infinity
    private let interactionCheckInterval = 0.08
    private let diagnosticsEnabled = CommandLine.arguments.contains("--diagnostics")

    private var waitingStatus: String {
        switch mode {
        case .onInteraction: return "Ready — waiting for activity"
        case .whileInUse: return "Ready — waiting for pointer movement or activity"
        default: return "Ready — waiting for scrolling"
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.mode = BoostMode.restored(from: defaults.string(forKey: "boostMode"))
        self.strength = BoostStrength.restored(from: defaults.string(forKey: "boostStrength"))
        defaults.set(mode.rawValue, forKey: "boostMode")
        defaults.set(strength.rawValue, forKey: "boostStrength")

        installNotifications()
        installPowerNotifications()
        reevaluate()
        diagnostic("Ready: \(mode.label); \(displayText); \(statusText)")
        if CommandLine.arguments.contains("--test-docked") {
            DispatchQueue.main.async { [weak self] in self?.mode = .whileDocked }
        }
    }

    deinit {
        if let interactionMonitor {
            NSEvent.removeMonitor(interactionMonitor)
        }
        refreshTimer?.invalidate()
        stopBurstWorkItem?.cancel()
        displayRefreshWorkItem?.cancel()
        dockedTestWorkItem?.cancel()
        indicatorSettleWorkItem?.cancel()
        lockPollTimer?.invalidate()
        setContinuousActivity(false)
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        engine?.stop()
    }

    func refreshNow() {
        engineError = nil
        reevaluate()
    }

    func openDisplaySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        engine?.stop()
        NSApplication.shared.terminate(nil)
    }

    private func installEventMonitor() {
        guard interactionMonitor == nil else { return }
        var events: NSEvent.EventTypeMask = [
            .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .swipe, .beginGesture, .endGesture, .magnify, .rotate]
        // Pointer movement arrives at the mouse's polling rate, so it is
        // only requested by the mode that uses it.
        if mode.monitorsPointerMovement { events.insert(.mouseMoved) }
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            let activity: BoostActivity
            switch event.type {
            case .scrollWheel:
                guard abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 0 else { return }
                activity = .scroll
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                activity = .drag
            case .mouseMoved:
                activity = .pointer
            default:
                activity = .transition
            }
            self?.handleInteraction(activity)
        }
        if interactionMonitor == nil {
            engineError = "Global input monitoring is unavailable."
        }
    }

    private func installNotifications() {
        let displayToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.diagnostic("Display configuration changed")
            self.stopBurstWorkItem?.cancel()
            self.stopBoost(status: "Checking display configuration…")
            self.engineError = nil
            self.reevaluate()
            self.displayRefreshWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.reevaluate() }
            self.displayRefreshWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
        notificationTokens.append(displayToken)

        let thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A change that leaves boosting allowed must not cut a burst short;
            // serious or critical pressure still suspends in reevaluate.
            self?.reevaluate(periodic: true)
        }
        notificationTokens.append(thermalToken)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepToken = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screensAreAwake = false
            self?.reevaluate()
        }
        notificationTokens.append(sleepToken)

        let wakeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screensAreAwake = true
            self?.reevaluate()
        }
        notificationTokens.append(wakeToken)

        // Lock and unlock are acted on at once; the timers in reevaluate are
        // the fallback if these session notifications ever stop arriving.
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            let token = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                self?.reevaluate(periodic: true)
            }
            notificationTokens.append(token)
        }

        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                self?.handleInteraction(.transition)
            }
            notificationTokens.append(token)
        }
    }

    private func installPowerNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<BoostController>.fromOpaque(context).takeUnretainedValue()
            controller.reevaluate(periodic: true)
        }, context)?.takeRetainedValue()
        if let powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
    }

    private func removeEventMonitor() {
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
        interactionMonitor = nil
    }

    private func ensureEngine() -> Bool {
        if engine != nil { return true }
        guard engineError == nil else { return false }
        do {
            let createdEngine = try MetalBoostEngine()
            engine = createdEngine
            createdEngine.setFailureHandler { [weak self, weak createdEngine] message in
                DispatchQueue.main.async { [weak self, weak createdEngine] in
                    guard let self, let createdEngine, self.engine === createdEngine else { return }
                    self.engineError = message
                    self.suspend(status: message)
                }
            }
            createdEngine.setTelemetryHandler { [weak self] milliseconds in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isBoosting else { return }
                    let text = String(format: "Metal batch: %.2f ms average", milliseconds)
                    if self.timingText != text { self.timingText = text }
                }
            }
            diagnostic("Metal engine ready (\(createdEngine.backendDescription))")
            return true
        } catch {
            engineError = error.localizedDescription
            return false
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.reevaluate(periodic: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func suspend(status: String) {
        stopBurstWorkItem?.cancel()
        removeEventMonitor()
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopBoost(status: status)
        if engine != nil { diagnostic("Standby: Metal engine released; input monitoring off") }
        engine = nil
        setContinuousActivity(false)
    }

    /// The session dictionary is absent or lacks the key when unlocked; any
    /// failure to read it counts as unlocked, so a change in macOS can only
    /// leave the boost running, never stuck off.
    private static func sessionIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// While paused for a locked screen the normal timer is stopped, so this
    /// one keeps checking and resumes within 2 seconds of unlocking.
    private func setLockPolling(_ on: Bool) {
        if on, lockPollTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.reevaluate(periodic: true)
            }
            RunLoop.main.add(timer, forMode: .common)
            lockPollTimer = timer
        } else if !on, let timer = lockPollTimer {
            timer.invalidate()
            lockPollTimer = nil
        }
    }

    /// "Always while docked" depends on the 2-second timer renewing the
    /// engine's 3-second lease. Without this, App Nap may delay that timer in
    /// a windowless app and open gaps in the boost. System sleep stays allowed.
    private func setContinuousActivity(_ on: Bool) {
        if on, continuousActivity == nil {
            continuousActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Continuous GPU boost while docked")
        } else if !on, let token = continuousActivity {
            ProcessInfo.processInfo.endActivity(token)
            continuousActivity = nil
        }
    }

    /// `point` is only supplied by tests; the pointer position is otherwise
    /// read after the throttle, not once per event.
    private func handleInteraction(_ activity: BoostActivity, at point: NSPoint? = nil) {
        guard mode.allows(activity) else { return }

        // High-polling mice can deliver hundreds of drag events per second.
        // Check power/display state at most 12.5 times/sec during a burst;
        // this does not throttle, consume or modify the input events.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInteractionCheck >= interactionCheckInterval else { return }
        lastInteractionCheck = now
        let point = point ?? NSEvent.mouseLocation

        let displays = displayInfos()
        updateDisplayText(from: displays)

        guard canBoost(displays: displays) else { return }
        guard let pointerDisplay = display(at: point, from: displays), pointerDisplay.isTarget else {
            stopBurstWorkItem?.cancel()
            stopBoost(status: "Ready — use the external high-refresh display")
            return
        }

        startBoost(status: activity == .transition
            ? "Boosting for UI activity"
            : "Boosting while \(activity.label)", burst: true)
        stopBurstWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.mode != .off else { return }
            self.stopBoost(status: self.waitingStatus, linger: true)
        }
        stopBurstWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + mode.tailSeconds, execute: workItem)
    }

    private func reevaluate(periodic: Bool = false) {
        if mode == .whileDocked, let deadline = dockedTestDeadline,
           ProcessInfo.processInfo.systemUptime >= deadline {
            mode = .onInteraction
            return
        }
        screenIsLocked = lockStateProvider()
        setLockPolling(screenIsLocked && mode != .off)
        let displays = displayInfos()
        let targetPresent = displays.contains(where: \.isTarget)
        if hasTargetDisplay != targetPresent { hasTargetDisplay = targetPresent }
        updateDisplayText(from: displays)

        if let reason = environment(displays: displays).pauseReason {
            suspend(status: reason)
            return
        }
        if let engineError {
            suspend(status: engineError)
            return
        }
        guard ensureEngine() else {
            suspend(status: engineError ?? "Metal is unavailable.")
            return
        }
        startRefreshTimer()
        setContinuousActivity(mode == .alwaysDocked)

        switch mode {
        case .off:
            break
        case .alwaysDocked:
            removeEventMonitor()
            stopBurstWorkItem?.cancel()
            startBoost(status: "Boosting continuously while docked")
        case .whileDocked:
            removeEventMonitor()
            stopBurstWorkItem?.cancel()
            startBoost(status: "All-motion test — returns to On activity after 60 seconds")
        case .onScroll, .onInteraction, .whileInUse:
            installEventMonitor()
            if let engineError {
                suspend(status: engineError)
                return
            }
            if !periodic {
                stopBurstWorkItem?.cancel()
                stopBoost(status: waitingStatus)
            } else if !isBoosting && currentStatus != waitingStatus {
                currentStatus = waitingStatus
                if indicatorSettleWorkItem == nil { showCurrentState() }
            }
        }
    }

    private func canBoost(displays: [DisplayInfo]) -> Bool {
        guard engineError == nil, engine != nil else {
            stopBoost(status: engineError ?? "Metal is unavailable.")
            return false
        }

        if let reason = environment(displays: displays).pauseReason {
            suspend(status: reason)
            return false
        }

        return true
    }

    private func environment(displays: [DisplayInfo]) -> BoostEnvironment {
        BoostEnvironment(
            mode: mode,
            screensAreAwake: screensAreAwake,
            screenIsLocked: screenIsLocked,
            usingACPower: isUsingACPower(),
            thermalState: ProcessInfo.processInfo.thermalState,
            hasTargetDisplay: displays.contains(where: \.isTarget)
        )
    }

    private func isUsingACPower() -> Bool {
        // This public IOKit call returns nil when no external adapter is connected.
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil
    }

    /// `burst` marks activity-triggered boosts. While the menu bar already
    /// shows a boost, another burst (or a different activity type) publishes
    /// nothing; `--diagnostics` still logs every change.
    private func startBoost(status: String, burst: Bool = false) {
        guard engineError == nil, let engine else {
            stopBoost(status: engineError ?? "Metal is unavailable.")
            return
        }
        if !isBoosting || currentStatus != status {
            diagnostic(status)
        }
        engine.start(strength: strength)
        isBoosting = true
        currentStatus = status
        if burst && showsBoosting {
            indicatorSettleWorkItem?.cancel()
            indicatorSettleWorkItem = nil
        } else {
            showCurrentState()
        }
    }

    /// `linger` is the ordinary end of a burst: the GPU work stops now, but
    /// the menu bar keeps showing the boost for `indicatorHoldSeconds` so
    /// back-to-back bursts don't redraw it each time. Every other stop
    /// (pause, Off, display change, error) is shown immediately.
    private func stopBoost(status: String, linger: Bool = false) {
        if isBoosting {
            diagnostic("Stopped: \(status)")
        }
        engine?.stop()
        isBoosting = false
        currentStatus = status
        guard linger && showsBoosting else {
            showCurrentState()
            return
        }
        indicatorSettleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.indicatorSettleWorkItem = nil
            self.showCurrentState()
        }
        indicatorSettleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + indicatorHoldSeconds, execute: item)
    }

    /// Publishes the real state, skipping values that haven't changed.
    private func showCurrentState() {
        indicatorSettleWorkItem?.cancel()
        indicatorSettleWorkItem = nil
        if showsBoosting != isBoosting { showsBoosting = isBoosting }
        if statusText != currentStatus { statusText = currentStatus }
        if !isBoosting && !timingText.isEmpty { timingText = "" }
    }

    private func diagnostic(_ message: String) {
        guard diagnosticsEnabled else { return }
        // Status only: no input contents, coordinates, window titles or files.
        print("M5GPUBoost: \(message)")
        fflush(stdout)
    }

    private func displayInfos() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let displayMode = CGDisplayCopyDisplayMode(displayID) else { return nil }

            return DisplayInfo(
                id: displayID,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                name: screen.localizedName,
                pixelWidth: displayMode.pixelWidth,
                pixelHeight: displayMode.pixelHeight,
                refreshRate: displayMode.refreshRate
            )
        }
    }

    private func display(at point: NSPoint, from infos: [DisplayInfo]) -> DisplayInfo? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let id = CGDirectDisplayID(number.uint32Value)
        return infos.first(where: { $0.id == id })
    }

    private func updateDisplayText(from displays: [DisplayInfo]) {
        let text: String
        if let target = displays.first(where: \.isTarget) {
            text = target.summary
        } else {
            text = "No external 5K/5K2K 100+ Hz display detected"
        }
        if displayText != text { displayText = text }
    }
}

private struct BoostMenu: View {
    @ObservedObject var controller: BoostController

    var body: some View {
        Text("M5GPUBoost \(BoostController.appVersion)").font(.caption).foregroundStyle(.secondary)
        Text(controller.displayText)
        Text(controller.statusText)
        if !controller.timingText.isEmpty {
            Text(controller.timingText)
        }

        Divider()

        Picker("Mode", selection: $controller.mode) {
            ForEach(BoostMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }

        Picker("Strength", selection: $controller.strength) {
            ForEach(BoostStrength.allCases) { strength in
                Text(strength.label).tag(strength)
            }
        }

        Divider()

        Button("Open Display Settings…") {
            controller.openDisplaySettings()
        }

        Button("Check Displays Again") {
            controller.refreshNow()
        }

        Divider()

        Button("Quit M5GPUBoost") {
            controller.quit()
        }
        .keyboardShortcut("q")
    }
}

@main
struct M5GPUBoostApp: App {
    @StateObject private var controller = BoostController()

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { controller.hasTargetDisplay },
            set: { _ in }
        )) {
            BoostMenu(controller: controller)
        } label: {
            Image(systemName: controller.showsBoosting ? "bolt.fill" : "bolt")
        }
        .menuBarExtraStyle(.menu)
    }
}
