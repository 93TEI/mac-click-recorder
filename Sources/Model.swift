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
}

struct Recording: Codable {
    var version = 1
    var id = UUID()
    var name: String
    var duration: Double
    var screens: [ScreenLayout]
    var clicks: [Click]

    func validate() throws {
        guard version == 1, duration.isFinite, duration >= 0, duration <= 180,
              !clicks.isEmpty, clicks.count <= 100_000, !screens.isEmpty else { throw StoreError.invalid }
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
    let click: Click
    let isDown: Bool
}

func playbackEvents(_ recording: Recording) -> [PlaybackEvent] {
    recording.clicks.flatMap { [PlaybackEvent(time: $0.down, click: $0, isDown: true), PlaybackEvent(time: $0.up, click: $0, isDown: false)] }
}

// A generation invalidates every callback from an earlier playback.
final class PlaybackTicket {
    private(set) var generation = 0
    func cancel() { generation += 1 }
    func accepts(_ value: Int) -> Bool { value == generation }
}
