import AppKit
import Carbon

final class InputSurface: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
struct ReceivedInput: Codable {
    var input: RecordedInput
    var receivedAt: Double
}
final class InputTarget: NSApplication, NSApplicationDelegate {
    var targetWindow: NSWindow!
    var output: URL!
    var rows: [ReceivedInput] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        targetWindow = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 500, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        targetWindow.title = "Click Recorder — disposable input test"
        let surface = InputSurface(frame: targetWindow.contentView!.bounds)
        targetWindow.contentView = surface
        targetWindow.acceptsMouseMovedEvents = true
        targetWindow.makeKeyAndOrderFront(nil); targetWindow.makeFirstResponder(surface)
        activate(ignoringOtherApps: true)
        let point = CGPoint(x: targetWindow.frame.minX + 100, y: NSScreen.screens.first!.frame.maxY - targetWindow.frame.maxY + 100)
        try? JSONEncoder().encode([point.x, point.y]).write(to: output.appendingPathExtension("ready"), options: .atomic)
        Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in NSApp.terminate(nil) }
    }
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        guard let cg = event.cgEvent, let input = recordedInput(cg, type: cg.type, time: Double(cg.timestamp) / 1_000_000_000) else { return }
        rows.append(ReceivedInput(input: input, receivedAt: ProcessInfo.processInfo.systemUptime))
        if let data = try? JSONEncoder().encode(rows) { try? data.write(to: output, options: .atomic) }
    }
}

