// Runtime checks for M5GPUBoost. run-runtime-checks.command appends this file
// to Sources/M5GPUBoost.swift, minus its @main app, so the extensions below
// can reach private state. They run the real Metal engines and controller.

extension LegacyMetalBoostEngine {
    fileprivate func testActive() -> Bool { worker.sync { active } }
}
extension ReusableBlitEngine {
    fileprivate func testActive() -> Bool { worker.sync { active } }
    fileprivate func testDrained() -> Bool { worker.sync { !lanes.contains(where: { $0.busy }) } }
    fileprivate func testFault() { worker.sync { fail("Synthetic runtime test fault") } }
    fileprivate func testTelemetryCallbacks(_ value: @autoclosure () -> Int) -> Int { worker.sync { value() } }
}
extension MetalBoostEngine {
    fileprivate func testActive() -> Bool { legacy.testActive() || (reusable?.testActive() ?? false) }
    fileprivate func testReusableAvailable() -> Bool { reusable != nil }
    fileprivate func testReusableActive() -> Bool { reusable?.testActive() ?? false }
    fileprivate func testLegacyActive() -> Bool { legacy.testActive() }
}
extension BoostController {
    fileprivate func testResources() -> [Bool] { [engine != nil, interactionMonitor != nil, refreshTimer != nil] }
    fileprivate func expireDiagnostic() {
        dockedTestDeadline = ProcessInfo.processInfo.systemUptime - 1
        reevaluate(periodic: true)
    }
    /// Stops real input and the polling timer from reaching this controller,
    /// so the timed checks below see only the activity they inject.
    fileprivate func testQuiesce() {
        removeEventMonitor()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    fileprivate func testActivity(_ activity: BoostActivity, at point: NSPoint) {
        lastInteractionCheck = -Double.infinity
        handleInteraction(activity, at: point)
    }
    fileprivate func testEngineActive() -> Bool { engine?.testActive() ?? false }
    fileprivate func testLocked() -> Bool { screenIsLocked }
    fileprivate func testLockPolling() -> Bool { lockPollTimer != nil }
    fileprivate func testSetLocked(_ locked: Bool, reevaluate now: Bool) {
        lockStateProvider = { locked }
        if now { reevaluate(periodic: true) }
    }
    fileprivate func testMonitorInstalled() -> Bool { interactionMonitor != nil }
    fileprivate func testShown() -> (Bool, String, String) { (showsBoosting, statusText, timingText) }
    /// Centre of the first qualifying display, where injected activity counts.
    fileprivate func testTargetPoint() -> NSPoint? {
        let targets = Set(displayInfos().filter(\.isTarget).map(\.id))
        return NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return targets.contains(CGDirectDisplayID(number.uint32Value))
        }).map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }
}

