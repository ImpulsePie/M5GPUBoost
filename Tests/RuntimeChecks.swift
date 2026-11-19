// Runtime checks for M5GPUBoost. run-runtime-checks.command appends this file
// to Sources/M5GPUBoost.swift, minus its @main app, so the extensions below
// can reach private state. They run the real Metal engines and controller.

extension OriginalBoostEngine {
    fileprivate func testActive() -> Bool { worker.sync { active } }
    fileprivate func testSync<T>(_ value: @autoclosure () -> T) -> T { worker.sync { value() } }
    /// Orphans the work in flight, as if its completions never arrived.
    fileprivate func testStall() {
        worker.sync {
            generation &+= 1
            lastProgress = DispatchTime.now().uptimeNanoseconds &- 3_000_000_000
        }
    }
}
extension Metal4BoostEngine {
    fileprivate func testActive() -> Bool { worker.sync { active } }
    fileprivate func testDrained() -> Bool { worker.sync { !lanes.contains(where: { $0.busy }) } }
    fileprivate func testFault() { worker.sync { fail("Synthetic runtime test fault") } }
    /// Marks a lane as submitted three seconds ago with no feedback since.
    fileprivate func testStall() {
        worker.sync {
            lanes[0].busy = true
            lanes[0].submittedAt = DispatchTime.now().uptimeNanoseconds &- 3_000_000_000
        }
    }
    fileprivate func testSync<T>(_ value: @autoclosure () -> T) -> T { worker.sync { value() } }
}
extension MetalBoostEngine {
    fileprivate func testActive() -> Bool { (original?.testActive() ?? false) || (metal4?.testActive() ?? false) }
    fileprivate func testMetal4Available() -> Bool { metal4 != nil }
    fileprivate func testMetal4Active() -> Bool { metal4?.testActive() ?? false }
    fileprivate func testOriginalActive() -> Bool { original?.testActive() ?? false }
    fileprivate func testFaultMetal4() { metal4?.testFault() }
}
extension BoostController {
    fileprivate func testResources() -> [Bool] { [engine != nil, interactionMonitor != nil, refreshTimer != nil] }
    /// Stops real input and the polling timer from reaching this controller,
    /// so the timed checks below see only the activity they inject.
    fileprivate func testQuiesce() {
        removeEventMonitor()
        refreshTimer?.invalidate()
        refreshTimer = nil
        lastInteractionCheck = .infinity
    }
    /// A power or thermal notification can reinstall the input monitor at any
    /// moment, so the throttle is also left closed after each injection.
    /// Real input and app switches then can't extend the burst being timed.
    fileprivate func testActivity(_ activity: BoostActivity, at point: NSPoint) {
        lastInteractionCheck = -Double.infinity
        handleInteraction(activity, at: point)
        lastInteractionCheck = .infinity
    }
    fileprivate func testEngineActive() -> Bool { engine?.testActive() ?? false }
    fileprivate func testLocked() -> Bool { screenIsLocked }
    fileprivate func testLockPolling() -> Bool { lockPollTimer != nil }
    fileprivate func testSetLocked(_ locked: Bool, reevaluate now: Bool) {
        lockStateProvider = { locked }
        if now { reevaluate(periodic: true) }
    }
    fileprivate func testMonitorInstalled() -> Bool { interactionMonitor != nil }
    fileprivate func testShown() -> (Bool, String, String) { (showsBoosting, statusText, readoutText) }
    fileprivate static func testACPower() -> Bool { isUsingACPower() }
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
        check(engine.testMetal4Available(), "Metal 4 backend selected on this Mac")
        engine.start()
        Thread.sleep(forTimeInterval: 0.2)
        check(engine.testActive(), "real Metal engine starts")
        Thread.sleep(forTimeInterval: 3.2)
        check(!engine.testActive(), "real Metal engine expires without controller renewal")
        engine.start()
        Thread.sleep(forTimeInterval: 0.1)
        check(engine.testActive(), "engine restarts after expiry")
        engine.stop()
        check(!engine.testActive(), "explicit stop ends engine")

