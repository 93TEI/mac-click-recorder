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