@main struct RuntimeChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: \(name)") }
            count += 1
            print("PASS: \(name)")
            fflush(stdout)
        }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        // Engines
        let engine = try MetalBoostEngine()
        check(engine.testReusableAvailable(), "Metal 4 backend selected on this Mac")
        engine.start(strength: .gentle)
        Thread.sleep(forTimeInterval: 0.2)
        check(engine.testActive(), "real Metal engine starts")
        Thread.sleep(forTimeInterval: 3.2)
        check(!engine.testActive(), "real Metal engine expires without controller renewal")
        engine.start(strength: .gentle)
        Thread.sleep(forTimeInterval: 0.1)
        check(engine.testActive(), "engine restarts after expiry")
        engine.stop()
        check(!engine.testActive(), "explicit stop ends engine")

        let reusable = try ReusableBlitEngine()
        var telemetryCallbacks = 0
        reusable.setTelemetryHandler { _ in telemetryCallbacks += 1 }
        reusable.start()
        Thread.sleep(forTimeInterval: 1.8)
        check(reusable.testTelemetryCallbacks(telemetryCallbacks) >= 2, "feedback continues across reused command buffers")
        reusable.stop()
        check(!reusable.testActive(), "reusable engine stops")
        for _ in 0..<100 { reusable.start(); reusable.stop() }
        reusable.start()
        Thread.sleep(forTimeInterval: 0.15)
        check(reusable.testActive(), "rapid stop/restart retains allocator safety and resumes")
        reusable.stop()
        Thread.sleep(forTimeInterval: 0.05)
        check(reusable.testDrained(), "all lanes finish and drain after stop")
        var observedFailures = 0
        reusable.setFailureHandler { _ in observedFailures += 1 }
        reusable.start()
        reusable.testFault()
        check(!reusable.testActive() && observedFailures == 1, "synthetic failure stops new submissions and reports once")
        reusable.stop()

        let fallback = try MetalBoostEngine(useReusableBlits: false)
        check(!fallback.testReusableAvailable(), "forced original-backend fallback selected")
        fallback.start(strength: .gentle)
        check(fallback.testActive(), "original Gentle fallback starts")
        fallback.stop()
        check(!fallback.testActive(), "original fallback stops")
        engine.start(strength: .gentle)
        engine.updateStrength(.balanced)
        Thread.sleep(forTimeInterval: 0.1)
        check(engine.testLegacyActive(), "Gentle-to-Balanced switches to original engine")
        engine.updateStrength(.gentle)
        Thread.sleep(forTimeInterval: 0.1)
        check(engine.testReusableActive() && !engine.testLegacyActive(), "Balanced-to-Gentle returns to reusable engine")
        engine.stop()

        // Controller lifecycle
        _ = NSApplication.shared
        let controller = BoostController()
        check(controller.hasTargetDisplay, "a qualifying external display is connected")
        check(controller.testResources() == [true, true, true], "eligible display creates engine/input/timer")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        check(controller.testResources() == [false, false, false], "sleep notification releases engine/input/timer")
        check(!controller.isBoosting, "sleep is not boosting")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        check(controller.testResources() == [true, true, true], "wake notification restores resources")
        controller.mode = .off
        check(controller.testResources() == [false, false, false], "Off releases resources")
        controller.mode = .onInteraction
        check(controller.testResources() == [true, true, true], "activity mode resumes resources")
        controller.mode = .whileDocked
        check(controller.isBoosting, "bounded diagnostic starts")
        check(UserDefaults.standard.string(forKey: "boostMode") == "on_interaction", "bounded diagnostic never saved as login mode")
        controller.expireDiagnostic()
        check(controller.mode == .onInteraction && !controller.isBoosting, "expired diagnostic returns to idle activity mode")

        // Menu-bar indicator coalescing
        guard let point = controller.testTargetPoint() else {
            fatalError("FAIL: no qualifying display to inject activity on")
        }
        var publishes = 0
        let subscription = controller.objectWillChange.sink { publishes += 1 }
        controller.mode = .onScroll
        controller.testQuiesce()
        publishes = 0
        controller.testActivity(.scroll, at: point)
        check(controller.isBoosting && controller.testShown().0
            && controller.testShown().1 == "Boosting while scrolling", "burst starts and is shown at once")
        check(publishes == 2, "burst start publishes once per shown value")
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        check(controller.isBoosting, "harmless thermal change does not cut a burst short")
        controller.testQuiesce()
        spin(1.3)
        check(!controller.isBoosting, "GPU work still stops 0.9 seconds after the last activity")
        check(controller.testShown().0 && controller.testShown().1 == "Boosting while scrolling",
              "indicator lingers after the burst ends")
        let afterFirstBurst = publishes
        check(afterFirstBurst <= 3, "nothing but batch timing published during or after the first burst")
        controller.testActivity(.scroll, at: point)
        check(controller.isBoosting && publishes == afterFirstBurst, "a burst during the linger publishes nothing")
        spin(0.9 + 3.4)
        check(!controller.isBoosting && !controller.testShown().0
            && controller.testShown().1 == "Ready — waiting for scrolling"
            && controller.testShown().2.isEmpty, "indicator settles to idle after the hold")
        check(publishes <= 6, "two bursts publish at most 6 changes")
        controller.mode = .onInteraction
        controller.testQuiesce()
        controller.testActivity(.scroll, at: point)
        let shownStatus = controller.testShown().1
        let beforeFlip = publishes
        controller.testActivity(.drag, at: point)
        check(controller.isBoosting && controller.testShown().1 == shownStatus && publishes == beforeFlip,
              "a different activity type mid-burst publishes nothing")
        controller.mode = .onScroll
        controller.testQuiesce()
        controller.testActivity(.scroll, at: point)
        spin(1.3)
        check(!controller.isBoosting && controller.testShown().0, "lingering before Off")
        controller.mode = .off
        check(!controller.testShown().0 && controller.testShown().1 == "Off", "Off is shown immediately, without the linger")
        subscription.cancel()

        // Modes
        controller.mode = .onInteraction
        controller.testQuiesce()
        controller.testActivity(.pointer, at: point)
        check(!controller.isBoosting, "On activity ignores pointer movement")
        controller.mode = .whileInUse
        check(controller.testMonitorInstalled(), "While in use installs its input monitor")
        controller.testQuiesce()
        controller.testActivity(.pointer, at: point)
        check(controller.isBoosting && controller.testShown().1 == "Boosting while moving the pointer",
              "While in use boosts on pointer movement")
        spin(1.4)
        check(controller.isBoosting, "While in use is still boosting 1.4 seconds after the last movement")
        spin(0.9)
        check(!controller.isBoosting, "While in use stops 2 seconds after the last movement")
        controller.testActivity(.drag, at: point)
        check(controller.isBoosting, "While in use still boosts on drags")
        controller.mode = .onScroll
        check(!controller.isBoosting, "leaving While in use stops the boost")
        controller.testQuiesce()
        controller.testActivity(.scroll, at: point)
        spin(1.3)
        check(!controller.isBoosting, "other modes keep the 0.9 second tail")
        controller.mode = .off
        check(UserDefaults.standard.string(forKey: "boostMode") == "off", "mode is saved")
        check(BoostMode.restored(from: "while_in_use") == .whileInUse, "While in use is restored at launch")
        controller.mode = .alwaysDocked
        check(controller.isBoosting && controller.testShown().0, "Always while docked boosts with no input")
        check(!controller.testMonitorInstalled(), "Always while docked needs no input monitoring")
        check(UserDefaults.standard.string(forKey: "boostMode") == "always_docked"
            && BoostMode.restored(from: "always_docked") == .alwaysDocked, "Always while docked is saved and restored")
        spin(4.5)
        check(controller.isBoosting && controller.testEngineActive(), "continuous boost outlives the 3-second lease")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        check(!controller.isBoosting && controller.testResources() == [false, false, false], "display sleep stops the continuous boost")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        check(controller.isBoosting, "wake resumes the continuous boost")
        controller.mode = .onInteraction
        check(!controller.isBoosting && controller.testMonitorInstalled(), "leaving Always while docked returns to waiting for activity")

        // Screen lock
        check(!controller.testLocked(), "the live session reads as unlocked")
        controller.mode = .alwaysDocked
        controller.testSetLocked(true, reevaluate: true)
        check(!controller.isBoosting && controller.testResources() == [false, false, false]
            && controller.testShown().1 == "Paused while the screen is locked", "locking stops the continuous boost and releases everything")
        check(controller.testLockPolling(), "a locked screen keeps a 2-second unlock check running")
        controller.testSetLocked(false, reevaluate: false)
        spin(2.6)
        check(controller.isBoosting && controller.testEngineActive(), "unlock resumes the boost by polling alone, with no notification")
        check(!controller.testLockPolling(), "the unlock check stops once unlocked")
        controller.mode = .onInteraction
        controller.testSetLocked(true, reevaluate: true)
        controller.testActivity(.scroll, at: point)
        check(!controller.isBoosting && controller.testResources() == [false, false, false], "activity modes also stay off while locked")
        controller.testSetLocked(false, reevaluate: true)
        check(controller.testResources() == [true, true, true], "activity modes resume on unlock")

        // Pause policy
        func env(_ mode: BoostMode, locked: Bool = false, target: Bool = true, ac: Bool = true) -> String? {
            BoostEnvironment(mode: mode, screensAreAwake: true, screenIsLocked: locked, usingACPower: ac,
                             thermalState: .nominal, hasTargetDisplay: target).pauseReason
        }
        check(env(.alwaysDocked) == nil && env(.alwaysDocked, locked: true) != nil, "lock is a pause reason in its own right")
        check(BoostMode.allCases.filter { $0 != .off }.allSatisfy { env($0, target: false) != nil },
              "no mode runs without a qualifying external display")
        check(BoostMode.allCases.filter { $0 != .off }.allSatisfy { env($0, ac: false) != nil }, "no mode runs on battery")
        check(!DisplayInfo(id: 1, isBuiltin: true, name: "Built-in", pixelWidth: 7680, pixelHeight: 4320, refreshRate: 120).isTarget,
              "the built-in display never qualifies, whatever its resolution or refresh rate")
        check(DisplayInfo(id: 2, isBuiltin: false, name: "Ultrawide", pixelWidth: 5120, pixelHeight: 2160, refreshRate: 120).isTarget,
              "a 5120×2160 120 Hz external display qualifies")
        check(!DisplayInfo(id: 3, isBuiltin: false, name: "Ultrawide", pixelWidth: 5120, pixelHeight: 2160, refreshRate: 60).isTarget,
              "the same display at 60 Hz does not")
        controller.mode = .off
        print("RUNTIME_CHECKS: \(count) passed")
    }
}
