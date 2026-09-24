import Foundation

struct ScreenLayout: Codable, Equatable {
    var id: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var pixelsWide: Int
    var pixelsHigh: Int
}

struct Click: Codable {
    var down: Double
    var up: Double
    var x: Double
    var y: Double
    var button: Int
    var count: Int
    var flags: UInt64? = nil
}

struct KeyInput: Codable {
    var time: Double
    var code: UInt16
    var isDown: Bool
    var flags: UInt64
    var isRepeat: Bool = false
}

// Keeps repeats, ignores orphan releases, and balances keys held at recording end.
struct KeyboardCapture {
    private(set) var events: [KeyInput] = []
    private var held: Set<UInt16> = []
    mutating func append(_ event: KeyInput) {
        if event.isDown {
            guard !event.isRepeat || held.contains(event.code) else { return }
            guard event.isRepeat || !held.contains(event.code) else { return }
            held.insert(event.code)
        } else {
            guard held.remove(event.code) != nil else { return }
        }
        events.append(event)
    }
    mutating func finish(at time: Double) -> [KeyInput] {
        for code in held.sorted() { events.append(KeyInput(time: time, code: code, isDown: false, flags: 0)) }
        held.removeAll()
        return events
    }
}

func isControlShortcut(code: UInt16, flags: UInt64, shortcutCodes: [UInt16]) -> Bool {
    // CGEventFlags: Control, Option, Command. Shift may also be present.
    let required: UInt64 = (1 << 18) | (1 << 19) | (1 << 20)
    return flags & required == required && shortcutCodes.contains(code)
}

struct Recording: Codable {
    var version = 1
    var id = UUID()
    var name: String
    var duration: Double
    var screens: [ScreenLayout]
    var clicks: [Click]
    var keys: [KeyInput]? = nil

    func validate() throws {
        let keys = keys ?? []
        guard (1...2).contains(version), duration.isFinite, duration >= 0, duration <= 180,
              !clicks.isEmpty || !keys.isEmpty, clicks.count + keys.count <= 100_000,
              !screens.isEmpty, version == 2 || keys.isEmpty else { throw StoreError.invalid }
        for s in screens {
            guard [s.x, s.y, s.width, s.height].allSatisfy({ $0.isFinite }),
                  s.width > 0, s.height > 0, s.pixelsWide > 0, s.pixelsHigh > 0 else { throw StoreError.invalid }
        }
        var previous = 0.0
        for c in clicks {
            guard [c.down, c.up, c.x, c.y].allSatisfy({ $0.isFinite }),
                  c.down >= previous, c.up >= c.down, c.up <= duration,
                  (0...1).contains(c.button), (1...3).contains(c.count),
                  screens.contains(where: { c.x >= $0.x && c.x < $0.x + $0.width && c.y >= $0.y && c.y < $0.y + $0.height })
            else { throw StoreError.invalid }
            previous = c.up
        }
        previous = 0
        var held: Set<UInt16> = []
        for key in keys {
            guard key.time.isFinite, key.time >= previous, key.time <= duration, key.code <= 127 else { throw StoreError.invalid }
            if key.isDown {
                guard key.isRepeat == held.contains(key.code) else { throw StoreError.invalid }
                held.insert(key.code)
            } else {
                guard !key.isRepeat, held.remove(key.code) != nil else { throw StoreError.invalid }
            }
            previous = key.time
        }
        guard held.isEmpty else { throw StoreError.invalid }
    }
}

enum StoreError: Error { case invalid }

struct RecordingStore {
    let directory: URL
    func load() -> ([Recording], Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var recordings: [Recording] = []
        var failures = 0
        for file in files where file.pathExtension == "json" {
            do {
                let record = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: file))
                try record.validate()
                guard file.deletingPathExtension().lastPathComponent == record.id.uuidString else { throw StoreError.invalid }
                recordings.append(record)
            } catch { failures += 1 }
        }
        return (recordings.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, failures)
    }
    func save(_ recording: Recording) throws {
        try recording.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: url(recording.id), options: .atomic)
    }
    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: url(id)) }
    func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

struct PlaybackEvent {
    let time: Double
    let click: Click?
    let isDown: Bool
    var key: KeyInput? = nil
}

func playbackEvents(_ recording: Recording) -> [PlaybackEvent] {
    let mouse = recording.clicks.flatMap { [PlaybackEvent(time: $0.down, click: $0, isDown: true), PlaybackEvent(time: $0.up, click: $0, isDown: false)] }
    let keyboard = (recording.keys ?? []).map { PlaybackEvent(time: $0.time, click: nil, isDown: $0.isDown, key: $0) }
    return (mouse + keyboard).enumerated().sorted {
        $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
    }.map(\.element)
}

// A generation invalidates every callback from an earlier playback.
final class PlaybackTicket {
    private(set) var generation = 0
    func cancel() { generation += 1 }
    func accepts(_ value: Int) -> Bool { value == generation }
}
