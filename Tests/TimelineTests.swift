import Foundation

func timelineTests() throws {
    let screen = ScreenLayout(id: 1, x: 0, y: 0, width: 1920, height: 1080, pixelsWide: 3840, pixelsHigh: 2160)
    let chord: UInt64 = (1 << 17)
    let events: [RecordedInput] = [
        RecordedInput(time: 0.25, kind: .move, x: 100, y: 100),
        RecordedInput(time: 0.5, kind: .modifiers, flags: chord, keyCode: 56),
        RecordedInput(time: 0.5, kind: .keyDown, flags: chord, keyCode: 0, isRepeat: false),
        RecordedInput(time: 0.5, kind: .mouseDown, flags: chord, x: 100, y: 100, button: 0, clickCount: 1),
        RecordedInput(time: 0.6, kind: .drag, flags: chord, x: 120, y: 140, button: 0, clickCount: 1),
        RecordedInput(time: 0.7, kind: .keyDown, flags: chord, keyCode: 0, isRepeat: true),
        RecordedInput(time: 0.8, kind: .mouseDown, flags: chord, x: 120, y: 140, button: 1, clickCount: 1),
        RecordedInput(time: 0.9, kind: .scroll, flags: chord, x: 120, y: 140, scroll: ScrollInput(vertical: -3, horizontal: 2, pointVertical: -12, pointHorizontal: 8, fixedVertical: -3.25, fixedHorizontal: 2.5, continuous: 1, phase: 2, momentumPhase: 1)),
        RecordedInput(time: 1, kind: .mouseUp, flags: chord, x: 120, y: 140, button: 1, clickCount: 1),
        RecordedInput(time: 1, kind: .keyUp, flags: chord, keyCode: 0, isRepeat: false),
        RecordedInput(time: 1, kind: .mouseUp, flags: chord, x: 120, y: 140, button: 0, clickCount: 1),
        RecordedInput(time: 1.2, kind: .modifiers, keyCode: 56)
    ]
    let recording = Recording(version: 3, name: "one timeline", duration: 2, screens: [screen], clicks: [], timeline: events)
    try recording.validate()
    let restored = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(recording))
    check(restored.timeline == events, "v3 timeline round trip is lossless")
    check(playbackEvents(restored).compactMap(\.input) == events, "same-time interleaved mouse/key order preserved")
    check(restored.clickCount == 2 && restored.keyCount == 1, "summary counts ignore repeats/movement")
    var capture = TimelineCapture()
    for event in events { capture.record(event) }
    check(capture.finish(at: 2) == events, "capture preserves the full valid stream")
    check(capture.finish(at: 2) == events, "timeline finish idempotent")
    var held = TimelineCapture()
    for event in events.prefix(8) { held.record(event) }
    let balanced = held.finish(at: 1)
    try validateTimeline(balanced, duration: 1, screens: [screen])
    check(balanced.suffix(4).map(\.kind) == [.mouseUp, .mouseUp, .keyUp, .modifiers], "end releases overlapping mouse/key/modifiers")
    check(balanced.first { $0.kind == .mouseUp && $0.button == 0 }?.x == 120, "held drag releases at last drag coordinate")
    var initial = TimelineCapture(); initial.ignoreInitialModifiers = true
    initial.record(RecordedInput(time: 0, kind: .modifiers, keyCode: 55))
    initial.record(RecordedInput(time: 0.1, kind: .move, x: 10, y: 10))
    check(initial.finish(at: 1).count == 1, "initial recording-hotkey release ignored")
    var own = TimelineCapture()
    own.record(RecordedInput(time: 0, kind: .move, x: 10, y: 10))
    own.record(RecordedInput(time: 0.1, kind: .modifiers, flags: 1 << 18, keyCode: 59))
    own.record(RecordedInput(time: 0.2, kind: .modifiers, flags: (1 << 18) | (1 << 19), keyCode: 58))
    own.record(RecordedInput(time: 0.3, kind: .modifiers, flags: (1 << 18) | (1 << 19) | (1 << 20), keyCode: 55))
    own.removeControlShortcutTail()
    check(own.finish(at: 1).count == 1, "recording-control modifier prefix removed")
    var focus = TimelineCapture()
    focus.record(RecordedInput(time: 0, kind: .keyDown, keyCode: 0))
    focus.record(RecordedInput(time: 1, kind: .keyUp, keyCode: 0), excluded: true)
    check(focus.finish(at: 2).last?.time == 1, "release survives focus change")
    var orphan = TimelineCapture()
    orphan.record(RecordedInput(time: 0, kind: .keyUp, keyCode: 0))
    orphan.record(RecordedInput(time: 0, kind: .keyDown, keyCode: 0, isRepeat: true))
    orphan.record(RecordedInput(time: 0, kind: .drag, x: 10, y: 10, button: 0, clickCount: 1))
    orphan.record(RecordedInput(time: 0, kind: .mouseUp, x: 10, y: 10, button: 0, clickCount: 1))
    check(orphan.finish(at: 1).isEmpty, "orphan releases/repeats/drags ignored")
    func reject(_ label: String, _ mutate: (inout [RecordedInput]) -> Void) {
        var altered = events; mutate(&altered)
        check((try? validateTimeline(altered, duration: 2, screens: [screen])) == nil, label)
    }
    reject("timeline cannot be empty") { $0 = [] }
    reject("negative time rejected") { $0[0].time = -1 }
    reject("nan time rejected") { $0[0].time = .nan }
    reject("nonmonotonic time rejected") { $0[5].time = 0 }
    reject("late event rejected") { $0[$0.count - 1].time = 3 }
    reject("missing position rejected") { $0[0].x = nil }
    reject("invalid position rejected") { $0[0].x = .infinity }
    reject("out of screen rejected") { $0[0].y = 1080 }
    reject("invalid button rejected") { $0[3].button = 99 }
    reject("invalid count rejected") { $0[3].clickCount = 0 }
    reject("invalid pressure rejected") { $0[3].pressure = .nan }
    reject("missing wheel data rejected") { $0[7].scroll = nil }
    reject("invalid wheel fraction rejected") { $0[7].scroll?.fixedVertical = .nan }
    reject("overflowing wheel lines rejected") { $0[7].scroll?.vertical = .max }
    reject("invalid wheel unit rejected") { $0[7].scroll?.continuous = 2 }
    reject("invalid key rejected") { $0[2].keyCode = 200 }
    reject("repeat without down rejected") { $0[2].isRepeat = true }
    reject("duplicate nonrepeat down rejected") { $0[5].isRepeat = false }
    reject("unbalanced key rejected") { $0.remove(at: 9) }
    reject("unbalanced button rejected") { $0.remove(at: 10) }
    reject("unbalanced modifier rejected") { $0.removeLast() }
    reject("too many events rejected") { $0 = Array(repeating: events[0], count: 100_001) }
    // Independent deterministic random stream with motion/drag/wheel and overlapping keys.
    var seed: UInt64 = 934
    func random(_ max: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(max)) }
    for _ in 0..<200 {
        var capture = TimelineCapture()
        for n in 0..<500 {
            let kind: RecordedInput.Kind = [.move, .mouseDown, .mouseUp, .drag, .scroll, .keyDown, .keyUp][random(7)]
            let t = Double(n / 3) / 100 // Deliberately equal timestamps.
            if kind == .keyDown || kind == .keyUp {
                capture.record(RecordedInput(time: t, kind: kind, keyCode: UInt16(random(4)), isRepeat: kind == .keyDown && random(4) == 0), excluded: random(10) == 0)
            } else {
                capture.record(RecordedInput(time: t, kind: kind, x: Double(random(1900)), y: Double(random(1000)), button: random(3), clickCount: 1, scroll: kind == .scroll ? ScrollInput(vertical: Int64(random(11) - 5), horizontal: Int64(random(11) - 5)) : nil), excluded: random(10) == 0)
            }
        }
        let result = capture.finish(at: 2)
        try validateTimeline(result, duration: 2, screens: [screen])
        let r = Recording(version: 3, name: "random", duration: 2, screens: [screen], clicks: [], timeline: result)
        let restored = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(r))
        check(restored.timeline == result && playbackEvents(restored).compactMap(\.input) == result, "randomized unified timeline remains lossless")
    }
    print("PASS: unified v3 timeline, same-time ordering, movement/drag/scroll/chords, interrupted holds, invalid data and 200 randomized mixed streams (100,000 steps)")
}
