import AppKit
import CoreGraphics
import IOKit
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .onScroll: return "On scroll"
        case .onInteraction: return "On activity"
        case .whileInUse: return "While in use (pointer movement too)"
        case .alwaysDocked: return "Always while docked (video too, highest cost)"
        }
    }

    func allows(_ activity: BoostActivity) -> Bool {
        switch self {
        case .off, .alwaysDocked: return false
        case .onScroll: return activity == .scroll
        case .onInteraction: return activity != .pointer
        case .whileInUse: return true
        }
    }

    /// How long boosting continues after the last accepted activity.
    var tailSeconds: Double { self == .whileInUse ? 2.0 : 0.9 }

    var monitorsPointerMovement: Bool { self == .whileInUse }

    static func restored(from value: String?) -> BoostMode {
        if let value, let mode = Self(rawValue: value) { return mode }
        // Retired modes (Continuous, the 60-second test) and older labels
        // fall back to activity-triggered work, never to an always-on mode.
        return allCases.first(where: { $0.label == value }) ?? .onInteraction
    }
}

/// The one workload both backends submit: a short compute dispatch.
///
/// The GPU reports two performance-state channels through IOReport, GPUPH and
/// AFRSTATE. A four-byte fill (the old Gentle strength) holds the first at
/// its top state but leaves the second cycling through every state. A
/// dispatch of about 2,000 threads or more holds both. Fewer than three lanes,
/// or any pause between submissions, lets the clock fall again.
/// See docs/GPU-SCHEDULING.md for the measurements.
private enum BoostWorkload {
    static let threadCount = 4_096
    static let iterations = 64
    static let laneCount = 3
    /// A lane normally completes in microseconds.
    static let stallNanoseconds: UInt64 = 2_000_000_000

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void dvfsKeepAlive(
        device float *values [[buffer(0)]],
        uint id [[thread_position_in_grid]])
    {
        float value = values[id];

        // A dependent recurrence prevents the compiler from removing the ALU
        // work.
        for (uint index = 0; index < \(iterations); ++index) {
            value = sin(value) * cos(value) + 0.001f;
        }

        values[id] = value;
    }
    """

    static func makeBuffer(device: MTLDevice) -> MTLBuffer? {
        guard let buffer = device.makeBuffer(
            length: threadCount * MemoryLayout<Float>.stride, options: .storageModeShared) else { return nil }
        let values = buffer.contents().bindMemory(to: Float.self, capacity: threadCount)
        for index in 0..<threadCount { values[index] = Float(index + 1) * 0.0001 }
        return buffer
    }
}

/// What a backend's submission loop did since it was last asked.
struct LoopSample {
    let batchesPerSecond: Double
    let gpuMicrosecondsPerBatch: Double
}

/// Counts completed batches on a backend's worker queue.
private struct LoopCounter {
    private var count = 0
    private var gpuSeconds = 0.0
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    mutating func reset() {
        count = 0
        gpuSeconds = 0
        windowStart = DispatchTime.now().uptimeNanoseconds
    }

    mutating func add(gpuSeconds seconds: Double) {
        count += 1
        gpuSeconds += max(0, seconds)
    }

    mutating func take() -> LoopSample? {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- windowStart) / 1_000_000_000
        defer { reset() }
        guard count > 0, elapsed >= 0.2 else { return nil }
        return LoopSample(batchesPerSecond: Double(count) / elapsed,
                          gpuMicrosecondsPerBatch: gpuSeconds / Double(count) * 1_000_000)
    }
}

private struct DisplayInfo {
    let id: CGDirectDisplayID
    let isBuiltin: Bool
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    /// The fastest the screen can refresh, from NSScreen. 0 when unknown.
    var maximumFramesPerSecond = 0

    var isTarget: Bool {
        guard !isBuiltin else { return false }

        // Include 5120x2160 ultrawides and their intermediate HiDPI modes.
        let isFiveK = pixelWidth >= 5_000 && pixelHeight >= 2_000
        let isHighRefresh = refreshRate >= 100
        let isStudioDisplayXDR = name.localizedCaseInsensitiveContains("Studio Display XDR")

        // Some adaptive modes report 0 Hz through CoreGraphics. Then go by
        // the screen's fastest refresh, or by the Studio Display XDR name.
        let isAdaptiveHighRefresh = refreshRate == 0 && (maximumFramesPerSecond >= 100 || isStudioDisplayXDR)
        return isFiveK && (isHighRefresh || isAdaptiveHighRefresh)
    }

    var summary: String {
        let rate: String
        if refreshRate > 0 {
            rate = String(format: "%.0f Hz", refreshRate)
        } else if maximumFramesPerSecond > 0 {
            rate = "adaptive, up to \(maximumFramesPerSecond) Hz"
        } else {
            rate = "adaptive rate"
        }
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

/// Routes to the Metal 4 backend when the device supports it and to the
/// original backend otherwise. If Metal 4 fails while running, the original
/// backend takes over without the controller having to do anything.
/// Used from the main thread; each backend serializes its own GPU state.
private final class MetalBoostEngine {
    private var metal4: Metal4BoostEngine?
    private var original: OriginalBoostEngine?
    private var requestedActive = false
    private var failureHandler: ((String) -> Void)?
    private var noteHandler: ((String) -> Void)?

    var backendDescription: String { metal4 == nil ? "original Metal" : "Metal 4" }

    init(useMetal4: Bool = true) throws {
        metal4 = useMetal4 ? try? Metal4BoostEngine() : nil
        if metal4 == nil {
            original = try makeOriginal()
        }
        metal4?.setFailureHandler { [weak self] message in
            DispatchQueue.main.async { self?.fallBack(reason: message) }
        }
    }

    /// Called once nothing else can take over.
    func setFailureHandler(_ handler: @escaping (String) -> Void) { failureHandler = handler }

    /// Called when the backend changes but boosting carries on.
    func setNoteHandler(_ handler: @escaping (String) -> Void) { noteHandler = handler }

    func start() {
        requestedActive = true
        if let metal4 { metal4.start() } else { original?.start() }
    }

    func stop() {
        requestedActive = false
        metal4?.stop()
        original?.stop()
    }

    func takeLoopSample() -> LoopSample? {
        if let metal4 { return metal4.takeLoopSample() }
        return original?.takeLoopSample()
    }

    private func makeOriginal() throws -> OriginalBoostEngine {
        let engine = try OriginalBoostEngine()
        engine.setFailureHandler { [weak self] message in
            DispatchQueue.main.async { self?.failureHandler?(message) }
        }
        return engine
    }

    private func fallBack(reason: String) {
        guard metal4 != nil else { return }
        metal4 = nil
        do {
            let engine = try makeOriginal()
            original = engine
            if requestedActive { engine.start() }
            noteHandler?("Metal 4 backend stopped (\(reason)); the original backend took over")
        } catch {
            failureHandler?("\(reason) \(error.localizedDescription)")
        }
    }
}

/// Three lanes, each with its own command buffer, allocator, work buffer and
/// argument table, reused after every GPU completion.
private final class Metal4BoostEngine {
    private final class Lane {
        let allocator: MTL4CommandAllocator
        let commandBuffer: MTL4CommandBuffer
        let buffer: MTLBuffer
        let residency: MTLResidencySet
        let arguments: MTL4ArgumentTable
        let commands: [MTL4CommandBuffer]
        var busy = false
        var generation: UInt64 = 0
        var submittedAt: UInt64 = 0

        init(allocator: MTL4CommandAllocator, commandBuffer: MTL4CommandBuffer, buffer: MTLBuffer,
             residency: MTLResidencySet, arguments: MTL4ArgumentTable) {
            self.allocator = allocator
            self.commandBuffer = commandBuffer
            self.buffer = buffer
            self.residency = residency
            self.arguments = arguments
            commands = [commandBuffer]
        }
    }

    private let worker = DispatchQueue(label: "io.github.impulsepie.M5GPUBoost.metal4", qos: .userInitiated)
    private let queue: MTL4CommandQueue
    private let pipeline: MTLComputePipelineState
    private let grid = MTLSize(width: BoostWorkload.threadCount, height: 1, depth: 1)
    private let group: MTLSize
    private var lanes: [Lane] = []
    private var active = false
    private var generation: UInt64 = 0
    private var lease = BoostLease()
    private var counter = LoopCounter()
    private var failureHandler: ((String) -> Void)?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
            throw MetalBoostError.noDevice
        }
        // Leave feedback on Metal's default queue; serialize state on worker.
        // Feedback options are single-submission objects, not reusable lanes.
        queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: BoostWorkload.shaderSource, options: nil)
        } catch {
            throw MetalBoostError.shaderCompilation(error.localizedDescription)
        }
        let function = MTL4LibraryFunctionDescriptor()
        function.name = "dvfsKeepAlive"
        function.library = library
        let pipelineDescriptor = MTL4ComputePipelineDescriptor()
        pipelineDescriptor.computeFunctionDescriptor = function
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        pipeline = try compiler.makeComputePipelineState(descriptor: pipelineDescriptor, compilerTaskOptions: nil)
        group = MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1
        for _ in 0..<BoostWorkload.laneCount {
            guard let allocator = device.makeCommandAllocator(),
                  let commandBuffer = device.makeCommandBuffer(),
                  let buffer = BoostWorkload.makeBuffer(device: device) else {
                throw MetalBoostError.noBuffer
            }
            // Each lane writes its own buffer: Metal 4 doesn't track resource
            // hazards, so lanes must not share one.
            let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
            residency.addAllocation(buffer)
            residency.commit()
            let arguments = try device.makeArgumentTable(descriptor: tableDescriptor)
            arguments.setAddress(buffer.gpuAddress, index: 0)
            lanes.append(Lane(allocator: allocator, commandBuffer: commandBuffer, buffer: buffer,
                              residency: residency, arguments: arguments))
        }
    }

    func setFailureHandler(_ handler: @escaping (String) -> Void) {
        worker.async { [weak self] in self?.failureHandler = handler }
    }

    /// Starts the loop or, if it is already running, renews its lease. Also
    /// the watchdog: a lane whose feedback never arrived is reported here.
    func start() {
        worker.async { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if self.lanes.contains(where: { $0.busy && now &- $0.submittedAt > BoostWorkload.stallNanoseconds }) {
                self.fail("A Metal 4 lane stopped responding.")
                return
            }
            self.lease.renew(at: now)
            guard !self.active else { return }
            self.active = true
            self.generation &+= 1
            self.counter.reset()
            for lane in self.lanes { self.submit(lane) }
        }
    }

    func stop() {
        worker.async { [weak self] in
            guard let self, self.active else { return }
            self.deactivate()
        }
    }

    func takeLoopSample() -> LoopSample? {
        worker.sync { active ? counter.take() : nil }
    }

    private func deactivate() {
        active = false
        generation &+= 1
        counter.reset()
    }

    private func fail(_ message: String) {
        deactivate()
        let handler = failureHandler
        // One report only: after this the router replaces the backend.
        failureHandler = nil
        handler?(message)
    }

    private func submit(_ lane: Lane) {
        guard active else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // A stalled controller cannot leave the GPU submission loop running.
        guard lease.isValid(at: now) else {
            deactivate()
            return
        }
        // A rapid stop/restart may still have old GPU work outstanding. Only
        // its completion can clear busy and make this allocator safe to reset.
        guard !lane.busy else { return }
        autoreleasepool {
            lane.allocator.reset()
            lane.commandBuffer.beginCommandBuffer(allocator: lane.allocator)
            lane.commandBuffer.useResidencySet(lane.residency)
            guard let encoder = lane.commandBuffer.makeComputeCommandEncoder() else {
                fail("The Metal 4 compute encoder could not be created.")
                return
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setArgumentTable(lane.arguments)
            encoder.dispatchThreads(threadsPerGrid: grid, threadsPerThreadgroup: group)
            encoder.endEncoding()
            lane.commandBuffer.endCommandBuffer()
            lane.busy = true
            lane.generation = generation
            lane.submittedAt = now
            let options = MTL4CommitOptions()
            options.addFeedbackHandler { [weak self, lane, queue, pipeline] feedback in
                // Metal 4 doesn't retain resource references. Keep the lane,
                // queue and pipeline alive through completion.
                let start = feedback.gpuStartTime, end = feedback.gpuEndTime, error = feedback.error
                guard let self else {
                    withExtendedLifetime((lane, queue, pipeline)) {}
                    return
                }
                self.worker.async { [weak self] in
                    withExtendedLifetime((lane, queue, pipeline)) {
                        self?.completed(lane, gpuSeconds: end - start, error: error)
                    }
                }
            }
            queue.commit(lane.commands, options: options)
        }
    }

    private func completed(_ lane: Lane, gpuSeconds: Double, error: Error?) {
        lane.busy = false
        guard active else { return }
        if let error {
            fail("Metal 4 submission failed: \(error.localizedDescription)")
            return
        }
        if lane.generation == generation {
            counter.add(gpuSeconds: gpuSeconds)
        }
        // A completion from an earlier burst may now refill its lane for the
        // current generation; it must never renew the controller's lease.
        submit(lane)
    }
}

/// Fred's engine: a new command buffer for every submission, from a queue
/// limited to eight. Used where Metal 4 is unavailable or has failed.
///
/// Keeps a few short command buffers queued instead of submitting one long
/// dispatch. The GPU can yield at command-buffer boundaries frequently, which
/// reduces the chance of blocking WindowServer for an entire 8.33 ms frame.
private final class OriginalBoostEngine {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private let grid = MTLSize(width: BoostWorkload.threadCount, height: 1, depth: 1)
    private let group: MTLSize
    private let worker = DispatchQueue(
        label: "io.github.impulsepie.M5GPUBoost.original",
        qos: .userInitiated
    )

    private var active = false
    private var lease = BoostLease()
    private var generation: UInt64 = 0
    /// Submissions of the current generation that haven't completed yet.
    private var inFlight = 0
    private var lastProgress: UInt64 = 0
    private var restartedAfterStall = false
    private var counter = LoopCounter()
    private var failureHandler: ((String) -> Void)?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalBoostError.noDevice
        }
        guard let queue = device.makeCommandQueue(maxCommandBufferCount: 8) else {
            throw MetalBoostError.noQueue
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: BoostWorkload.shaderSource, options: nil)
        } catch {
            throw MetalBoostError.shaderCompilation(error.localizedDescription)
        }

        guard let function = library.makeFunction(name: "dvfsKeepAlive") else {
            throw MetalBoostError.noFunction
        }

        self.commandQueue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)
        self.group = MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)

        guard let workBuffer = BoostWorkload.makeBuffer(device: device) else {
            throw MetalBoostError.noBuffer
        }
        self.buffer = workBuffer
    }

    func setFailureHandler(_ handler: @escaping (String) -> Void) {
        worker.async { [weak self] in self?.failureHandler = handler }
    }

    /// Starts the loop or, if it is already running, renews its lease, refills
    /// any lane that failed to submit and restarts lanes that have stalled.
    func start() {
        worker.async { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.lease.renew(at: now)

            if self.active {
                if now &- self.lastProgress > BoostWorkload.stallNanoseconds {
                    guard !self.restartedAfterStall else {
                        self.fail("The GPU stopped completing work.")
                        return
                    }
                    self.restartedAfterStall = true
                    self.beginGeneration(at: now)
                }
            } else {
                self.active = true
                self.restartedAfterStall = false
                self.counter.reset()
                self.beginGeneration(at: now)
            }
            self.fillLanes()
        }
    }

    func stop() {
        worker.async { [weak self] in
            guard let self, self.active else { return }
            self.deactivate()
        }
    }

    func takeLoopSample() -> LoopSample? {
        worker.sync { active ? counter.take() : nil }
    }

    private func beginGeneration(at now: UInt64) {
        generation &+= 1
        inFlight = 0
        lastProgress = now
    }

    private func deactivate() {
        active = false
        generation &+= 1
        inFlight = 0
        counter.reset()
    }

    private func fail(_ message: String) {
        deactivate()
        failureHandler?(message)
    }

    private func fillLanes() {
        while active, inFlight < BoostWorkload.laneCount {
            // A stalled controller cannot leave the GPU submission loop running.
            guard lease.isValid(at: DispatchTime.now().uptimeNanoseconds) else {
                deactivate()
                return
            }
            // A submission that can't be made is retried on the next start.
            guard submit() else { return }
        }
    }

    private func submit() -> Bool {
        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            encoder.endEncoding()

            let token = generation
            commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                guard let self else { return }
                let seconds = completedBuffer.gpuEndTime - completedBuffer.gpuStartTime
                let error = completedBuffer.error

                self.worker.async { [weak self] in
                    self?.completed(token: token, gpuSeconds: seconds, error: error)
                }
            }

            inFlight += 1
            commandBuffer.commit()
            return true
        }
    }

    private func completed(token: UInt64, gpuSeconds: Double, error: Error?) {
        guard active, token == generation else { return }
        inFlight -= 1
        if let error {
            fail("Metal submission failed: \(error.localizedDescription)")
            return
        }
        lastProgress = DispatchTime.now().uptimeNanoseconds
        restartedAfterStall = false
        counter.add(gpuSeconds: gpuSeconds)
        fillLanes()
    }
}

/// Reads how long the GPU spent in each performance state, so the menu can
/// say whether the boost is actually holding the clock.
///
/// The figures come from IOReport, which is a private library. Every symbol
/// is looked up at run time and the monitor is simply absent if any part is
/// missing; the app then shows the submission rate instead.
/// Used from the main thread.
private final class GPUClockMonitor {
    struct Reading {
        /// Share of the window spent in the top state, 0...1, per channel.
        let mainShare: Double
        let secondShare: Double?
        let megahertz: Int?

        var heldShare: Double { min(mainShare, secondShare ?? 1) }
    }

    /// One subscription for the life of the process.
    static let shared = GPUClockMonitor()

    private typealias CopyChannelsFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias MergeChannelsFn = @convention(c) (CFMutableDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias SubscribeFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias SamplesFn = @convention(c) (OpaquePointer, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: SamplesFn
    private let createDelta: DeltaFn
    private let channelName: ChannelNameFn
    private let stateCount: StateCountFn
    private let stateName: StateNameFn
    private let stateResidency: StateResidencyFn
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private let topStateName: String
    private let megahertz: Int?
    private var previous: CFDictionary?

    private init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
              let mergeChannels = symbol("IOReportMergeChannels", as: MergeChannelsFn.self),
              let subscribe = symbol("IOReportCreateSubscription", as: SubscribeFn.self),
              let createSamples = symbol("IOReportCreateSamples", as: SamplesFn.self),
              let createDelta = symbol("IOReportCreateSamplesDelta", as: DeltaFn.self),
              let channelName = symbol("IOReportChannelGetChannelName", as: ChannelNameFn.self),
              let stateCount = symbol("IOReportStateGetCount", as: StateCountFn.self),
              let stateName = symbol("IOReportStateGetNameForIndex", as: StateNameFn.self),
              let stateResidency = symbol("IOReportStateGetResidency", as: StateResidencyFn.self),
              let top = Self.topState() else {
            return nil
        }

        guard let main = copyChannels("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?
                .takeRetainedValue(),
              let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, main) else {
            return nil
        }
        // Not every GPU reports the second channel; one is enough.
        if let second = copyChannels("GPU Stats" as CFString, "AFR Performance States" as CFString, 0, 0, 0)?
            .takeRetainedValue() {
            mergeChannels(desired, second, nil)
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, desired, &subscribed, 0, nil),
              let channels = subscribed?.takeRetainedValue() else {
            return nil
        }

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.channelName = channelName
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        self.subscription = subscription
        self.channels = channels
        topStateName = "P\(top.index)"
        megahertz = top.megahertz
    }

    /// The GPU's highest performance state and its frequency, from the
    /// device tree: `perf-states` holds a frequency and a voltage per state,
    /// starting with the powered-off entry.
    private static func topState() -> (index: Int, megahertz: Int?)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("sgx"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Data? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data
        }
        func word(_ data: Data, at offset: Int) -> UInt32? {
            guard offset >= 0, data.count >= offset + 4 else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard let countData = property("perf-state-count"), let count = word(countData, at: 0), count >= 2 else {
            return nil
        }
        let index = Int(count) - 1
        let hertz = property("perf-states").flatMap { word($0, at: index * 8) }
        return (index, hertz.flatMap { $0 > 0 ? Int(($0 + 500_000) / 1_000_000) : nil })
    }

    /// Starts a new measuring window without reporting the old one.
    func mark() {
        previous = createSamples(subscription, channels, nil)?.takeRetainedValue()
    }

    /// The share of time in the top state since the last `mark` or `read`.
    func read() -> Reading? {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer { previous = current }
        guard let previous,
              let delta = createDelta(previous, current, nil)?.takeRetainedValue() as NSDictionary?,
              let entries = delta["IOReportChannels"] as? [NSDictionary] else {
            return nil
        }
        var shares: [String: Double] = [:]
        for entry in entries {
            let channel = entry as CFDictionary
            guard let name = channelName(channel)?.takeUnretainedValue() as String? else { continue }
            var total: Int64 = 0, top: Int64 = 0
            for index in 0..<max(0, stateCount(channel)) {
                let residency = stateResidency(channel, index)
                total += residency
                if (stateName(channel, index)?.takeUnretainedValue() as String?) == topStateName {
                    top = residency
                }
            }
            if total > 0 { shares[name] = Double(top) / Double(total) }
        }
        guard let main = shares["GPUPH"] else { return nil }
        return Reading(mainShare: main, secondShare: shares["AFRSTATE"], megahertz: megahertz)
    }
}

final class BoostController: ObservableObject {
    static let appVersion = "v1.1.0"
    @Published var mode: BoostMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "boostMode")
            sessionSeconds = 0
            sessionHeldSeconds = 0
            // The event mask depends on the mode; reevaluate reinstalls it.
            removeEventMonitor()
            reevaluate()
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
    /// Whether the boost is holding the GPU clock, or the submission rate
    /// where the clock can't be read. Empty while idle.
    @Published private(set) var readoutText = ""
    @Published private(set) var hasTargetDisplay = false

    private var engine: MetalBoostEngine?
    private var engineError: String?
    private let clockMonitor = GPUClockMonitor.shared
    private var readoutWindowStart = 0.0
    /// Boosted time since launch or the last mode change, and how much of it
    /// was spent at the top clock state.
    private var sessionSeconds = 0.0
    private var sessionHeldSeconds = 0.0
    private var interactionMonitor: Any?
    private var stopBurstWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var displayRefreshWorkItem: DispatchWorkItem?
    private var screensAreAwake = true
    private var indicatorSettleWorkItem: DispatchWorkItem?
    private var continuousActivity: NSObjectProtocol?
    /// Refreshed in reevaluate, never on the per-event path. Display, power
    /// and lock changes all arrive as notifications that call reevaluate,
    /// and the 2-second timer covers any that are missed.
    private var displays: [DisplayInfo] = []
    private var usingACPower = false
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
        defaults.set(mode.rawValue, forKey: "boostMode")
        // 1.0 had Gentle and Balanced strengths; there is one workload now.
        defaults.removeObject(forKey: "boostStrength")

        installNotifications()
        installPowerNotifications()
        reevaluate()
        diagnostic("Ready: \(mode.label); \(displayText); \(statusText)")
        if clockMonitor == nil { diagnostic("GPU clock states can't be read here; showing the submission rate") }
    }

    deinit {
        if let interactionMonitor {
            NSEvent.removeMonitor(interactionMonitor)
        }
        refreshTimer?.invalidate()
        stopBurstWorkItem?.cancel()
        displayRefreshWorkItem?.cancel()
        indicatorSettleWorkItem?.cancel()
        lockPollTimer?.invalidate()
        setBoostActivity(false)
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
                guard let self, let createdEngine, self.engine === createdEngine else { return }
                self.engineError = message
                self.suspend(status: message)
            }
            createdEngine.setNoteHandler { [weak self] message in self?.diagnostic(message) }
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

    /// Held for as long as a boost is running, in every mode. App Nap would
    /// otherwise be free to slow a windowless app: "Always while docked"
    /// depends on the 2-second timer renewing the engine's 3-second lease,
    /// and any delay to the submission threads lets the GPU clock fall.
    /// System sleep stays allowed.
    private func setBoostActivity(_ on: Bool) {
        if on, continuousActivity == nil {
            continuousActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Holding the GPU clock for a high-refresh display")
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
        // Act on at most 12.5 of them a second during a burst; this does not
        // throttle, consume or modify the input events. Display, power and
        // lock state come from the last reevaluate, not from new queries.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInteractionCheck >= interactionCheckInterval else { return }
        lastInteractionCheck = now
        let point = point ?? NSEvent.mouseLocation

        guard canBoost() else { return }
        guard let pointerDisplay = display(at: point), pointerDisplay.isTarget else {
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
        screenIsLocked = lockStateProvider()
        setLockPolling(screenIsLocked && mode != .off)
        displays = displayInfos()
        usingACPower = Self.isUsingACPower()
        let targetPresent = displays.contains(where: \.isTarget)
        if hasTargetDisplay != targetPresent { hasTargetDisplay = targetPresent }
        updateDisplayText()

        if let reason = environment.pauseReason {
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

        switch mode {
        case .off:
            break
        case .alwaysDocked:
            removeEventMonitor()
            stopBurstWorkItem?.cancel()
            let wasBoosting = isBoosting
            startBoost(status: "Boosting continuously while docked")
            if periodic && wasBoosting { updateReadout() }
        case .onScroll, .onInteraction, .whileInUse:
            installEventMonitor()
            if let engineError {
                suspend(status: engineError)
                return
            }
            if !periodic {
                stopBurstWorkItem?.cancel()
                stopBoost(status: waitingStatus)
            } else if isBoosting {
                updateReadout()
            } else if currentStatus != waitingStatus {
                currentStatus = waitingStatus
                if indicatorSettleWorkItem == nil { showCurrentState() }
            }
        }
    }

    private func canBoost() -> Bool {
        guard engineError == nil, engine != nil else {
            stopBoost(status: engineError ?? "Metal is unavailable.")
            return false
        }

        if let reason = environment.pauseReason {
            suspend(status: reason)
            return false
        }

        return true
    }

    private var environment: BoostEnvironment {
        BoostEnvironment(
            mode: mode,
            screensAreAwake: screensAreAwake,
            screenIsLocked: screenIsLocked,
            usingACPower: usingACPower,
            thermalState: ProcessInfo.processInfo.thermalState,
            hasTargetDisplay: displays.contains(where: \.isTarget)
        )
    }

    /// Mains power on a desktop Mac as well as a laptop with its adapter
    /// connected. Anything else, including a failed read, counts as battery.
    private static func isUsingACPower() -> Bool {
        guard let source = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMACPowerKey
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
        // The readout covers boosted time only, so its window opens here.
        if !isBoosting {
            clockMonitor?.mark()
            readoutWindowStart = ProcessInfo.processInfo.systemUptime
        }
        setBoostActivity(true)
        engine.start()
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
            // The last reading of a burst, shown while the indicator lingers.
            if linger { updateReadout(final: true) }
        }
        engine?.stop()
        setBoostActivity(false)
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
        if !isBoosting && !readoutText.isEmpty { readoutText = "" }
    }

    /// Called on the 2-second timer while boosting and at the end of a burst.
    /// A steady hold always produces the same text, so it publishes once.
    /// Power, thermal and lock notifications also reach here at any moment,
    /// so a window under a second is left to grow unless the burst is over.
    private func updateReadout(final: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard final || now - readoutWindowStart >= 1 else { return }
        let window = now - readoutWindowStart
        readoutWindowStart = now
        let loop = engine?.takeLoopSample()
        let clock = clockMonitor?.read()
        if let clock {
            sessionSeconds += window
            sessionHeldSeconds += window * clock.heldShare
        }
        let session = sessionSeconds >= 60 ? sessionHeldSeconds / sessionSeconds : nil
        if let text = Self.readout(clock: clock, loop: loop, session: session), readoutText != text {
            readoutText = text
        }
        guard diagnosticsEnabled else { return }
        var parts: [String] = []
        if let clock {
            let rate = clock.megahertz.map { " at \($0) MHz" } ?? " in the top state"
            parts.append(String(format: "GPUPH %.1f%%", clock.mainShare * 100)
                + (clock.secondShare.map { String(format: ", AFRSTATE %.1f%%", $0 * 100) } ?? "") + rate)
        }
        if let loop {
            parts.append(String(format: "%.0f batches/s, %.1f µs GPU each",
                                loop.batchesPerSecond, loop.gpuMicrosecondsPerBatch))
        }
        if let session { parts.append(String(format: "%.2f%% over %.0f s boosted", session * 100, sessionSeconds)) }
        if !parts.isEmpty { diagnostic("Clock: " + parts.joined(separator: "; ")) }
    }

    /// `session` is the share of all boosted time at the top state. It is
    /// shown once there is a minute of it, so one slow window stays visible
    /// after the current reading has recovered.
    fileprivate static func readout(clock: GPUClockMonitor.Reading?, loop: LoopSample?,
                                    session: Double? = nil) -> String? {
        if let clock {
            let rate = clock.megahertz.map { "\($0) MHz" } ?? "its top speed"
            // Rounded down, so 100% means no measurable time below the top state.
            let overall = session.map { String(format: " (%.1f%% this session)", ($0 * 1_000).rounded(.down) / 10) } ?? ""
            // Short dips are normal; only say so when the hold is really short.
            if clock.heldShare >= 0.97 { return "GPU clock held at \(rate)\(overall)" }
            return String(format: "GPU clock at \(rate) %.0f%% of the time", clock.heldShare * 100) + overall
        }
        if let loop {
            let thousands = (loop.batchesPerSecond / 1_000).rounded()
            return thousands >= 1
                ? String(format: "Submitting about %.0f,000 GPU batches a second", thousands)
                : String(format: "Submitting %.0f GPU batches a second", loop.batchesPerSecond)
        }
        return nil
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
                refreshRate: displayMode.refreshRate,
                maximumFramesPerSecond: screen.maximumFramesPerSecond
            )
        }
    }

    private func display(at point: NSPoint) -> DisplayInfo? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let id = CGDirectDisplayID(number.uint32Value)
        return displays.first(where: { $0.id == id })
    }

    private func updateDisplayText() {
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
        if !controller.readoutText.isEmpty {
            Text(controller.readoutText)
        }

        Divider()

        Picker("Mode", selection: $controller.mode) {
            ForEach(BoostMode.allCases) { mode in
                Text(mode.label).tag(mode)
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