        let metal4 = try Metal4BoostEngine()
        metal4.start()
        Thread.sleep(forTimeInterval: 1.0)
        let metal4Loop = metal4.takeLoopSample()
        check((metal4Loop?.batchesPerSecond ?? 0) > 1_000 && (metal4Loop?.gpuMicrosecondsPerBatch ?? 0) > 0,
              "feedback continues across reused command buffers")
        metal4.stop()
        check(!metal4.testActive(), "Metal 4 engine stops")
        check(metal4.takeLoopSample() == nil, "a stopped engine reports no loop sample")
        for _ in 0..<100 { metal4.start(); metal4.stop() }
        metal4.start()
        Thread.sleep(forTimeInterval: 0.15)
        check(metal4.testActive(), "rapid stop/restart retains allocator safety and resumes")
        metal4.stop()
        Thread.sleep(forTimeInterval: 0.05)
        check(metal4.testDrained(), "all lanes finish and drain after stop")
        var observedFailures = 0
        metal4.setFailureHandler { _ in observedFailures += 1 }
        metal4.start()
        metal4.testFault()
        check(!metal4.testActive() && metal4.testSync(observedFailures) == 1,
              "synthetic failure stops new submissions and reports once")
        metal4.stop()

        let stalled = try Metal4BoostEngine()
        var stallReports = 0
        stalled.setFailureHandler { _ in stallReports += 1 }
        stalled.start()
        Thread.sleep(forTimeInterval: 0.1)
        stalled.stop()
        Thread.sleep(forTimeInterval: 0.1)
        stalled.testStall()
        stalled.start()
        check(!stalled.testActive() && stalled.testSync(stallReports) == 1,
              "a lane with no feedback for 2 seconds is reported at the next start")

        // Runtime fallback
        check(engine.testMetal4Available(), "router still on Metal 4 before the fault")
        var notes = 0, terminalFailures = 0
        engine.setNoteHandler { _ in notes += 1 }
        engine.setFailureHandler { _ in terminalFailures += 1 }
        engine.start()
        Thread.sleep(forTimeInterval: 0.1)
        engine.testFaultMetal4()
        spin(0.3)
        check(!engine.testMetal4Available() && engine.testOriginalActive() && notes == 1 && terminalFailures == 0,
              "a Metal 4 failure while boosting hands over to the original backend")
        _ = engine.takeLoopSample()
        Thread.sleep(forTimeInterval: 1.0)
        check((engine.takeLoopSample()?.batchesPerSecond ?? 0) > 1_000, "the original backend keeps submitting after the handover")
        engine.stop()
        check(!engine.testActive(), "stop still ends the engine after the handover")

        let fallback = try MetalBoostEngine(useMetal4: false)
        check(!fallback.testMetal4Available(), "forced original-backend fallback selected")
        fallback.start()
        check(fallback.testActive(), "original backend starts")
        fallback.stop()
        check(!fallback.testActive(), "original backend stops")

        let original = try OriginalBoostEngine()
        var originalFailures = 0
        original.setFailureHandler { _ in originalFailures += 1 }
        original.start()
        Thread.sleep(forTimeInterval: 0.3)
        original.testStall()
        Thread.sleep(forTimeInterval: 0.2)
        _ = original.takeLoopSample()
        Thread.sleep(forTimeInterval: 0.3)
        check(original.takeLoopSample() == nil, "orphaned work leaves the original loop stalled")
        original.start()
        Thread.sleep(forTimeInterval: 0.5)
        check((original.takeLoopSample()?.batchesPerSecond ?? 0) > 1_000 && original.testSync(originalFailures) == 0,
              "the next start restarts stalled lanes on the original backend")
        Thread.sleep(forTimeInterval: 3.2)
        check(!original.testActive(), "original backend expires without renewal")

