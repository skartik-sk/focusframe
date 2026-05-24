import Foundation
import Cocoa

final class KeyboardMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var events: [KeyPressEvent] = []
    private var startTime: CFTimeInterval = 0
    private var outputURL: URL?
    private var isPaused = false
    private var pauseStartedAt: CFTimeInterval?
    private var accumulatedPauseDuration: CFTimeInterval = 0
    private let lock = NSLock()

    func start(outputURL: URL) {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)
        lock.lock()
        events.removeAll()
        startTime = CACurrentMediaTime()
        isPaused = false
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        lock.unlock()
        startAppKitFallbackMonitors()

        guard PrivacyPermissions.hasUsageDescription(.inputMonitoring) else {
            print("Keyboard monitor input monitoring usage description is missing. Run the app bundle so macOS can grant keyboard shortcut capture.")
            return
        }

        if !KeyboardCapturePermissions.reliableCaptureAuthorized {
            _ = KeyboardCapturePermissions.requestInputMonitoring()
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, userInfo in
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.record(event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Keyboard monitor event tap could not start. AppKit fallback remains active for in-app keys, but Input Monitoring is required for reliable keyboard badges.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() -> URL? {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        guard let outputURL else { return nil }
        lock.lock()
        let savedEvents = events.sorted { $0.timestamp < $1.timestamp }
        lock.unlock()
        return KeyboardMonitor.persist(events: savedEvents, to: outputURL)
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPaused else { return }
        isPaused = true
        pauseStartedAt = CACurrentMediaTime()
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        if isPaused, let pauseStartedAt {
            accumulatedPauseDuration += CACurrentMediaTime() - pauseStartedAt
        }
        isPaused = false
        pauseStartedAt = nil
    }

    private func record(event: CGEvent) {
        let flags = event.flags
        let modifiers = ModifierFlags(from: flags)
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let keyLabel = KeyPressEventFormatter.characters(for: keyCode, cgEvent: event) else {
            return
        }

        appendEvent(keyCode: keyCode, modifiers: modifiers, characters: keyLabel)
    }

    private func record(event: NSEvent) {
        let keyCode = UInt16(event.keyCode)
        guard let keyLabel = KeyPressEventFormatter.characters(for: keyCode, nsEvent: event) else {
            return
        }
        appendEvent(
            keyCode: keyCode,
            modifiers: ModifierFlags(nsEventFlags: event.modifierFlags),
            characters: keyLabel
        )
    }

    private func appendEvent(keyCode: UInt16, modifiers: ModifierFlags, characters: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isPaused else { return }
        let timestamp = CACurrentMediaTime() - startTime - accumulatedPauseDuration
        guard timestamp.isFinite, timestamp >= 0 else { return }
        let display = modifiers.symbolString + characters
        if let last = events.last,
           last.keyCode == keyCode,
           last.modifiers == modifiers,
           abs(last.timestamp - timestamp) < 0.06 {
            return
        }

        events.append(
            KeyPressEvent(
                id: UUID(),
                timestamp: timestamp,
                keyCode: keyCode,
                modifiers: modifiers,
                characters: characters,
                displayString: display
            )
        )
    }

    private func startAppKitFallbackMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event: event)
            return event
        }
    }

    static func persist(events: [KeyPressEvent], to outputURL: URL) -> URL? {
        let safeEvents = KeyPressEvent.sanitized(events)
        guard !safeEvents.isEmpty else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        do {
            let data = try JSONEncoder().encode(safeEvents)
            try data.write(to: outputURL)
            return outputURL
        } catch {
            return nil
        }
    }
}

private extension ModifierFlags {
    init(nsEventFlags flags: NSEvent.ModifierFlags) {
        var value: UInt = 0
        if flags.contains(.command) { value |= ModifierFlags.command.rawValue }
        if flags.contains(.option) { value |= ModifierFlags.option.rawValue }
        if flags.contains(.control) { value |= ModifierFlags.control.rawValue }
        if flags.contains(.shift) { value |= ModifierFlags.shift.rawValue }
        self.init(rawValue: value)
    }
}

