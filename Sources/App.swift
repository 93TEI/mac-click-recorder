import AppKit
import Carbon
import CoreGraphics

let ownTag: Int64 = 0x434C49434B
private let hotKeySignature: OSType = 0x434C494B

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var store = RecordingStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClickRecorder/Recordings"))
    var preferences = UserDefaults.standard
    var modalDepth = 0
    var menuOpen = false
    var status: NSStatusItem!
    var recordings: [Recording] = []
    var selected: UUID? {
        didSet { preferences.set(selected?.uuidString, forKey: "selected") }
    }
    enum Mode { case idle, countdown, recording, preparing, playing }
    var mode: Mode = .idle
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var timer: Timer?
    var pendingWork: DispatchWorkItem?
    let ticket = PlaybackTicket()
    var playbackRun: PlaybackRun?
    var playbackTimer: DispatchSourceTimer?
    var lastPlaybackStart: TimeInterval = 0
    var recordingStart: TimeInterval = 0
    var recordingStartTimestamp: UInt64 = 0
    var lastCaptureTime: TimeInterval = 0
    var useEventTimestamps = true
    var recordingScreens: [ScreenLayout] = []
    var captureSession = TimelineCapture()
    var unsavedRecording: Recording?
    var environmentObservers: [NSObjectProtocol] = []
    var workspaceObservers: [NSObjectProtocol] = []
    // OS adapters are replaceable in controller tests; production uses these defaults.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var canListen: () -> Bool = { CGPreflightListenEventAccess() }
    var canPost: () -> Bool = { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var physicalModifiers: () -> UInt64 = { CGEventSource.flagsState(.combinedSessionState).rawValue }
    var screenProvider: (() -> [ScreenLayout])?
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var eventSink: ((CGEvent) -> Void)?
    var alertSink: ((String, String) -> Void)?
    var recordLimit: TimeInterval = 180
    var countdownInterval: TimeInterval = 1
    var installCaptureTap = true
    var controlCodes: [UInt16] = [15, 35, 53]
    var heldPlaybackKeys: Set<UInt16> = []
    var playbackModifiers: UInt64 = 0
    let playbackSource = CGEventSource(stateID: .privateState)
    var pressed: [Int: Click] = [:]
    var heldTimelineButtons: [Int: RecordedInput] = [:]
    var heldTimelineModifiers: Set<UInt16> = []
    var hotKeys: [EventHotKeyRef] = []
    var settingsWindow: NSWindow?
    var keyFields: [NSTextField] = []
    var hotKeyOK = false
    var lastError: String?

    var current: Recording? { recordings.first { $0.id == selected } }
    var now: TimeInterval { clock() }
    var listenAllowed: Bool { canListen() }
    var postAllowed: Bool { canPost() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loaded = store.load()
        recordings = loaded.0
        selected = UUID(uuidString: preferences.string(forKey: "selected") ?? "")
        if current == nil { selected = recordings.first?.id }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "◉"
        status.button?.toolTip = "클릭 녹화기"
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        observeEnvironment()
        installHotKeyHandler()
        registerHotKeys()
        rebuildMenu()
        if loaded.1 > 0 { alert("읽을 수 없는 녹화 \(loaded.1)개를 건너뛰었습니다.", "원본 파일은 그대로 보관했습니다.") }
        if !listenAllowed || !postAllowed { showPermissions() }
        else { showAppMenu() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showAppMenu() }
        return true
    }
    func showAppMenu() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.status.button?.performClick(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        stopEverything()
        hotKeys.forEach { UnregisterEventHotKey($0) }
        environmentObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    func observeEnvironment() {
        environmentObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.environmentChanged("화면 구성이 변경되어 작업을 중지했습니다.")
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.environmentChanged("잠자기 또는 사용자 전환으로 작업을 중지했습니다.")
            })
        }
    }
    func environmentChanged(_ message: String) {
        guard mode != .idle else { return }
        stopEverything(); lastError = message; rebuildMenu()
    }
    func startTimer(interval: TimeInterval, repeats: Bool, action: @escaping (Timer) -> Void) {
        timer?.invalidate()
        let value = Timer(timeInterval: interval, repeats: repeats, block: action)
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; rebuildMenu() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
    func item(_ title: String, _ selector: Selector?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self; item.isEnabled = enabled
        return item
    }
    func rebuildMenu() {
        guard let menu = status.menu else { return }
        menu.removeAllItems(); menu.autoenablesItems = false
        let state: String
        switch mode { case .idle: state = "클릭 녹화기"; case .countdown: state = "녹화 준비 중…"; case .recording: state = "녹화 중 · 최대 3분"; case .preparing: state = "재생 준비 중…"; case .playing: state = "재생 중" }
        menu.addItem(item(state, nil, enabled: false))
        if let lastError { menu.addItem(item(lastError, nil, enabled: false)) }
        menu.addItem(.separator())
        menu.addItem(item(mode == .recording || mode == .countdown ? "녹화 종료" : "녹화 시작 (3초 후)", #selector(toggleRecord), enabled: (mode == .idle || mode == .recording || mode == .countdown) && listenAllowed && hotKeyOK))
        menu.addItem(item("선택한 녹화 재생", #selector(playFromMenu), enabled: mode == .idle && current != nil && postAllowed && hotKeyOK))
        menu.addItem(item("즉시 중지", #selector(stopEverything), enabled: mode != .idle))
        menu.addItem(.separator())
        if recordings.isEmpty { menu.addItem(item("저장된 녹화 없음", nil, enabled: false)) }
        for recording in recordings {
            let row = item("\(recording.name) · \(recording.clickCount)클릭 / \(recording.keyCount)키 · \(Int(ceil(recording.duration)))초", #selector(selectRecording(_:)), enabled: mode == .idle)
            row.representedObject = recording.id.uuidString
            row.state = recording.id == selected ? .on : .off
            menu.addItem(row)
        }
        menu.addItem(.separator())
        if unsavedRecording != nil { menu.addItem(item("저장 실패한 녹화 다시 저장", #selector(retrySave), enabled: mode == .idle)) }
        menu.addItem(item("선택한 녹화 이름 변경…", #selector(renameRecording), enabled: current != nil && mode == .idle))
        menu.addItem(item("선택한 녹화 삭제…", #selector(deleteRecording), enabled: current != nil && mode == .idle))
        menu.addItem(item("저장 폴더 열기", #selector(openFolder)))
        menu.addItem(.separator())
        menu.addItem(item("단축키 설정…", #selector(showSettings), enabled: mode == .idle))
        menu.addItem(item("권한 설정…", #selector(showPermissions)))
        menu.addItem(item("사용 방법", #selector(help)))
        menu.addItem(item("종료", #selector(quit)))
    }
    func alert(_ title: String, _ detail: String = "") {
        if let alertSink { alertSink(title, detail); return }
        modalDepth += 1; defer { modalDepth -= 1 }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: "확인"); alert.runModal()
    }
    func layouts() -> [ScreenLayout] {
        if let screenProvider { return screenProvider() }
        var count: UInt32 = 0; CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { id in
            let rect = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            return ScreenLayout(id: id, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, pixelsWide: mode?.pixelWidth ?? CGDisplayPixelsWide(id), pixelsHigh: mode?.pixelHeight ?? CGDisplayPixelsHigh(id))
        }.sorted { $0.id < $1.id }
    }
    @objc func toggleRecord() {
        if mode == .recording { finishRecording(); return }
        if mode == .countdown { stopEverything(); return }
        guard mode == .idle, modalDepth == 0, listenAllowed, hotKeyOK else { return }
        guard unsavedRecording == nil else { alert("저장하지 못한 녹화가 있습니다.", "메뉴에서 다시 저장한 후 새 녹화를 시작해 주세요."); return }
        guard !secureInput() else { alert("보안 입력이 활성화되어 있습니다.", "암호 입력을 종료한 후 녹화를 시작해 주세요."); return }
        guard layouts().count == 1 else { alert("한 화면에서 녹화해 주세요.", "첫 버전은 활성 모니터 한 개를 지원합니다."); return }
        mode = .countdown; status.button?.title = "3"; rebuildMenu()
        var remaining = 3
        startTimer(interval: countdownInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            remaining -= 1
            if remaining == 0 { self.timer?.invalidate(); self.timer = nil; self.beginRecording() }
            else { self.status.button?.title = "\(remaining)" }
        }
    }
    func beginRecording() {
        guard mode == .countdown else { return }
        guard listenAllowed, !secureInput() else { stopEverything(); alert("권한 또는 보안 입력 상태가 변경되어 녹화를 시작하지 않았습니다."); return }
        captureSession = TimelineCapture(); captureSession.ignoreInitialModifiers = physicalModifiers() & modifierMask != 0; recordingScreens = layouts()
        guard recordingScreens.count == 1 else { stopEverything(); return }
        if installCaptureTap {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<App>.fromOpaque(info).takeUnretainedValue()
            app.capture(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { stopEverything(); alert("클릭 감시를 시작할 수 없습니다.", "입력 모니터링 권한을 허용한 후 앱을 다시 실행해 주세요."); return }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            stopEverything(); alert("입력 감시 소스를 만들지 못했습니다."); return
        }
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        recordingStart = now; recordingStartTimestamp = CGEvent(source: nil)?.timestamp ?? 0
        lastCaptureTime = 0
        mode = .recording; status.button?.title = "● REC"
        startTimer(interval: recordLimit, repeats: false) { [weak self] _ in self?.finishRecording() }
        rebuildMenu()
    }
    func capture(_ type: CGEventType, _ event: CGEvent) {
        guard mode == .recording else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            finishRecording(); lastError = "입력 감시가 중단되어 녹화를 종료했습니다."; rebuildMenu(); return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != ownTag else { return }
        guard listenAllowed, !secureInput() else {
            finishRecording(); lastError = "권한 또는 보안 입력 상태가 변경되어 녹화를 종료했습니다."; rebuildMenu(); return
        }
        if captureSession.events.count >= 99_800 {
            finishRecording(); lastError = "입력 수 제한에 도달하여 녹화를 종료했습니다."; rebuildMenu(); return
        }
        let rawTime: Double
        if useEventTimestamps && recordingStartTimestamp > 0 {
            guard event.timestamp >= recordingStartTimestamp else { return }
            rawTime = Double(event.timestamp - recordingStartTimestamp) / 1_000_000_000
        } else { rawTime = now - recordingStart }
        if rawTime >= recordLimit { finishRecording(); return }
        let elapsed = max(lastCaptureTime, max(0, rawTime))
        lastCaptureTime = elapsed
        guard let input = recordedInput(event, type: type, time: elapsed) else { return }
        var excluded = menuOpen || event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier)
        if input.keyCode != nil {
            excluded = excluded || frontmostPID() == ProcessInfo.processInfo.processIdentifier
            if let code = input.keyCode, input.kind != .modifiers,
               isControlShortcut(code: code, flags: input.flags, shortcutCodes: controlCodes) {
                captureSession.removeControlShortcutTail(); excluded = true
            }
        } else {
            if let x = input.x, let y = input.y,
               !recordingScreens.contains(where: { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }) {
                environmentChanged("화면 범위를 벗어난 입력이 감지되어 녹화를 종료했습니다."); return
            }
            if let window = status.button?.window, let screen = NSScreen.screens.first {
                let point = NSPoint(x: event.location.x, y: screen.frame.maxY - event.location.y)
                excluded = excluded || window.frame.contains(point)
            }
        }
        captureSession.record(input, excluded: excluded)
    }

    func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }
    func finishRecording() {
        guard mode == .recording else { return }
        let duration = min(recordLimit, max(lastCaptureTime, max(0, now - recordingStart)))
        removeTap(); timer?.invalidate(); timer = nil; mode = .idle; status.button?.title = "◉"
        let inputs = captureSession.finish(at: duration)
        if !inputs.isEmpty {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let recording = Recording(version: 3, name: formatter.string(from: Date()), duration: duration, screens: recordingScreens, clicks: [], timeline: inputs)
            saveRecording(recording)
        }
        captureSession = TimelineCapture()
        rebuildMenu()
    }

    func saveRecording(_ recording: Recording) {
        do {
            try store.save(recording)
            if !recordings.contains(where: { $0.id == recording.id }) { recordings.append(recording) }
            selected = recording.id; unsavedRecording = nil; lastError = nil
        } catch {
            unsavedRecording = recording
            alert("녹화를 저장하지 못했습니다.", error.localizedDescription + "\n앱을 종료하지 말고 메뉴의 ‘다시 저장’을 사용해 주세요.")
        }
    }
    @objc func retrySave() {
        guard mode == .idle, let recording = unsavedRecording else { return }
        saveRecording(recording); rebuildMenu()
    }
    @objc func playFromMenu() { play(delay: 0.2) }
    func play(delay: TimeInterval = 0) {
        guard mode == .idle, modalDepth == 0, let recording = current, hotKeyOK else { return }
        guard postAllowed else { alert("재생 권한이 없습니다.", "권한 설정에서 손쉬운 사용을 허용해 주세요."); return }
        guard !secureInput() else { alert("보안 입력 중에는 재생할 수 없습니다."); return }
        do { try recording.validate() } catch { alert("녹화 데이터가 올바르지 않습니다."); return }
        guard layouts() == recording.screens else { alert("화면 구성이 녹화 당시와 다릅니다.", "모니터·해상도·배율을 원래대로 맞추거나 새로 녹화해 주세요."); return }
        ticket.cancel(); let generation = ticket.generation
        mode = .preparing; status.button?.title = "… PLAY"; rebuildMenu()
        preparePlayback(recording, generation: generation, earliest: now + delay, timeout: now + delay + 3)
    }
    func preparePlayback(_ recording: Recording, generation: Int, earliest: TimeInterval, timeout: TimeInterval) {
        guard ticket.accepts(generation), mode == .preparing else { return }
        // A playback shortcut must be released before emitting the recording.
        let mask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)
        if now >= earliest && physicalModifiers() & mask == 0 {
            mode = .playing; status.button?.title = "▶ PLAY"; rebuildMenu()
            lastPlaybackStart = now
            playbackRun = PlaybackRun(recording: recording, start: lastPlaybackStart)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in self?.playbackStep(generation: generation) }
            playbackTimer = timer
            timer.resume()
            scheduleNext()
        } else if now >= timeout {
            stopEverything(); lastError = "보조키를 놓은 후 다시 재생해 주세요."; rebuildMenu()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.preparePlayback(recording, generation: generation, earliest: earliest, timeout: timeout) }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
    }
    func scheduleNext() {
        guard let run = playbackRun else { return }
        // Absolute offsets avoid cumulative sleep/handler drift. Only one timer exists.
        playbackTimer?.schedule(deadline: .now() + max(0, run.start + run.nextTime - now), leeway: .milliseconds(1))
    }
    func playbackStep(generation: Int) {
        guard ticket.accepts(generation), mode == .playing, let run = playbackRun else { return }
        guard postAllowed, !secureInput(), layouts() == run.screens else {
            stopEverything(); alert("권한·보안 입력 또는 화면 구성이 변경되어 재생을 중단했습니다."); return
        }
        // A timer may wake early. Never emit before the recorded deadline.
        guard now >= run.start + run.nextTime else { scheduleNext(); return }
        guard run.index < run.eventCount else { stopEverything(); return }
        let event = run.event(at: run.index)
        if let input = event.input {
            guard emitTimeline(input) else { stopEverything(); alert("입력 이벤트를 만들지 못해 재생을 중단했습니다."); return }
        } else if let click = event.click {
            syncModifiers(event.isDown ? (click.flags ?? 0) : (click.upFlags ?? click.flags ?? 0))
            if event.isDown { pressed[click.button] = click } else { pressed.removeValue(forKey: click.button) }
            emit(click, down: event.isDown)
        } else if let key = event.key {
            syncModifiers(key.flags)
            if key.isDown { heldPlaybackKeys.insert(key.code) } else { heldPlaybackKeys.remove(key.code) }
            emitKey(key)
        }
        guard ticket.accepts(generation), mode == .playing else { return }
        if event.input == nil && heldPlaybackKeys.isEmpty && pressed.isEmpty { syncModifiers(0) }
        playbackRun?.index += 1
        scheduleNext()
    }
    func emitTimeline(_ input: RecordedInput) -> Bool {
        guard let event = makeInputEvent(input, source: playbackSource, tag: ownTag) else { return false }
        // Explicit modifier transitions are played at their recorded times. A chord
        // already held when recording began is reconstructed on its first input.
        if input.kind != .modifiers && playbackModifiers & modifierMask != input.flags & modifierMask { syncModifiers(input.flags) }
        switch input.kind {
        case .mouseDown, .drag:
            if let button = input.button { heldTimelineButtons[button] = input }
        case .mouseUp:
            if let button = input.button { heldTimelineButtons.removeValue(forKey: button) }
        case .keyDown:
            if let code = input.keyCode { heldPlaybackKeys.insert(code) }
        case .keyUp:
            if let code = input.keyCode { heldPlaybackKeys.remove(code) }
        case .modifiers:
            if let code = input.keyCode { updateModifierKeys(&heldTimelineModifiers, code: code, flags: input.flags) }
            playbackModifiers = input.flags & modifierMask
        default: break
        }
        post(event)
        return true
    }
    func post(_ event: CGEvent) {
        if let eventSink { eventSink(event) } else { event.post(tap: .cghidEventTap) }
    }
    func emit(_ click: Click, down: Bool) {
        let type: CGEventType = click.button == 0 ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
        let point = CGPoint(x: click.x, y: click.y)
        if eventSink == nil { CGWarpMouseCursorPosition(point) }
        let event = CGEvent(mouseEventSource: playbackSource, mouseType: type, mouseCursorPosition: point, mouseButton: click.button == 0 ? .left : .right)
        event?.flags = CGEventFlags(rawValue: down ? (click.flags ?? 0) : (click.upFlags ?? click.flags ?? 0))
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(click.count))
        event?.setIntegerValueField(.eventSourceUserData, value: ownTag)
        if let event { post(event) }
    }
    func emitKey(_ key: KeyInput) {
        let event = CGEvent(keyboardEventSource: playbackSource, virtualKey: key.code, keyDown: key.isDown)
        event?.flags = CGEventFlags(rawValue: key.flags)
        event?.setIntegerValueField(.keyboardEventAutorepeat, value: key.isRepeat ? 1 : 0)
        event?.setIntegerValueField(.eventSourceUserData, value: ownTag)
        if let event { post(event) }
    }
    func syncModifiers(_ flags: UInt64) {
        // Canonical left modifier keys reproduce the recorded chord without
        // recording the modifier-only prefix of this app's control shortcuts.
        let modifiers: [(UInt64, UInt16)] = [(1 << 17, 56), (1 << 18, 59), (1 << 19, 58), (1 << 20, 55), (1 << 23, 63)]
        for (mask, code) in modifiers where (playbackModifiers & mask) != (flags & mask) {
            let down = flags & mask != 0
            if down { playbackModifiers |= mask } else { playbackModifiers &= ~mask }
            let event = CGEvent(keyboardEventSource: playbackSource, virtualKey: code, keyDown: down)
            event?.type = .flagsChanged
            event?.flags = CGEventFlags(rawValue: playbackModifiers)
            event?.setIntegerValueField(.eventSourceUserData, value: ownTag)
            if let event { post(event) }
        }
    }
    @objc func stopEverything() {
        if mode == .recording { finishRecording(); return }
        ticket.cancel(); pendingWork?.cancel(); pendingWork = nil
        timer?.invalidate(); timer = nil; removeTap()
        playbackTimer?.setEventHandler {}; playbackTimer?.cancel(); playbackTimer = nil; playbackRun = nil
        for button in pressed.keys.sorted() {
            if var click = pressed[button] { click.upFlags = 0; emit(click, down: false) }
        }
        pressed.removeAll()
        for code in heldPlaybackKeys.sorted() { emitKey(KeyInput(time: 0, code: code, isDown: false, flags: 0)) }
        heldPlaybackKeys.removeAll()
        for button in heldTimelineButtons.keys.sorted() {
            if var input = heldTimelineButtons[button] {
                input.kind = .mouseUp; input.flags = 0
                if let event = makeInputEvent(input, source: playbackSource, tag: ownTag) { post(event) }
            }
        }
        heldTimelineButtons.removeAll()
        for code in heldTimelineModifiers.sorted() {
            if let event = makeInputEvent(RecordedInput(time: 0, kind: .modifiers, keyCode: code), source: playbackSource, tag: ownTag) { post(event) }
        }
        let releasedMask = modifierKeys.filter { heldTimelineModifiers.contains($0.code) }.reduce(UInt64(0)) { $0 | $1.flag }
        heldTimelineModifiers.removeAll(); playbackModifiers &= ~releasedMask; syncModifiers(0)
        mode = .idle; status?.button?.title = "◉"; if status != nil { rebuildMenu() }
    }
    @objc func selectRecording(_ sender: NSMenuItem) { guard mode == .idle else { return }; selected = UUID(uuidString: sender.representedObject as? String ?? ""); rebuildMenu() }
    @objc func renameRecording() {
        guard mode == .idle, var recording = current else { return }
        modalDepth += 1; defer { modalDepth -= 1 }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "녹화 이름 변경"
        let field = NSTextField(string: recording.name); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "저장"); alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }; recording.name = String(name.prefix(100))
        do { try store.save(recording); recordings[recordings.firstIndex { $0.id == recording.id }!] = recording; rebuildMenu() }
        catch { self.alert("이름을 저장하지 못했습니다.", error.localizedDescription) }
    }
    @objc func deleteRecording() {
        guard mode == .idle, let recording = current else { return }
        modalDepth += 1; defer { modalDepth -= 1 }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "‘\(recording.name)’ 녹화를 삭제할까요?"; alert.addButton(withTitle: "삭제"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.delete(recording.id); recordings.removeAll { $0.id == recording.id }; selected = recordings.first?.id; rebuildMenu() }
        catch { self.alert("삭제하지 못했습니다.", error.localizedDescription) }
    }
    @objc func openFolder() { try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true); NSWorkspace.shared.open(store.directory) }
    @objc func help() { alert("클릭 녹화기 사용 방법", "1. 단축키로 녹화를 시작하고 3초 후 클릭하세요.\n2. 같은 단축키로 종료하면 자동 저장됩니다.\n3. 메뉴에서 녹화를 선택하세요.\n4. 대상 창의 위치·크기를 맞춘 후 재생 단축키를 누르세요.\n\n마우스 이동·좌우/가운데 클릭·드래그·스크롤과 키보드 단축키를 하나의 타임라인으로 기록합니다. 재생할 때 입력 언어와 대상 창을 녹화 당시와 같게 맞춰 주세요. 앱의 로딩 시간에 따라 결과가 달라질 수 있습니다.\n\n기본 단축키: Control+Option+Command와 R(녹화), P(재생), Esc(중지).") }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mode == .recording { finishRecording() }
        guard unsavedRecording == nil else {
            alert("아직 저장하지 못한 녹화가 있습니다.", "메뉴에서 다시 저장한 후 종료해 주세요.")
            return .terminateCancel
        }
        return .terminateNow
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showPermissions() {
        if mode != .idle { stopEverything() }
        modalDepth += 1; defer { modalDepth -= 1 }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "다른 앱의 클릭과 키보드를 녹화하고 재생하려면 권한이 필요합니다."
        alert.informativeText = "입력 모니터링: \(listenAllowed ? "허용됨" : "필요")\n손쉬운 사용: \(postAllowed ? "허용됨" : "필요")\n\n시스템 설정에서 ‘클릭 녹화기’를 허용하세요. 권한 변경 후 앱을 다시 실행해야 할 수 있습니다."
        alert.addButton(withTitle: "권한 요청"); alert.addButton(withTitle: "손쉬운 사용 설정"); alert.addButton(withTitle: "입력 모니터링 설정"); alert.addButton(withTitle: "닫기")
        switch alert.runModal().rawValue {
        case 1000:
            _ = CGRequestListenEventAccess()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case 1001: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case 1002: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        default: break
        }
        rebuildMenu()
    }
    let availableKeys: [String: UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"N":45,"M":46,"ESC":53]
    func keyNames() -> [String] { (preferences.array(forKey: "keys") as? [String]).flatMap { $0.count == 3 ? $0 : nil } ?? ["R", "P", "ESC"] }
    func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
            guard id.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
            if app.mode == .recording { app.captureSession.removeControlShortcutTail() }
            switch id.id { case 1: app.toggleRecord(); case 2: app.play(); case 3: app.stopEverything(); default: break }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
    func registerHotKeys() {
        controlCodes = keyNames().compactMap { availableKeys[$0].map(UInt16.init) }
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys = []; hotKeyOK = true; lastError = nil
        for (index, name) in keyNames().enumerated() {
            var ref: EventHotKeyRef?
            guard let code = availableKeys[name], RegisterEventHotKey(code, UInt32(controlKey | optionKey | cmdKey), EventHotKeyID(signature: hotKeySignature, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref else {
                hotKeyOK = false; lastError = "단축키 충돌: 설정에서 변경해 주세요"; continue
            }
            hotKeys.append(ref)
        }
        if !hotKeyOK { hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys = [] }
    }
    @objc func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 245), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "단축키 설정"; window.isReleasedWhenClosed = false
        let info = NSTextField(wrappingLabelWithString: "Control + Option + Command + 아래 키\n영문 한 글자, 숫자 또는 ESC를 입력하세요.")
        info.frame = NSRect(x: 24, y: 175, width: 375, height: 48); window.contentView?.addSubview(info)
        keyFields = []
        for (i, label) in ["녹화 시작·종료", "한 번 재생", "즉시 중지"].enumerated() {
            let text = NSTextField(labelWithString: label); text.frame = NSRect(x: 24, y: 140 - i * 35, width: 180, height: 24); window.contentView?.addSubview(text)
            let field = NSTextField(string: keyNames()[i]); field.frame = NSRect(x: 230, y: 140 - i * 35, width: 150, height: 24); window.contentView?.addSubview(field); keyFields.append(field)
        }
        let button = NSButton(title: "저장", target: self, action: #selector(saveSettings)); button.frame = NSRect(x: 290, y: 15, width: 90, height: 32); window.contentView?.addSubview(button)
        settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func saveSettings() {
        guard mode == .idle else { alert("녹화 또는 재생을 먼저 중지해 주세요."); return }
        let names = keyFields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        guard Set(names).count == 3, names.allSatisfy({ availableKeys[$0] != nil }) else { alert("서로 다른 유효한 키 3개를 입력해 주세요."); return }
        let previous = keyNames()
        preferences.set(names, forKey: "keys"); registerHotKeys()
        if hotKeyOK { settingsWindow?.close() }
        else {
            preferences.set(previous, forKey: "keys"); registerHotKeys()
            alert("다른 앱과 단축키가 충돌합니다.", "기존 설정을 복원했습니다. 다른 키로 변경해 주세요.")
        }
        rebuildMenu()
    }
}

#if !TESTING
@main
enum EntryPoint {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = App()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

#endif
