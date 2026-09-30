import AppKit
import Carbon

@main
enum AppTests {
    static var checks = 0
    static var apps: [App] = []
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClickRecorderController-" + UUID().uuidString)
    static let screen = ScreenLayout(id: 1, x: 0, y: 0, width: 1920, height: 1080, pixelsWide: 3840, pixelsHigh: 2160)
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("FAIL: " + name) }
        checks += 1
    }
    static func pump(_ seconds: Double, mode: RunLoop.Mode = .default) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.002)) }
    }
    static func app() -> App {
        let app = App()
        let id = UUID().uuidString
        app.preferences = UserDefaults(suiteName: "ClickRecorderTests." + id)!
        app.store = RecordingStore(directory: root.appendingPathComponent(id))
        app.status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        app.status.menu = NSMenu()
        app.canListen = { true }; app.canPost = { true }; app.secureInput = { false }
        app.physicalModifiers = { 0 }; app.screenProvider = { [screen] }; app.frontmostPID = { -1 }
        app.useEventTimestamps = false; app.installCaptureTap = false; app.hotKeyOK = true
        app.alertSink = { _, _ in }
        app.eventSink = { _ in }
        apps.append(app)
        return app
    }
    static func recording(duration: Double = 0.12, keys: [KeyInput]? = nil) -> Recording {
        Recording(version: 2, name: "controller", duration: duration, screens: [screen],
                  clicks: keys == nil ? [Click(down: 0.025, up: 0.05, x: 100, y: 100, button: 0, count: 1)] : [], keys: keys)
    }
    static func select(_ app: App, _ record: Recording) { app.recordings = [record]; app.selected = record.id }
    static func key(_ code: UInt16, _ down: Bool, flags: UInt64 = 0) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = CGEventFlags(rawValue: flags)
        return event
    }
    static func mouse(_ type: CGEventType, button: CGMouseButton = .left) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 100, y: 100), mouseButton: button)!
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: -1)
        return event
    }
    static func main() throws {
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--input-target" { LiveTests.target(CommandLine.arguments[2]); return }
        if CommandLine.arguments.contains("--live") { try LiveTests.run(); return }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        defer {
            for app in apps {
                app.stopEverything()
                app.hotKeys.forEach { UnregisterEventHotKey($0) }
                app.environmentObservers.forEach { NotificationCenter.default.removeObserver($0) }
                app.workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
                NSStatusBar.system.removeStatusItem(app.status)
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let a = app(); select(a, recording())
            var emitted = 0; a.eventSink = { _ in emitted += 1 }
            a.playFromMenu(); check(a.mode == .preparing, "menu reserves playback state")
            a.stopEverything(); pump(0.25)
            check(a.mode == .idle && emitted == 0, "stop cancels delayed menu playback")
            a.playFromMenu(); a.playFromMenu(); pump(0.36)
            check(emitted == 2 && a.mode == .idle, "repeated menu request produces only one replay")
        }
        do {
            let a = app(); select(a, recording())
            var times: [Double] = []; let start = a.now
            a.eventSink = { _ in times.append(a.now - start) }
            a.play(); pump(0.075)
            check(times.count == 2 && a.mode == .playing, "trailing wait preserved")
            check(times[0] >= 0.02 && times[1] >= 0.045, "leading and inter-event wait preserved")
            pump(0.08); check(a.mode == .idle && a.pendingWork == nil, "natural completion releases scheduled work")
        }
        do {
            let a = app(); select(a, recording())
            var emitted = 0; a.eventSink = { _ in emitted += 1 }
            var modifiers: UInt64 = 1 << 20; a.physicalModifiers = { modifiers }
            a.play(); pump(0.04)
            check(a.mode == .preparing && emitted == 0, "wait for physical shortcut release")
            modifiers = 0; pump(0.2)
            check(a.mode == .idle && emitted == 2, "replay after shortcut release")
            modifiers = 1 << 20; a.play()
            a.preparePlayback(a.current!, generation: a.ticket.generation, earliest: 0, timeout: 0)
            check(a.mode == .idle, "held shortcut times out")
        }
        do {
            let a = app()
            let command: UInt64 = 1 << 20
            select(a, recording(duration: 0.15, keys: [KeyInput(time: 0, code: 0, isDown: true, flags: command), KeyInput(time: 0.13, code: 0, isDown: false, flags: command)]))
            var events: [CGEvent] = []; a.eventSink = { events.append($0) }
            a.play(); pump(0.02); check(a.heldPlaybackKeys == [0], "key held during playback")
            a.stopEverything(); let count = events.count; pump(0.18)
            check(events.count == count && a.heldPlaybackKeys.isEmpty && a.playbackModifiers == 0, "cancel invalidates callbacks and releases modifiers")
            check(events.contains { $0.type == .keyUp && $0.getIntegerValueField(.keyboardEventKeycode) == 0 }, "cancel emits actual key release")
            check(events.last?.type == .flagsChanged && events.last?.flags.rawValue == 0, "cancel emits modifier release")
            a.stopEverything(); check(events.count == count, "stop is idempotent")
        }
        do {
            let a = app(); select(a, recording(duration: 1))
            var events: [CGEventType] = []; a.eventSink = { events.append($0.type) }
            a.play(); pump(0.035); a.stopEverything(); pump(0.04)
            check(events == [.leftMouseDown, .leftMouseUp], "cancel releases held mouse exactly once")
        }
        for failure in ["permission", "screen", "secure"] {
            let a = app(); select(a, recording())
            var emitted: [CGEventType] = []
            a.eventSink = { event in
                emitted.append(event.type)
                if event.type == .leftMouseDown {
                    if failure == "permission" { a.canPost = { false } }
                    if failure == "screen" { a.screenProvider = { [] } }
                    if failure == "secure" { a.secureInput = { true } }
                }
            }
            a.play(); pump(0.15)
            check(a.mode == .idle && emitted == [.leftMouseDown, .leftMouseUp], "\(failure) change stops replay and releases mouse")
        }
        do {
            let a = app(); select(a, recording(duration: 100))
            a.observeEnvironment(); a.play(); pump(0.07)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            check(a.mode == .idle, "screen notification cancels long trailing wait immediately")
            a.playFromMenu()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            check(a.mode == .idle, "sleep cancels pending start")
            a.playFromMenu()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            check(a.mode == .idle, "user switch cancels pending start")
        }
        do {
            let a = app(); a.countdownInterval = 0.01; a.recordLimit = 0.05
            a.toggleRecord(); check(a.mode == .countdown, "countdown begins")
            pump(0.04, mode: .eventTracking)
            check(a.mode == .recording, "countdown fires while menu is tracking")
            a.capture(.keyDown, key(0, true))
            pump(0.06, mode: .eventTracking)
            check(a.mode == .idle && a.recordings.count == 1, "auto-stop fires while menu is tracking")
            check(a.recordings[0].duration == 0.05 && a.recordings[0].timeline?.last?.kind == .keyUp, "auto-stop balances held key at limit")
            check(a.tap == nil && a.source == nil && a.timer == nil && a.captureSession.events.isEmpty, "recording resources released")
        }
        do {
            let a = app(); a.countdownInterval = 0.01
            a.toggleRecord(); a.stopEverything(); pump(0.05)
            check(a.mode == .idle && a.timer == nil, "cancel countdown never starts recording")
            a.toggleRecord(); a.secureInput = { true }; pump(0.05)
            check(a.mode == .idle && a.tap == nil, "secure input rechecked after countdown")
            a.secureInput = { false }; a.toggleRecord(); a.canListen = { false }; pump(0.05)
            check(a.mode == .idle, "permission rechecked after countdown")
        }
        do {
            let a = app(); var time = 1.0; a.clock = { time }; a.mode = .countdown; a.beginRecording()
            time = 1.1; a.capture(.keyDown, key(0, true))
            a.frontmostPID = { ProcessInfo.processInfo.processIdentifier }
            time = 1.2; a.capture(.keyUp, key(0, false))
            a.capture(.keyDown, key(1, true)); a.capture(.keyUp, key(1, false))
            a.frontmostPID = { -1 }
            let tagged = key(2, true); tagged.setIntegerValueField(.eventSourceUserData, value: ownTag)
            a.capture(.keyDown, tagged)
            time = 1.3; a.finishRecording()
            check(a.recordings[0].timeline?.count == 2, "own UI and tagged events excluded without losing prior release")
            check(abs(a.recordings[0].timeline![1].time - 0.2) < 0.0001, "focus change retains actual release time")
            check(a.store.load().0.count == 1, "controller saves valid file")
        }
        do {
            let a = app(); a.mode = .countdown; a.beginRecording()
            a.capture(.leftMouseDown, mouse(.leftMouseDown)); a.capture(.leftMouseDragged, mouse(.leftMouseDragged)); a.capture(.leftMouseUp, mouse(.leftMouseUp))
            a.menuOpen = true; a.capture(.leftMouseDown, mouse(.leftMouseDown)); a.capture(.leftMouseUp, mouse(.leftMouseUp)); a.menuOpen = false
            a.capture(.rightMouseDown, mouse(.rightMouseDown, button: .right)); a.capture(.rightMouseUp, mouse(.rightMouseUp, button: .right))
            a.finishRecording()
            check(a.recordings.count == 1 && a.recordings[0].clickCount == 2 && a.recordings[0].timeline!.contains { $0.kind == .drag }, "controller captures drag/right click and excludes own menu")
        }
        do {
            let a = app(); a.mode = .countdown; a.beginRecording()
            a.capture(.keyDown, key(0, true)); a.secureInput = { true }; a.capture(.keyDown, key(1, true))
            check(a.mode == .idle && a.recordings[0].timeline?.count == 2, "secure input mid-recording ends and balances input")
            a.secureInput = { false }; a.mode = .countdown; a.beginRecording()
            a.capture(.tapDisabledByTimeout, key(0, true))
            check(a.mode == .idle && a.tap == nil, "disabled event tap ends recording")
        }
        do {
            let a = app(); let target = a.store.directory
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: target)
            a.mode = .countdown; a.beginRecording(); a.capture(.keyDown, key(0, true)); a.finishRecording()
            check(a.unsavedRecording != nil && a.recordings.isEmpty, "storage failure retains unsaved data")
            a.toggleRecord(); check(a.mode == .idle, "new recording cannot overwrite unsaved data")
            check(a.applicationShouldTerminate(application) == .terminateCancel, "normal quit cannot discard failed save")
            try FileManager.default.removeItem(at: target)
            a.retrySave()
            check(a.unsavedRecording == nil && a.recordings.count == 1 && a.store.load().0.count == 1, "retry saves retained recording")
            check(a.applicationShouldTerminate(application) == .terminateNow, "quit allowed after save")
        }
        do {
            let a = app(); select(a, recording())
            a.modalDepth = 1; a.play(); a.toggleRecord()
            check(a.mode == .idle, "dialogs block starting input actions")
            a.modalDepth = 0; a.canPost = { false }; a.play()
            check(a.mode == .idle, "missing playback permission blocks start")
            a.canPost = { true }; a.screenProvider = { [] }; a.play()
            check(a.mode == .idle, "screen mismatch blocks start")
            a.screenProvider = { [screen] }; a.recordings[0].duration = -1; a.play()
            check(a.mode == .idle, "invalid recording blocks playback")
        }
        // Real Carbon registration tests, without injecting input into other apps.
        do {
            let a = app(); a.preferences.set(["G", "H", "J"], forKey: "keys"); a.registerHotKeys()
            check(a.hotKeyOK && a.hotKeys.count == 3, "global hotkeys register")
            let b = app(); b.preferences.set(["G", "H", "J"], forKey: "keys"); b.registerHotKeys()
            check(!b.hotKeyOK && b.hotKeys.isEmpty, "conflict rolls back partial registration")
            b.preferences.set(["K", "L", "M"], forKey: "keys"); b.registerHotKeys()
            check(b.hotKeyOK, "alternate hotkeys register")
            b.keyFields = ["G", "H", "J"].map { NSTextField(string: $0) }; b.saveSettings()
            check(b.hotKeyOK && b.keyNames() == ["K", "L", "M"], "failed settings restore previously working shortcuts")
        }
        print("PASS: \(checks) controller assertions (timers, playback, cancellation, permissions, capture, storage, notifications, real Carbon registration)")
    }
}
