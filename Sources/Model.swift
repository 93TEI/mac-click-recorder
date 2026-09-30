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
    var upFlags: UInt64? = nil
    var downOrder: Int? = nil
    var upOrder: Int? = nil
}

struct KeyInput: Codable {
    var time: Double
    var code: UInt16
    var isDown: Bool
    var flags: UInt64
    var isRepeat: Bool = false
    var order: Int? = nil
}

// Keeps repeats, ignores orphan releases, and balances keys held at recording end.
struct KeyboardCapture {
    private(set) var events: [KeyInput] = []
    private var held: Set<UInt16> = []
    private var suppressed: Set<UInt16> = []
    // Releases must still be captured if focus or shortcut modifiers change.
    mutating func record(_ event: KeyInput, excluded: Bool) {
        if !event.isDown {
            if suppressed.remove(event.code) != nil { return }
            append(event)
        } else if excluded {
            if held.contains(event.code) {
                append(KeyInput(time: event.time, code: event.code, isDown: false, flags: event.flags, order: event.order))
            }
            suppressed.insert(event.code)
        } else if !suppressed.contains(event.code) {
            append(event)
        }
    }
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
    mutating func finish(at time: Double, startingOrder: Int? = nil) -> [KeyInput] {
        for (index, code) in held.sorted().enumerated() {
            events.append(KeyInput(time: time, code: code, isDown: false, flags: 0, order: startingOrder.map { $0 + index }))
        }
        held.removeAll(); suppressed.removeAll()
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
    var timeline: [RecordedInput]? = nil
    var clickCount: Int { timeline?.filter { $0.kind == .mouseDown }.count ?? clicks.count }
    var keyCount: Int { timeline?.filter { $0.kind == .keyDown && $0.isRepeat != true }.count ?? (keys ?? []).filter { $0.isDown && !$0.isRepeat }.count }

    func validate() throws {
        let keys = keys ?? []
        guard (1...3).contains(version), duration.isFinite, duration >= 0, duration <= 180,
              clicks.count + keys.count <= 100_000,
              !screens.isEmpty, screens.count <= 32,
              Set(screens.map(\.id)).count == screens.count,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              version >= 2 || keys.isEmpty else { throw StoreError.invalid }
        for s in screens {
            guard [s.x, s.y, s.width, s.height].allSatisfy({ $0.isFinite }),
                  s.width > 0, s.height > 0, (s.x + s.width).isFinite, (s.y + s.height).isFinite, s.pixelsWide > 0, s.pixelsHigh > 0 else { throw StoreError.invalid }
        }
        if version == 3 {
            guard let timeline, clicks.isEmpty, keys.isEmpty else { throw StoreError.invalid }
            try validateTimeline(timeline, duration: duration, screens: screens)
            return
        }
        guard timeline == nil, !clicks.isEmpty || !keys.isEmpty else { throw StoreError.invalid }
        var previous = 0.0
        var buttonRelease: [Int: Double] = [:]
        for c in clicks {
            guard [c.down, c.up, c.x, c.y].allSatisfy({ $0.isFinite }),
                  c.down >= (version >= 3 ? buttonRelease[c.button, default: 0] : previous), c.up >= c.down, c.up <= duration,
                  (0...1).contains(c.button), (1...3).contains(c.count),
                  screens.contains(where: { c.x >= $0.x && c.x < $0.x + $0.width && c.y >= $0.y && c.y < $0.y + $0.height })
            else { throw StoreError.invalid }
            previous = c.up; buttonRelease[c.button] = c.up
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

enum StoreError: LocalizedError {
    case invalid
    var errorDescription: String? { "녹화 데이터의 시간·입력 순서 또는 화면 정보가 올바르지 않습니다." }
}

struct RecordingStore {
    static let maximumFileBytes = 128 * 1024 * 1024
    let directory: URL
    func load() -> ([Recording], Int) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], 0) }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return ([], 1) }
        var recordings: [Recording] = []
        var failures = 0
        for file in files where file.pathExtension == "json" {
            do {
                let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let size = attributes.fileSize, size <= Self.maximumFileBytes else { throw StoreError.invalid }
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recording)
        guard data.count <= Self.maximumFileBytes else { throw StoreError.invalid }
        try data.write(to: url(recording.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(recording.id).path)
    }
    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: url(id)) }
    func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