        // GPU clock
        check(BoostController.readout(clock: .init(mainShare: 0.999, secondShare: 0.98, megahertz: 1620), loop: nil)
            == "GPU clock held at 1620 MHz", "a full hold reads as held")
        check(BoostController.readout(clock: .init(mainShare: 1, secondShare: 0.23, megahertz: 1620), loop: nil)
            == "GPU clock at 1620 MHz 23% of the time", "the readout follows the weaker of the two channels")
        check(BoostController.readout(clock: .init(mainShare: 1, secondShare: nil, megahertz: nil), loop: nil)
            == "GPU clock held at its top speed", "the readout works without a second channel or a frequency")
        check(BoostController.readout(clock: nil, loop: LoopSample(batchesPerSecond: 18_400, gpuMicrosecondsPerBatch: 4))
            == "Submitting about 18,000 GPU batches a second", "the submission rate is shown where the clock can't be read")
        check(BoostController.readout(clock: .init(mainShare: 1, secondShare: 1, megahertz: 1620), loop: nil, session: 0.99872)
            == "GPU clock held at 1620 MHz (99.8% this session)", "the session figure is added once there is a minute of it, rounded down")
        let metal4Hold = try Metal4BoostEngine()
        guard let monitor = GPUClockMonitor.shared else { fatalError("FAIL: GPU clock states can't be read on this Mac") }
        check(true, "GPU clock states can be read on this Mac")
        for (name, start, stop) in [
            ("Metal 4", { metal4Hold.start() }, { metal4Hold.stop() }),
            ("original", { original.start() }, { original.stop() }),
        ] as [(String, () -> Void, () -> Void)] {
            start()
            Thread.sleep(forTimeInterval: 0.5)
            monitor.mark()
            for _ in 0..<3 { Thread.sleep(forTimeInterval: 1); start() }
            let reading = monitor.read()
            stop()
            print(String(format: "      %@: GPUPH %.1f%%, AFRSTATE %.1f%% in the top state",
                         name, (reading?.mainShare ?? 0) * 100, (reading?.secondShare ?? 0) * 100))
            // Run from a terminal, this process is deprioritised whenever the
            // terminal's app isn't in front, which lowers both channels
            // together. What must never happen is the second one trailing
            // the first, as it did with the four-byte fill.
            let main = reading?.mainShare ?? 0, second = reading?.secondShare ?? main
            check(main >= 0.5 && second >= main - 0.1, "the \(name) backend holds the second GPU clock channel as well as the first")
        }
        Thread.sleep(forTimeInterval: 1.0)
        monitor.mark()
        Thread.sleep(forTimeInterval: 1.0)
        check((monitor.read()?.heldShare ?? 1) < 0.5, "the clock falls again once the work stops")

        // Controller lifecycle
        _ = NSApplication.shared
        check(BoostController.testACPower(), "mains power is detected")
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
        check(BoostMode.restored(from: "while_docked") == .onInteraction && BoostMode.restored(from: "Continuous") == .onInteraction,
              "retired always-on modes are restored as On activity")

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
        check(controller.isBoosting && publishes == 2, "harmless thermal change does not cut a burst short or publish")
        controller.testQuiesce()
        spin(1.3)
        check(!controller.isBoosting, "GPU work still stops 0.9 seconds after the last activity")
        check(controller.testShown().0 && controller.testShown().1 == "Boosting while scrolling",
              "indicator lingers after the burst ends")
        let afterFirstBurst = publishes
        check(afterFirstBurst == 3 && !controller.testShown().2.isEmpty, "the burst's clock readout is the only other publish")
        print("      \(controller.testShown().2)")
        controller.testActivity(.scroll, at: point)
        check(controller.isBoosting && publishes == afterFirstBurst, "a burst during the linger publishes nothing")
        spin(0.9 + 3.4)
        check(!controller.isBoosting && !controller.testShown().0
            && controller.testShown().1 == "Ready — waiting for scrolling"
            && controller.testShown().2.isEmpty, "indicator settles to idle after the hold")
        check(publishes <= 7, "two bursts publish at most 7 changes")
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
        print("      \(controller.testShown().2)")
        check(controller.testShown().2.hasPrefix("GPU clock "), "the menu reports the GPU clock in Always while docked")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        check(!controller.isBoosting && controller.testResources() == [false, false, false], "display sleep stops the continuous boost")
        check(controller.testShown().2.isEmpty, "the readout clears when the boost is paused")
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
        check(DisplayInfo(id: 4, isBuiltin: false, name: "Ultrawide", pixelWidth: 5120, pixelHeight: 2160, refreshRate: 0,
                          maximumFramesPerSecond: 120).isTarget
            && !DisplayInfo(id: 5, isBuiltin: false, name: "Ultrawide", pixelWidth: 5120, pixelHeight: 2160, refreshRate: 0,
                            maximumFramesPerSecond: 60).isTarget,
              "an adaptive mode reporting 0 Hz qualifies by the screen's fastest refresh")
        controller.mode = .off
        print("RUNTIME_CHECKS: \(count) passed")
    }
}
