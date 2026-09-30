import Foundation

// Array order is the tie-breaker: mouse, wheel and keyboard share one clock.
struct RecordedInput: Codable, Equatable {
    enum Kind: String, Codable { case move, mouseDown, mouseUp, drag, scroll, keyDown, keyUp, modifiers }
    var time: Double
    var kind: Kind
    var flags: UInt64 = 0
    var x: Double? = nil
    var y: Double? = nil
    var deltaX: Int64? = nil
    var deltaY: Int64? = nil
    var pressure: Double? = nil
    var button: Int? = nil
    var clickCount: Int? = nil
    var keyCode: UInt16? = nil
    var isRepeat: Bool? = nil
    var scroll: ScrollInput? = nil
}

struct ScrollInput: Codable, Equatable {
    var vertical: Int64
    var horizontal: Int64
    var depth: Int64 = 0
    var pointVertical: Int64 = 0
    var pointHorizontal: Int64 = 0
    var pointDepth: Int64 = 0
    var fixedVertical: Double = 0
    var fixedHorizontal: Double = 0
    var fixedDepth: Double = 0
    var continuous: Int64 = 0
    var phase: Int64 = 0
    var momentumPhase: Int64 = 0
    var count: Int64 = 0
}

let modifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)
let modifierKeys: [(code: UInt16, flag: UInt64, device: UInt64)] = [
    (56, 1 << 17, 0x2), (60, 1 << 17, 0x4),
    (59, 1 << 18, 0x1), (62, 1 << 18, 0x2000),
    (58, 1 << 19, 0x20), (61, 1 << 19, 0x40),
    (55, 1 << 20, 0x8), (54, 1 << 20, 0x10), (63, 1 << 23, 0)
]

func updateModifierKeys(_ held: inout Set<UInt16>, code: UInt16, flags: UInt64) {
    guard let modifier = modifierKeys.first(where: { $0.code == code }) else { return }
    let down: Bool
    if flags & modifier.flag == 0 { down = false }
    else if flags & 0x207f != 0 && modifier.device != 0 { down = flags & modifier.device != 0 }
    else { down = modifier.device == 0 || !held.contains(code) }
    if down { held.insert(code) } else { held.remove(code) }
}

struct TimelineCapture {
    private(set) var events: [RecordedInput] = []
    private var keys: Set<UInt16> = []
    private var suppressedKeys: Set<UInt16> = []
    private var buttons: [Int: RecordedInput] = [:]
    private var modifiers: Set<UInt16> = []
    var ignoreInitialModifiers = false

    mutating func record(_ event: RecordedInput, excluded: Bool = false) {
        switch event.kind {
        case .keyDown:
            guard let code = event.keyCode else { return }
            if excluded {
                if keys.remove(code) != nil { events.append(RecordedInput(time: event.time, kind: .keyUp, flags: event.flags, keyCode: code, isRepeat: false)) }
                suppressedKeys.insert(code); return
            }
            guard !suppressedKeys.contains(code), (event.isRepeat ?? false) == keys.contains(code) else { return }
            keys.insert(code)
        case .keyUp:
            guard let code = event.keyCode, suppressedKeys.remove(code) == nil, keys.remove(code) != nil else { return }
        case .mouseDown:
            guard !excluded, let button = event.button, buttons[button] == nil else { return }
            buttons[button] = event
        case .mouseUp:
            guard let button = event.button, buttons.removeValue(forKey: button) != nil else { return }
        case .drag:
            guard let button = event.button, buttons[button] != nil else { return }
            buttons[button] = event
        case .modifiers:
            if ignoreInitialModifiers {
                if event.flags & modifierMask == 0 { ignoreInitialModifiers = false }
                return
            }
            guard !excluded, let code = event.keyCode, modifierKeys.contains(where: { $0.code == code }) else { return }
            updateModifierKeys(&modifiers, code: code, flags: event.flags)
        case .move, .scroll:
            guard !excluded else { return }
        }
        events.append(event)
    }

