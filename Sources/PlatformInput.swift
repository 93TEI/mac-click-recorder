import CoreGraphics

func recordedInput(_ event: CGEvent, type: CGEventType, time: Double) -> RecordedInput? {
    var input = RecordedInput(time: time, kind: .move, flags: event.flags.rawValue)
    switch type {
    case .keyDown, .keyUp, .flagsChanged:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard (0...127).contains(code) else { return nil }
        input.kind = type == .keyDown ? .keyDown : (type == .keyUp ? .keyUp : .modifiers)
        input.keyCode = UInt16(code)
        if type != .flagsChanged { input.isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 }
    case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        input.x = event.location.x; input.y = event.location.y
        input.deltaX = event.getIntegerValueField(.mouseEventDeltaX)
        input.deltaY = event.getIntegerValueField(.mouseEventDeltaY)
        input.pressure = event.getDoubleValueField(.mouseEventPressure)
        if type == .mouseMoved { break }
        input.button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged { input.button = 0 }
        if type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged { input.button = 1 }
        guard let button = input.button, (0...2).contains(button) else { return nil }
        input.clickCount = max(1, min(3, Int(event.getIntegerValueField(.mouseEventClickState))))
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: input.kind = .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: input.kind = .mouseUp
        default: input.kind = .drag
        }
    case .scrollWheel:
        input.kind = .scroll; input.x = event.location.x; input.y = event.location.y
        input.scroll = ScrollInput(
            vertical: event.getIntegerValueField(.scrollWheelEventDeltaAxis1), horizontal: event.getIntegerValueField(.scrollWheelEventDeltaAxis2), depth: event.getIntegerValueField(.scrollWheelEventDeltaAxis3),
            pointVertical: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), pointHorizontal: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), pointDepth: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3),
            fixedVertical: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), fixedHorizontal: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), fixedDepth: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3),
            continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous), phase: event.getIntegerValueField(.scrollWheelEventScrollPhase), momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase), count: event.getIntegerValueField(.scrollWheelEventScrollCount))
    default: return nil
    }
    return input
}

func makeInputEvent(_ input: RecordedInput, source: CGEventSource?, tag: Int64) -> CGEvent? {
    let event: CGEvent?
    switch input.kind {
    case .keyDown, .keyUp, .modifiers:
        guard let code = input.keyCode else { return nil }
        event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: input.kind == .keyDown)
        if input.kind == .modifiers { event?.type = .flagsChanged }
        event?.setIntegerValueField(.keyboardEventAutorepeat, value: input.isRepeat == true ? 1 : 0)
    case .move, .mouseDown, .mouseUp, .drag:
        guard let x = input.x, let y = input.y, let button = CGMouseButton(rawValue: UInt32(input.button ?? 0)) else { return nil }
        let type: CGEventType
        switch input.kind {
        case .move: type = .mouseMoved
        case .mouseDown: type = button == .left ? .leftMouseDown : (button == .right ? .rightMouseDown : .otherMouseDown)
        case .mouseUp: type = button == .left ? .leftMouseUp : (button == .right ? .rightMouseUp : .otherMouseUp)
        default: type = button == .left ? .leftMouseDragged : (button == .right ? .rightMouseDragged : .otherMouseDragged)
        }
        event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(input.clickCount ?? 1))
        event?.setIntegerValueField(.mouseEventDeltaX, value: input.deltaX ?? 0)
        event?.setIntegerValueField(.mouseEventDeltaY, value: input.deltaY ?? 0)
        event?.setDoubleValueField(.mouseEventPressure, value: input.pressure ?? 0)
    case .scroll:
        guard let scroll = input.scroll, let x = input.x, let y = input.y else { return nil }
        event = CGEvent(scrollWheelEvent2Source: source, units: scroll.continuous == 0 ? .line : .pixel, wheelCount: 3,
                        wheel1: Int32(clamping: scroll.vertical), wheel2: Int32(clamping: scroll.horizontal), wheel3: Int32(clamping: scroll.depth))
        event?.location = CGPoint(x: x, y: y)
        let integerFields: [(CGEventField, Int64)] = [(.scrollWheelEventDeltaAxis1, scroll.vertical), (.scrollWheelEventDeltaAxis2, scroll.horizontal), (.scrollWheelEventDeltaAxis3, scroll.depth),
            (.scrollWheelEventPointDeltaAxis1, scroll.pointVertical), (.scrollWheelEventPointDeltaAxis2, scroll.pointHorizontal), (.scrollWheelEventPointDeltaAxis3, scroll.pointDepth),
            (.scrollWheelEventIsContinuous, scroll.continuous), (.scrollWheelEventScrollPhase, scroll.phase), (.scrollWheelEventMomentumPhase, scroll.momentumPhase), (.scrollWheelEventScrollCount, scroll.count)]
        for (field, value) in integerFields { event?.setIntegerValueField(field, value: value) }
        for (field, value): (CGEventField, Double) in [(.scrollWheelEventFixedPtDeltaAxis1, scroll.fixedVertical), (.scrollWheelEventFixedPtDeltaAxis2, scroll.fixedHorizontal), (.scrollWheelEventFixedPtDeltaAxis3, scroll.fixedDepth)] { event?.setDoubleValueField(field, value: value) }
    }
    event?.flags = CGEventFlags(rawValue: input.flags)
    event?.setIntegerValueField(.eventSourceUserData, value: tag)
    return event
}
