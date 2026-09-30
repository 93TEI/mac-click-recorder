import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClickRecorderTests-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let store = RecordingStore(directory: directory)
let screen = ScreenLayout(id: 1, x: 0, y: 0, width: 1920, height: 1080, pixelsWide: 3840, pixelsHigh: 2160)
var recording = Recording(name: "테스트", duration: 3, screens: [screen], clicks: [Click(down: 0.5, up: 0.6, x: 100, y: 200, button: 0, count: 1), Click(down: 1, up: 1.1, x: 100, y: 200, button: 0, count: 2)])
try store.save(recording)
let loaded = store.load()
check(loaded.0.count == 1 && loaded.1 == 0, "round trip")
check(loaded.0[0].clicks[1].count == 2 && loaded.0[0].clicks[0].x == 100, "coordinates and double click")
check(loaded.0[0].screens == [screen], "retina screen metadata")
let events = playbackEvents(loaded.0[0])
check(events.map { $0.time } == [0.5, 0.6, 1, 1.1], "timing and event order")
check(events.map { $0.isDown } == [true, false, true, false], "balanced clicks")
recording.name = "새 이름"; try store.save(recording)
check(store.load().0.count == 1 && store.load().0[0].name == "새 이름", "atomic overwrite")
try Data("broken".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
check(store.load().1 == 1 && store.load().0.count == 1, "corrupt file isolation")
var invalid = recording; invalid.clicks[0].up = 200
check((try? invalid.validate()) == nil, "reject over-limit event")
invalid = recording; invalid.clicks[0].x = -1
check((try? invalid.validate()) == nil, "reject outside screen")
invalid = recording; invalid.version = 999
check((try? invalid.validate()) == nil, "reject unsupported version")
let ticket = PlaybackTicket(); let generation = ticket.generation
check(ticket.accepts(generation), "active playback")
ticket.cancel(); check(!ticket.accepts(generation), "cancel stale callback")
check(ticket.accepts(ticket.generation), "new playback")
try store.delete(recording.id); check(store.load().0.isEmpty, "delete")
print("PASS: persistence, timing, coordinates, double click, validation, corruption, cancellation, deletion")

let command: UInt64 = 1 << 20
var capture = KeyboardCapture()
capture.append(KeyInput(time: 0.1, code: 0, isDown: false, flags: 0)) // orphan up
capture.append(KeyInput(time: 0.2, code: 0, isDown: true, flags: command))
capture.append(KeyInput(time: 0.3, code: 0, isDown: true, flags: command, isRepeat: true))
capture.append(KeyInput(time: 0.4, code: 0, isDown: false, flags: command))
capture.append(KeyInput(time: 0.7, code: 36, isDown: true, flags: 0)) // held at stop
let keys = capture.finish(at: 2)
check(keys.count == 5 && keys.last?.isDown == false && keys.last?.time == 2, "orphan suppression and held key release")
var mixed = Recording(version: 2, name: "키보드", duration: 3, screens: [screen], clicks: recording.clicks, keys: keys)
try mixed.validate()
try store.save(mixed)
let restored = store.load().0.first!
check(restored.keys?.count == 5 && restored.keys?[0].flags == command, "keyboard persistence")
let timeline = playbackEvents(mixed)
check(timeline.map { $0.time } == [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 1, 1.1, 2], "mixed timeline ordering")
check(timeline[1].key?.isRepeat == true && timeline[3].click != nil, "mixed event dispatch")
mixed.clicks = []
try mixed.validate()
check(playbackEvents(mixed).count == 5, "keyboard only recording")
mixed.keys?.removeLast()
check((try? mixed.validate()) == nil, "reject unbalanced keyboard")
mixed.keys = [KeyInput(time: 0.2, code: 0, isDown: true, flags: 0, isRepeat: true)]
check((try? mixed.validate()) == nil, "reject orphan repeat")
mixed.keys = [KeyInput(time: 0.2, code: 0, isDown: false, flags: 0)]
check((try? mixed.validate()) == nil, "reject orphan key release")
let controlChord: UInt64 = (1 << 18) | (1 << 19) | (1 << 20)
check(isControlShortcut(code: 15, flags: controlChord, shortcutCodes: [15, 35, 53]), "exclude app shortcut")
check(!isControlShortcut(code: 0, flags: command, shortcutCodes: [15, 35, 53]), "keep app keyboard command")
check(!isControlShortcut(code: 15, flags: command, shortcutCodes: [15, 35, 53]), "keep ordinary command R")
let legacyData = try JSONEncoder().encode(recording)
let legacy = try JSONDecoder().decode(Recording.self, from: legacyData)
try legacy.validate()
check(legacy.version == 1 && legacy.keys == nil, "legacy click recording compatibility")
var flagged = recording.clicks[0]; flagged.flags = command
let flaggedRecording = Recording(version: 2, name: "보조키 클릭", duration: 3, screens: [screen], clicks: [flagged])
try flaggedRecording.validate()
check(playbackEvents(flaggedRecording)[0].click?.flags == command, "modifier click")
print("PASS: keyboard persistence, repeats, releases, mixed timeline, keyboard-only, legacy compatibility, control shortcut exclusion, modifier click")

// Regression and boundary cases. Each invalid value must fail before saving/replay.
func rejected(_ name: String, _ edit: (inout Recording) -> Void) {
    var value = recording; edit(&value)
    check((try? value.validate()) == nil, name)
}
rejected("negative duration") { $0.duration = -1 }
rejected("nan duration") { $0.duration = .nan }
rejected("infinite duration") { $0.duration = .infinity }
rejected("empty input") { $0.clicks = [] }
rejected("blank name") { $0.name = "  \n" }
rejected("long name") { $0.name = String(repeating: "a", count: 101) }
rejected("no screen") { $0.screens = [] }
rejected("duplicate displays") { $0.screens.append(screen) }
rejected("invalid width") { $0.screens[0].width = 0 }
rejected("nan origin") { $0.screens[0].x = .nan }
rejected("overflowing bounds") { $0.screens[0].x = .greatestFiniteMagnitude; $0.screens[0].width = .greatestFiniteMagnitude }
rejected("invalid pixel size") { $0.screens[0].pixelsWide = -1 }
rejected("negative time") { $0.clicks[0].down = -0.1 }
rejected("release precedes down") { $0.clicks[0].up = 0.1 }
rejected("overlapping clicks") { $0.clicks[1].down = 0.55 }
rejected("right edge is exclusive") { $0.clicks[0].x = 1920 }
rejected("bottom edge is exclusive") { $0.clicks[0].y = 1080 }
rejected("nan position") { $0.clicks[0].x = .nan }
rejected("unsupported mouse button") { $0.clicks[0].button = 2 }
rejected("invalid click count") { $0.clicks[0].count = 0 }
rejected("too many inputs") { $0.clicks = Array(repeating: Click(down: 0, up: 0, x: 0, y: 0, button: 0, count: 1), count: 100_001) }
rejected("v1 cannot contain keyboard") { $0.keys = keys }
for badKeys in [
    [KeyInput(time: -1, code: 0, isDown: true, flags: 0)],
    [KeyInput(time: .nan, code: 0, isDown: true, flags: 0)],
    [KeyInput(time: 0, code: 128, isDown: true, flags: 0)],
    [KeyInput(time: 0, code: 0, isDown: true, flags: 0), KeyInput(time: 4, code: 0, isDown: false, flags: 0)],
    [KeyInput(time: 1, code: 0, isDown: true, flags: 0), KeyInput(time: 0, code: 0, isDown: false, flags: 0)],
    [KeyInput(time: 0, code: 0, isDown: true, flags: 0), KeyInput(time: 1, code: 0, isDown: true, flags: 0)],
    [KeyInput(time: 0, code: 0, isDown: true, flags: 0), KeyInput(time: 1, code: 0, isDown: false, flags: 0, isRepeat: true)]
] { rejected("invalid keyboard sequence") { $0.version = 2; $0.keys = badKeys } }
var boundary = recording
boundary.clicks = [Click(down: 0, up: 180, x: 0, y: 0, button: 1, count: 3)]
boundary.duration = 180
try boundary.validate()

var focused = KeyboardCapture()
focused.record(KeyInput(time: 0, code: 0, isDown: true, flags: 0), excluded: false)
focused.record(KeyInput(time: 1, code: 0, isDown: false, flags: command), excluded: true)
check(focused.finish(at: 2).map { $0.time } == [0, 1], "release after focus change retained")
var suppressed = KeyboardCapture()
suppressed.record(KeyInput(time: 0, code: 15, isDown: true, flags: controlChord), excluded: true)
suppressed.record(KeyInput(time: 1, code: 15, isDown: true, flags: 0, isRepeat: true), excluded: false)
suppressed.record(KeyInput(time: 2, code: 15, isDown: false, flags: 0), excluded: false)
check(suppressed.finish(at: 3).isEmpty, "shortcut remains suppressed until release")
var duplicates = KeyboardCapture()
duplicates.append(KeyInput(time: 0, code: 0, isDown: true, flags: 0, isRepeat: true))
duplicates.append(KeyInput(time: 1, code: 0, isDown: true, flags: 0))
duplicates.append(KeyInput(time: 2, code: 0, isDown: true, flags: 0))
check(duplicates.finish(at: 3).count == 2, "duplicate down and orphan repeat ignored")
check(duplicates.finish(at: 3).count == 2, "finish is idempotent")

func click(_ time: Double, _ button: Int = 0) -> Click { Click(down: time, up: time, x: 100, y: 200, button: button, count: 1) }
var mouse = MouseCapture()
mouse.up(button: 0, time: 0)
mouse.down(click(1), excluded: false); mouse.drag(); mouse.up(button: 0, time: 2)
check(mouse.clicks.isEmpty, "drag excluded")
mouse.down(click(3), excluded: false); mouse.unsupportedGesture(); mouse.up(button: 0, time: 4)
check(mouse.clicks.isEmpty, "scroll while held cannot become click")
mouse.down(click(5), excluded: false); mouse.down(click(5.1, 1), excluded: false)
mouse.up(button: 0, time: 6); mouse.down(click(6.1), excluded: false)
mouse.up(button: 1, time: 7); mouse.up(button: 0, time: 8)
check(mouse.clicks.count == 3, "overlapping button lifetimes captured independently")
mouse = MouseCapture()
mouse.down(click(9), excluded: true); mouse.up(button: 0, time: 10)
check(mouse.clicks.isEmpty, "own UI excluded")
mouse.down(click(11, 1), excluded: false); mouse.up(button: 0, time: 11.1); mouse.up(button: 1, time: 12)
check(mouse.clicks.count == 1 && mouse.clicks[0].button == 1 && mouse.clicks[0].up == 12, "right click and mismatched release")
mouse.down(click(13), excluded: false); mouse.finish()
check(mouse.pending.isEmpty && mouse.clicks.count == 1, "incomplete click discarded")

// Deterministic randomized event streams must always produce valid, balanced recordings.
var seed: UInt64 = 431
func random(_ max: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(max)) }
for iteration in 0..<200 {
    var keyboard = KeyboardCapture(); var mouse = MouseCapture()
    for index in 0..<500 {
        let time = Double(index) / 100
        let code = UInt16(random(5))
        keyboard.record(KeyInput(time: time, code: code, isDown: random(2) == 0, flags: 0, isRepeat: false), excluded: random(5) == 0)
        switch random(5) {
        case 0: mouse.down(click(time, random(2)), excluded: random(8) == 0)
        case 1: mouse.up(button: random(2), time: time)
        case 2: mouse.drag()
        case 3: mouse.unsupportedGesture()
        default: break
        }
    }
    mouse.finish(); let keys = keyboard.finish(at: 5)
    if !keys.isEmpty || !mouse.clicks.isEmpty {
        let old = Recording(version: 2, name: "fuzz \(iteration)", duration: 5, screens: [screen], clicks: mouse.clicks, keys: keys)
        let inputs = playbackEvents(old).map { event -> RecordedInput in
            if let key = event.key { return RecordedInput(time: event.time, kind: key.isDown ? .keyDown : .keyUp, keyCode: key.code, isRepeat: key.isRepeat) }
            let c = event.click!
            return RecordedInput(time: event.time, kind: event.isDown ? .mouseDown : .mouseUp, x: c.x, y: c.y, button: c.button, clickCount: c.count)
        }
        let value = Recording(version: 3, name: "fuzz \(iteration)", duration: 5, screens: [screen], clicks: [], timeline: inputs)
        try value.validate()
        let times = playbackEvents(value).map(\.time)
        check(times == times.sorted(), "randomized timeline stays ordered")
    }
}