private enum KeyPressEventFormatter {
    static func characters(for keyCode: UInt16, cgEvent event: CGEvent) -> String? {
        if let nsEvent = NSEvent(cgEvent: event) {
            return characters(for: keyCode, nsEvent: nsEvent)
        }
        return fallbackCharacters[keyCode]
    }

    static func characters(for keyCode: UInt16, nsEvent event: NSEvent) -> String? {
        switch keyCode {
        case KeyCode.space: return "Space"
        case KeyCode.returnKey: return "Return"
        case KeyCode.tab: return "Tab"
        case KeyCode.escape: return "Esc"
        case KeyCode.delete: return "Delete"
        case KeyCode.forwardDelete: return "Del"
        case KeyCode.leftArrow: return "Left"
        case KeyCode.rightArrow: return "Right"
        case KeyCode.upArrow: return "Up"
        case KeyCode.downArrow: return "Down"
        default:
            break
        }

        if let chars = event.charactersIgnoringModifiers,
           !chars.isEmpty {
            return chars.uppercased()
        }

        return fallbackCharacters[keyCode]
    }

    private static let fallbackCharacters: [UInt16: String] = [
        KeyCode.a: "A",
        KeyCode.b: "B",
        KeyCode.c: "C",
        KeyCode.d: "D",
        KeyCode.e: "E",
        KeyCode.f: "F",
        KeyCode.g: "G",
        KeyCode.h: "H",
        KeyCode.i: "I",
        KeyCode.j: "J",
        KeyCode.k: "K",
        KeyCode.l: "L",
        KeyCode.m: "M",
        KeyCode.n: "N",
        KeyCode.o: "O",
        KeyCode.p: "P",
        KeyCode.q: "Q",
        KeyCode.r: "R",
        KeyCode.s: "S",
        KeyCode.t: "T",
        KeyCode.u: "U",
        KeyCode.v: "V",
        KeyCode.w: "W",
        KeyCode.x: "X",
        KeyCode.y: "Y",
        KeyCode.z: "Z",
        KeyCode.zero: "0",
        KeyCode.one: "1",
        KeyCode.two: "2",
        KeyCode.three: "3",
        KeyCode.four: "4",
        KeyCode.five: "5",
        KeyCode.six: "6",
        KeyCode.seven: "7",
        KeyCode.eight: "8",
        KeyCode.nine: "9",
        KeyCode.minus: "-",
        KeyCode.equal: "=",
        KeyCode.leftBracket: "[",
        KeyCode.rightBracket: "]",
        KeyCode.backslash: "\\",
        KeyCode.semicolon: ";",
        KeyCode.quote: "'",
        KeyCode.comma: ",",
        KeyCode.period: ".",
        KeyCode.slash: "/",
        KeyCode.grave: "`"
    ]
}

private enum KeyCode {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let f: UInt16 = 3
    static let h: UInt16 = 4
    static let g: UInt16 = 5
    static let z: UInt16 = 6
    static let x: UInt16 = 7
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let b: UInt16 = 11
    static let q: UInt16 = 12
    static let w: UInt16 = 13
    static let e: UInt16 = 14
    static let r: UInt16 = 15
    static let y: UInt16 = 16
    static let t: UInt16 = 17
    static let one: UInt16 = 18
    static let two: UInt16 = 19
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let six: UInt16 = 22
    static let five: UInt16 = 23
    static let equal: UInt16 = 24
    static let nine: UInt16 = 25
    static let seven: UInt16 = 26
    static let minus: UInt16 = 27
    static let eight: UInt16 = 28
    static let zero: UInt16 = 29
    static let rightBracket: UInt16 = 30
    static let o: UInt16 = 31
    static let u: UInt16 = 32
    static let leftBracket: UInt16 = 33
    static let i: UInt16 = 34
    static let p: UInt16 = 35
    static let returnKey: UInt16 = 36
    static let l: UInt16 = 37
    static let j: UInt16 = 38
    static let quote: UInt16 = 39
    static let k: UInt16 = 40
    static let semicolon: UInt16 = 41
    static let backslash: UInt16 = 42
    static let comma: UInt16 = 43
    static let slash: UInt16 = 44
    static let n: UInt16 = 45
    static let m: UInt16 = 46
    static let period: UInt16 = 47
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let grave: UInt16 = 50
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let forwardDelete: UInt16 = 117
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}