enum LiveTests {
    static func target(_ path: String) {
        let app = InputTarget.shared as! InputTarget
        app.output = URL(fileURLWithPath: path); app.setActivationPolicy(.regular); app.delegate = app; app.run()
    }
    static func run() throws {
        let listen = CGPreflightListenEventAccess()
        let post = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        print("Live permissions: listen=\(listen), post=\(post)")
        guard listen && post else { print("BLOCKED: live test requires Input Monitoring and Accessibility."); exit(77) }
        let application = NSApplication.shared; application.setActivationPolicy(.accessory)
        let a = App()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClickRecorderLive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ClickRecorderLive." + UUID().uuidString
        a.preferences = UserDefaults(suiteName: suite)!
        a.store = RecordingStore(directory: directory.appendingPathComponent("recordings"))
        a.status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); a.status.menu = NSMenu()
        a.alertSink = { title, detail in print("APP: \(title) \(detail)") }
        a.preferences.set(["G", "H", "J"], forKey: "keys")
        a.installHotKeyHandler(); a.registerHotKeys(); a.observeEnvironment()
        guard a.hotKeyOK else { print("BLOCKED: live test shortcut conflict"); exit(77) }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPoint = CGEvent(source: nil)?.location
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let log = directory.appendingPathComponent("events.json")
        process.arguments = ["--input-target", log.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            a.stopEverything(); a.hotKeys.forEach { UnregisterEventHotKey($0) }
            if process.isRunning { process.terminate() }
            a.preferences.removePersistentDomain(forName: suite)
            if let previousPoint { CGWarpMouseCursorPosition(previousPoint) }
            previousApp?.activate(options: [])
            try? FileManager.default.removeItem(at: directory)
        }
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let event = application.nextEvent(matching: .any, until: Date().addingTimeInterval(0.002), inMode: .default, dequeue: true) { application.sendEvent(event) }
            }
        }
        func rows() -> [ReceivedInput] { (try? JSONDecoder().decode([ReceivedInput].self, from: Data(contentsOf: log))) ?? [] }
        func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "LiveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            print("PASS LIVE: \(label)")
        }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: log.appendingPathExtension("ready").path) { break }; pump(0.05) }
        let xy = try JSONDecoder().decode([Double].self, from: Data(contentsOf: log.appendingPathExtension("ready")))
        let x = xy[0], y = xy[1]
        let source = CGEventSource(stateID: .privateState)
        func send(_ input: RecordedInput, pause: Double = 0.04) {
            makeInputEvent(input, source: source, tag: 0)?.post(tap: .cghidEventTap); pump(pause)
        }
        func hotkey(_ code: UInt16) {
            send(RecordedInput(time: 0, kind: .keyDown, flags: (1 << 18) | (1 << 19) | (1 << 20), keyCode: code))
            send(RecordedInput(time: 0, kind: .keyUp, keyCode: code))
        }
        hotkey(5); try require(a.mode == .countdown, "global record shortcut starts countdown")
        pump(3.1); try require(a.mode == .recording && a.tap != nil, "real event tap starts after three seconds")
        let firstIndex = rows().count
        let shift: UInt64 = 1 << 17
        let inputs: [RecordedInput] = [
            RecordedInput(time: 0, kind: .move, x: x, y: y),
            RecordedInput(time: 0, kind: .mouseDown, x: x, y: y, button: 0, clickCount: 1),
            RecordedInput(time: 0, kind: .drag, x: x + 20, y: y + 10, deltaX: 20, deltaY: 10, button: 0, clickCount: 1),
            RecordedInput(time: 0, kind: .modifiers, flags: shift, keyCode: 56),
            RecordedInput(time: 0, kind: .keyDown, flags: shift, keyCode: 0, isRepeat: false),
            RecordedInput(time: 0, kind: .drag, flags: shift, x: x + 40, y: y + 20, deltaX: 20, deltaY: 10, button: 0, clickCount: 1),
            RecordedInput(time: 0, kind: .keyDown, flags: shift, keyCode: 0, isRepeat: true),
            RecordedInput(time: 0, kind: .keyUp, flags: shift, keyCode: 0, isRepeat: false),
            RecordedInput(time: 0, kind: .modifiers, keyCode: 56),
            RecordedInput(time: 0, kind: .mouseUp, x: x + 40, y: y + 20, button: 0, clickCount: 1),
            RecordedInput(time: 0, kind: .mouseDown, x: x + 40, y: y + 20, button: 1, clickCount: 1),
            RecordedInput(time: 0, kind: .mouseUp, x: x + 40, y: y + 20, button: 1, clickCount: 1),
            RecordedInput(time: 0, kind: .mouseDown, x: x + 40, y: y + 20, button: 0, clickCount: 2),
            RecordedInput(time: 0, kind: .mouseUp, x: x + 40, y: y + 20, button: 0, clickCount: 2),
            RecordedInput(time: 0, kind: .scroll, x: x + 40, y: y + 20, scroll: ScrollInput(vertical: -3, horizontal: 2)),
            RecordedInput(time: 0, kind: .scroll, x: x + 40, y: y + 20, scroll: ScrollInput(vertical: 1, horizontal: -1, pointVertical: 8, pointHorizontal: -4, fixedVertical: 1.5, fixedHorizontal: -0.5, continuous: 1, phase: 2)),
            RecordedInput(time: 0, kind: .move, x: x + 60, y: y + 30, deltaX: 20, deltaY: 10)
        ]
        for (index, input) in inputs.enumerated() { send(input, pause: index == 5 ? 0.18 : 0.04) }
        pump(0.15); hotkey(5)
        try require(a.mode == .idle && a.recordings.count == 1, "global stop persists one unified timeline")
        let saved = a.recordings[0]
        let restored = a.store.load().0[0]
        try require(saved.timeline == restored.timeline, "disk restore preserves every field and event order")
        try require(Set(saved.timeline!.map(\.kind)).isSuperset(of: [.move, .drag, .scroll, .keyDown, .keyUp, .mouseDown, .mouseUp, .modifiers]), "all mouse/keyboard event kinds captured")
        a.recordings = [restored]; a.selected = restored.id
        let recordedRows = Array(rows().dropFirst(firstIndex))
        func relevant(_ rows: [ReceivedInput]) -> [ReceivedInput] {
            rows.filter { ![UInt16(5), 4, 38].contains($0.input.keyCode ?? 999) }
        }
        func signature(_ row: ReceivedInput) -> String {
            var input = row.input; input.time = 0
            input.flags &= modifierMask
            // OS may add a non-semantic pressure default to pointer motion.
            if input.kind == .move { input.pressure = nil }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(data: try! encoder.encode(input), encoding: .utf8)!
        }
        let original = relevant(recordedRows)
        for repetition in 1...3 {
            let index = rows().count
            hotkey(4); pump(restored.duration + 0.25)
            try require(a.mode == .idle, "replay \(repetition) completes")
            let replay = relevant(Array(rows().dropFirst(index)))
            let before = original.map(signature), after = replay.map(signature)
            if before != after { print("expected=\(before)\nactual=\(after)") }
            try require(!before.isEmpty && before == after, "replay \(repetition) preserves target event order, coordinates, drag, wheel and chord")
            let errors = zip(original, replay).map { abs(($1.receivedAt - replay[0].receivedAt) - ($0.receivedAt - original[0].receivedAt)) * 1000 }.sorted()
            let maximum = errors.last!, p95 = errors[Int(Double(errors.count - 1) * 0.95)]
            print(String(format: "TIMING replay %d: count=%d p95=%.3f ms max=%.3f ms", repetition, errors.count, p95, maximum))
            try require(maximum <= 25, "replay \(repetition) relative target-arrival error <= 25 ms")
            let firstExpected = restored.timeline![0].time
            let leadingError = abs((replay[0].receivedAt - a.lastPlaybackStart) - firstExpected) * 1000
            print(String(format: "TIMING replay %d: leading error=%.3f ms", repetition, leadingError))
            try require(leadingError <= 25, "replay \(repetition) leading wait error <= 25 ms")
        }
        let heldInputs = [RecordedInput(time: 0, kind: .keyDown, keyCode: 0), RecordedInput(time: 0.9, kind: .keyUp, keyCode: 0)]
        let held = Recording(version: 3, name: "held-key-stop", duration: 1, screens: a.layouts(), clicks: [], timeline: heldInputs)
        a.recordings.append(held); a.selected = held.id
        let cancelIndex = rows().count
        hotkey(4); pump(0.1); hotkey(38); pump(1.1)
        let canceled = rows().dropFirst(cancelIndex).filter { $0.input.keyCode == 0 }
        try require(a.mode == .idle && canceled.count == 2 && canceled.last?.input.kind == .keyUp, "real emergency shortcut releases held key and cancels later input")
        print("PASS: live full-input capture → disk restore → three timed replays → independent AppKit receiver → emergency stop")
    }
}
