import AppKit
import Carbon
import CoreGraphics

private let ownTag: Int64 = 0x434C49434B
private let hotKeySignature: OSType = 0x434C494B

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = RecordingStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClickRecorder/Recordings"))
    var status: NSStatusItem!
    var recordings: [Recording] = []
    var selected: UUID? {
        didSet { UserDefaults.standard.set(selected?.uuidString, forKey: "selected") }
    }
    enum Mode { case idle, countdown, recording, playing }
    var mode: Mode = .idle
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var timer: Timer?
    var pendingWork: DispatchWorkItem?
    let ticket = PlaybackTicket()
    var recordingStart: TimeInterval = 0
    var recordingScreens: [ScreenLayout] = []
    var clicks: [Click] = []
    var pendingClick: Click?
    var excluded = 0
    var pressed: Click?
    var hotKeys: [EventHotKeyRef] = []
    var settingsWindow: NSWindow?
    var keyFields: [NSTextField] = []
    var hotKeyOK = false
    var lastError: String?

    var current: Recording? { recordings.first { $0.id == selected } }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var listenAllowed: Bool { CGPreflightListenEventAccess() }
    var postAllowed: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loaded = store.load()
        recordings = loaded.0
        selected = UUID(uuidString: UserDefaults.standard.string(forKey: "selected") ?? "")
        if current == nil { selected = recordings.first?.id }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "◉"
        status.button?.toolTip = "클릭 녹화기"
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        installHotKeyHandler()
        registerHotKeys()
        rebuildMenu()
        if loaded.1 > 0 { alert("읽을 수 없는 녹화 \(loaded.1)개를 건너뛰었습니다.", "원본 파일은 그대로 보관했습니다.") }
        if !listenAllowed || !postAllowed { showPermissions() }
    }
    func applicationWillTerminate(_ notification: Notification) { stopEverything(); hotKeys.forEach { UnregisterEventHotKey($0) } }
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
    func item(_ title: String, _ selector: Selector?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self; item.isEnabled = enabled
        return item
    }
    func rebuildMenu() {
        guard let menu = status.menu else { return }
        menu.removeAllItems(); menu.autoenablesItems = false
        let state: String
        switch mode { case .idle: state = "클릭 녹화기"; case .countdown: state = "녹화 준비 중…"; case .recording: state = "녹화 중 · 최대 3분"; case .playing: state = "재생 중" }
        menu.addItem(item(state, nil, enabled: false))
        if let lastError { menu.addItem(item(lastError, nil, enabled: false)) }
        menu.addItem(.separator())
        menu.addItem(item(mode == .recording || mode == .countdown ? "녹화 종료" : "녹화 시작 (3초 후)", #selector(toggleRecord), enabled: mode != .playing && listenAllowed && hotKeyOK))
        menu.addItem(item("선택한 녹화 재생", #selector(playFromMenu), enabled: mode == .idle && current != nil && postAllowed && hotKeyOK))
        menu.addItem(item("즉시 중지", #selector(stopEverything), enabled: mode != .idle))
        menu.addItem(.separator())
        if recordings.isEmpty { menu.addItem(item("저장된 녹화 없음", nil, enabled: false)) }
        for recording in recordings {
            let row = item("\(recording.name) · \(recording.clicks.count)클릭 · \(Int(ceil(recording.duration)))초", #selector(selectRecording(_:)), enabled: mode == .idle)
            row.representedObject = recording.id.uuidString
            row.state = recording.id == selected ? .on : .off
            menu.addItem(row)
        }
        menu.addItem(.separator())
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
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: "확인"); alert.runModal()
    }
    func layouts() -> [ScreenLayout] {
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
        guard mode == .idle, listenAllowed, hotKeyOK else { return }
        guard layouts().count == 1 else { alert("한 화면에서 녹화해 주세요.", "첫 버전은 활성 모니터 한 개를 지원합니다."); return }
        mode = .countdown; status.button?.title = "3"; rebuildMenu()
        var remaining = 3
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            remaining -= 1
            if remaining == 0 { self.timer?.invalidate(); self.timer = nil; self.beginRecording() }
            else { self.status.button?.title = "\(remaining)" }
        }
    }
    func beginRecording() {
        clicks = []; pendingClick = nil; excluded = 0; recordingScreens = layouts()
        guard recordingScreens.count == 1 else { stopEverything(); return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<App>.fromOpaque(info).takeUnretainedValue()
            app.capture(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { stopEverything(); alert("클릭 감시를 시작할 수 없습니다.", "입력 모니터링 권한을 허용한 후 앱을 다시 실행해 주세요."); return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        recordingStart = now; mode = .recording; status.button?.title = "● REC"
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in self?.finishRecording() }
        rebuildMenu()
    }
    func capture(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in self?.finishRecording(); self?.alert("입력 감시가 중단되어 녹화를 종료했습니다.") }; return
        }
        guard mode == .recording, event.getIntegerValueField(.eventSourceUserData) != ownTag else { return }
        if type == .scrollWheel || type == .otherMouseDown { excluded += 1; return }
        if type == .leftMouseDragged || type == .rightMouseDragged {
            if pendingClick != nil { excluded += 1; pendingClick = nil }; return
        }
        let elapsed = min(180, now - recordingStart)
        if type == .leftMouseDown || type == .rightMouseDown {
            if pendingClick != nil { excluded += 1; pendingClick = nil; return }
            let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            guard event.flags.intersection(modifiers).isEmpty else { excluded += 1; return }
            guard event.getIntegerValueField(.eventTargetUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier) else { return }
            // The status item's menu-bar click belongs to this app too.
            if let window = status.button?.window, let screen = NSScreen.screens.first {
                let p = NSPoint(x: event.location.x, y: screen.frame.maxY - event.location.y)
                if window.frame.contains(p) { return }
            }
            pendingClick = Click(down: elapsed, up: elapsed, x: event.location.x, y: event.location.y, button: type == .leftMouseDown ? 0 : 1, count: max(1, min(3, Int(event.getIntegerValueField(.mouseEventClickState)))))
        } else if var click = pendingClick {
            guard (type == .leftMouseUp && click.button == 0) || (type == .rightMouseUp && click.button == 1) else { return }
            click.up = elapsed; clicks.append(click); pendingClick = nil
        }
    }
    func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }
    func finishRecording() {
        guard mode == .recording else { return }
        let duration = min(180, now - recordingStart)
        if pendingClick != nil { excluded += 1 }
        removeTap(); timer?.invalidate(); timer = nil; pendingClick = nil; mode = .idle; status.button?.title = "◉"
        if !clicks.isEmpty {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let recording = Recording(name: formatter.string(from: Date()), duration: duration, screens: recordingScreens, clicks: clicks)
            do { try store.save(recording); recordings.append(recording); selected = recording.id }
            catch { alert("녹화를 저장하지 못했습니다.", error.localizedDescription) }
        }
        rebuildMenu()
        if excluded > 0 { alert("녹화 완료 · \(clicks.count)클릭 저장", "드래그·스크롤·보조키 클릭 등 지원하지 않거나 미완료인 동작 \(excluded)개를 제외했습니다.") }
    }
    @objc func playFromMenu() {
        // Allow the menu to close without activating this app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.play() }
    }
    func play() {
        guard mode == .idle, let recording = current, hotKeyOK else { return }
        guard postAllowed else { showPermissions(); return }
        guard layouts() == recording.screens else { alert("화면 구성이 녹화 당시와 다릅니다.", "모니터·해상도·배율을 원래대로 맞추거나 새로 녹화해 주세요."); return }
        ticket.cancel(); let generation = ticket.generation
        mode = .playing; status.button?.title = "▶ PLAY"; rebuildMenu()
        schedule(playbackEvents(recording), index: 0, start: now, duration: recording.duration, generation: generation, screens: recording.screens)
    }
    func schedule(_ events: [PlaybackEvent], index: Int, start: TimeInterval, duration: Double, generation: Int, screens: [ScreenLayout]) {
        let target = index < events.count ? events[index].time : duration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ticket.accepts(generation), self.mode == .playing else { return }
            guard self.postAllowed, self.layouts() == screens else { self.stopEverything(); self.alert("권한 또는 화면 구성이 변경되어 재생을 중단했습니다."); return }
            guard index < events.count else { self.stopEverything(); return }
            let event = events[index]
            self.emit(event.click, down: event.isDown)
            self.pressed = event.isDown ? event.click : nil
            self.schedule(events, index: index + 1, start: start, duration: duration, generation: generation, screens: screens)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, start + target - now), execute: work)
    }
    func emit(_ click: Click, down: Bool) {
        let type: CGEventType = click.button == 0 ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
        let point = CGPoint(x: click.x, y: click.y)
        CGWarpMouseCursorPosition(point)
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type, mouseCursorPosition: point, mouseButton: click.button == 0 ? .left : .right)
        event?.flags = []
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(click.count))
        event?.setIntegerValueField(.eventSourceUserData, value: ownTag)
        event?.post(tap: .cghidEventTap)
    }
    @objc func stopEverything() {
        if mode == .recording { finishRecording(); return }
        ticket.cancel(); pendingWork?.cancel(); pendingWork = nil
        timer?.invalidate(); timer = nil; removeTap()
        if let pressed { emit(pressed, down: false) }; pressed = nil
        mode = .idle; status?.button?.title = "◉"; if status != nil { rebuildMenu() }
    }
    @objc func selectRecording(_ sender: NSMenuItem) { selected = UUID(uuidString: sender.representedObject as? String ?? ""); rebuildMenu() }
    @objc func renameRecording() {
        guard var recording = current else { return }
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
        guard let recording = current else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "‘\(recording.name)’ 녹화를 삭제할까요?"; alert.addButton(withTitle: "삭제"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.delete(recording.id); recordings.removeAll { $0.id == recording.id }; selected = recordings.first?.id; rebuildMenu() }
        catch { self.alert("삭제하지 못했습니다.", error.localizedDescription) }
    }
    @objc func openFolder() { try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true); NSWorkspace.shared.open(store.directory) }
    @objc func help() { alert("클릭 녹화기 사용 방법", "1. 단축키로 녹화를 시작하고 3초 후 클릭하세요.\n2. 같은 단축키로 종료하면 자동 저장됩니다.\n3. 메뉴에서 녹화를 선택하세요.\n4. 대상 창의 위치·크기를 맞춘 후 재생 단축키를 누르세요.\n\n좌우·더블클릭과 시간 간격만 기록합니다. 이동 경로·드래그·스크롤·보조키 클릭은 제외합니다. 앱의 로딩 시간에 따라 결과가 달라질 수 있습니다.\n\n기본 단축키: Control+Option+Command와 R(녹화), P(재생), Esc(중지).") }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "다른 앱의 클릭을 녹화하고 재생하려면 권한이 필요합니다."
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
    func keyNames() -> [String] { (UserDefaults.standard.array(forKey: "keys") as? [String]).flatMap { $0.count == 3 ? $0 : nil } ?? ["R", "P", "ESC"] }
    func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
            guard id.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
            switch id.id { case 1: app.toggleRecord(); case 2: app.play(); case 3: app.stopEverything(); default: break }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
    func registerHotKeys() {
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
        UserDefaults.standard.set(names, forKey: "keys"); registerHotKeys(); rebuildMenu()
        if hotKeyOK { settingsWindow?.close() } else { alert("다른 앱과 단축키가 충돌합니다.", "다른 키로 변경해 주세요.") }
    }
}

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