struct PlaybackEvent {
    let time: Double
    let click: Click?
    let isDown: Bool
    var key: KeyInput? = nil
    var order: Int? = nil
    var input: RecordedInput? = nil
}

func playbackEvents(_ recording: Recording) -> [PlaybackEvent] {
    if let timeline = recording.timeline {
        return timeline.enumerated().map { PlaybackEvent(time: $0.element.time, click: nil, isDown: $0.element.kind == .mouseDown || $0.element.kind == .keyDown, order: $0.offset, input: $0.element) }
    }
    let mouse = recording.clicks.flatMap { [PlaybackEvent(time: $0.down, click: $0, isDown: true, order: $0.downOrder), PlaybackEvent(time: $0.up, click: $0, isDown: false, order: $0.upOrder)] }
    let keyboard = (recording.keys ?? []).map { PlaybackEvent(time: $0.time, click: nil, isDown: $0.isDown, key: $0, order: $0.order) }
    return (mouse + keyboard).enumerated().sorted {
        $0.element.time == $1.element.time ? ($0.element.order ?? $0.offset) < ($1.element.order ?? $1.offset) : $0.element.time < $1.element.time
    }.map(\.element)
}

// A generation invalidates every callback from an earlier playback.
final class PlaybackTicket {
    private(set) var generation = 0
    func cancel() { generation += 1 }
    func accepts(_ value: Int) -> Bool { value == generation }
}

// Independent button lifetimes preserve overlapping clicks without inventing input.
struct MouseCapture {
    private(set) var clicks: [Click] = []
    private(set) var pending: [Int: Click] = [:]
    private(set) var excluded = 0
    private var held: Set<Int> = []

    mutating func down(_ click: Click, excluded shouldExclude: Bool) {
        guard held.insert(click.button).inserted else { return }
        if !shouldExclude { pending[click.button] = click }
    }
    mutating func up(button: Int, time: Double, order: Int? = nil, flags: UInt64? = nil) {
        held.remove(button)
        guard var click = pending.removeValue(forKey: button) else { return }
        click.up = time; click.upOrder = order; click.upFlags = flags
        clicks.append(click)
    }
    mutating func unsupportedGesture() {
        excluded += 1
        pending.removeAll()
    }
    mutating func drag(button: Int? = nil) {
        if let button {
            if pending.removeValue(forKey: button) != nil { excluded += 1 }
        } else {
            excluded += pending.count; pending.removeAll()
        }
    }
    mutating func finish() {
        excluded += pending.count
        pending.removeAll(); held.removeAll()
    }
}

struct PlaybackRun {
    // v3 shares the existing immutable timeline buffer instead of copying every event.
    private let events: [PlaybackEvent]
    private let timeline: [RecordedInput]?
    var index = 0
    let start: TimeInterval
    let duration: Double
    let screens: [ScreenLayout]
    init(recording: Recording, start: TimeInterval) {
        self.start = start; duration = recording.duration; screens = recording.screens
        timeline = recording.timeline
        events = timeline == nil ? playbackEvents(recording) : []
    }
    var eventCount: Int { timeline?.count ?? events.count }
    func event(at index: Int) -> PlaybackEvent {
        if let timeline {
            let input = timeline[index]
            return PlaybackEvent(time: input.time, click: nil, isDown: input.kind == .mouseDown || input.kind == .keyDown, order: index, input: input)
        }
        return events[index]
    }
    var nextTime: Double { index < eventCount ? (timeline?[index].time ?? events[index].time) : duration }
}