let mismatch = directory.appendingPathComponent(UUID().uuidString + ".json")
try JSONEncoder().encode(recording).write(to: mismatch)
check(store.load().1 == 2, "filename UUID mismatch rejected")
let symlink = directory.appendingPathComponent(UUID().uuidString + ".json")
try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: store.url(restored.id))
check(store.load().1 == 3, "symbolic link rejected")
let blockedDirectory = directory.appendingPathComponent("not-a-directory")
try Data().write(to: blockedDirectory)
let blockedStore = RecordingStore(directory: blockedDirectory)
check(blockedStore.load().1 == 1, "unreadable directory is reported")
check((try? blockedStore.save(recording)) == nil, "storage failure propagated")
try store.save(recording)
let attrs = try FileManager.default.attributesOfItem(atPath: store.url(recording.id).path)
check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "recording owner-only permissions")
let before = try Data(contentsOf: store.url(recording.id))
var badOverwrite = recording; badOverwrite.duration = -1
check((try? store.save(badOverwrite)) == nil, "invalid overwrite rejected")
let after = try Data(contentsOf: store.url(recording.id))
check(after == before, "failed validation preserves prior file")
print("PASS: validation boundaries, shortcut/focus transitions, mouse gestures, 200 randomized streams (100,000 steps), storage failures and permissions")

try timelineTests()