    mutating func removeControlShortcutTail() {
        // Discard only the trailing modifier presses that introduce our control chord.
        var start = events.count
        while start > 0 {
            let event = events[start - 1]
            if event.kind == .modifiers && event.flags & modifierMask == 0 { break }
            guard event.kind == .modifiers || event.kind == .move else { break }
            start -= 1
        }
        let baseFlags = start > 0 ? events[start - 1].flags : 0
        let suffix = events[start...].filter { $0.kind != .modifiers }.map { value -> RecordedInput in
            var input = value; input.flags = (input.flags & ~modifierMask) | (baseFlags & modifierMask); return input
        }
        events.replaceSubrange(start..., with: suffix)
        modifiers.removeAll()
        for event in events where event.kind == .modifiers {
            if let code = event.keyCode { updateModifierKeys(&modifiers, code: code, flags: event.flags) }
        }
        ignoreInitialModifiers = true
    }

    mutating func finish(at time: Double) -> [RecordedInput] {
        for button in buttons.keys.sorted() {
            let held = buttons[button]!
            events.append(RecordedInput(time: time, kind: .mouseUp, x: held.x, y: held.y, button: button, clickCount: held.clickCount ?? 1))
        }
        for code in keys.sorted() { events.append(RecordedInput(time: time, kind: .keyUp, keyCode: code, isRepeat: false)) }
        var remaining = modifiers
        for code in modifiers.sorted() {
            remaining.remove(code)
            let flags = modifierKeys.filter { remaining.contains($0.code) }.reduce(UInt64(0)) { $0 | $1.flag | $1.device }
            events.append(RecordedInput(time: time, kind: .modifiers, flags: flags, keyCode: code))
        }
        buttons.removeAll(); keys.removeAll(); modifiers.removeAll(); suppressedKeys.removeAll()
        return events
    }
}

func validateTimeline(_ events: [RecordedInput], duration: Double, screens: [ScreenLayout]) throws {
    guard !events.isEmpty, events.count <= 100_000 else { throw StoreError.invalid }
    var previous = 0.0
    var keys: Set<UInt16> = []
    var buttons: Set<Int> = []
    var modifiers: Set<UInt16> = []
    for event in events {
        guard event.time.isFinite, event.time >= previous, event.time <= duration else { throw StoreError.invalid }
        previous = event.time
        if let pressure = event.pressure { guard pressure.isFinite && (0...1).contains(pressure) else { throw StoreError.invalid } }
        switch event.kind {
        case .move, .mouseDown, .mouseUp, .drag, .scroll:
            guard let x = event.x, let y = event.y, x.isFinite, y.isFinite,
                  screens.contains(where: { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }) else { throw StoreError.invalid }
            if event.kind == .mouseDown || event.kind == .mouseUp || event.kind == .drag {
                guard let button = event.button, (0...2).contains(button), let count = event.clickCount, (1...3).contains(count) else { throw StoreError.invalid }
                if event.kind == .mouseDown { guard buttons.insert(button).inserted else { throw StoreError.invalid } }
                else if event.kind == .mouseUp { guard buttons.remove(button) != nil else { throw StoreError.invalid } }
                else { guard buttons.contains(button) else { throw StoreError.invalid } }
            }
            if event.kind == .scroll {
                guard let scroll = event.scroll,
                      [scroll.fixedVertical, scroll.fixedHorizontal, scroll.fixedDepth].allSatisfy({ $0.isFinite }),
                      [scroll.vertical, scroll.horizontal, scroll.depth].allSatisfy({ Int64(Int32.min)...Int64(Int32.max) ~= $0 }),
                      (0...1).contains(scroll.continuous) else { throw StoreError.invalid }
            }
        case .keyDown, .keyUp:
            guard let code = event.keyCode, code <= 127, !modifierKeys.contains(where: { $0.code == code }) else { throw StoreError.invalid }
            if event.kind == .keyDown {
                guard (event.isRepeat ?? false) == keys.contains(code) else { throw StoreError.invalid }
                keys.insert(code)
            } else {
                guard event.isRepeat != true, keys.remove(code) != nil else { throw StoreError.invalid }
            }
        case .modifiers:
            guard let code = event.keyCode, modifierKeys.contains(where: { $0.code == code }) else { throw StoreError.invalid }
            updateModifierKeys(&modifiers, code: code, flags: event.flags)
        }
    }
    guard keys.isEmpty, buttons.isEmpty, modifiers.isEmpty else { throw StoreError.invalid }
}
