import Foundation
import Cocoa

class CursorTracker {
    static let pollingSampleRate: Double = 60.0
    private static let minimumMovementFrameInterval: Double = 1.0 / 120.0

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollingTimer: DispatchSourceTimer?
    private var appKitMonitors: [Any] = []
    private var frames: [CursorFrame] = []
    private var startTime: CFTimeInterval = 0
    private var outputURL: URL?
    private var captureRect: CGRect = .zero
    private var displayBounds: CGRect = .zero
    private var streamToPointScale = CGSize(width: 1, height: 1)
    private var screenSize: CGSize = CGSize(width: 1920, height: 1080)
    private var isPaused = false
    private var pauseStartedAt: CFTimeInterval?
    private var accumulatedPauseDuration: CFTimeInterval = 0
    private let lock = NSLock()
    private let pollingQueue = DispatchQueue(label: "com.screenrecorder.cursor-polling")
    
    func start(outputURL: URL, captureRect: CGRect, displayBounds: CGRect) {
        self.outputURL = outputURL
        self.displayBounds = displayBounds
        let pointWidth = max(displayBounds.width, 1)
        let pointHeight = max(displayBounds.height, 1)
        streamToPointScale = CGSize(
            width: max(captureRect.width, 1) / pointWidth,
            height: max(captureRect.height, 1) / pointHeight
        )
        self.captureRect = CGRect(
            x: captureRect.origin.x / streamToPointScale.width,
            y: captureRect.origin.y / streamToPointScale.height,
            width: captureRect.width / streamToPointScale.width,
            height: captureRect.height / streamToPointScale.height
        )
        self.screenSize = self.captureRect.size
        startTime = CACurrentMediaTime()
        isPaused = false
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        frames.removeAll()
        recordCurrentPosition(timestamp: 0, force: true)
        startPollingPositions()
        startAppKitFallbackMonitors()

        if !KeyboardCapturePermissions.isCaptureAuthorized {
            _ = KeyboardCapturePermissions.requestInputMonitoring()
        }
        
        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
            
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let tracker = Unmanaged<CursorTracker>.fromOpaque(userInfo).takeUnretainedValue()
                tracker.recordEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        
        self.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let rls = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    func stop() -> URL {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let rls = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), rls, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        pollingTimer?.cancel()
        pollingTimer = nil
        for monitor in appKitMonitors {
            NSEvent.removeMonitor(monitor)
        }
        appKitMonitors.removeAll()

        recordCurrentPosition(timestamp: currentTimelineTimestamp(), force: true)
        
        let fileURL = outputURL ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-cursor.json")
        
        let recording = CursorRecording(
            frames: recordedFramesSnapshot(),
            sampleRate: Self.pollingSampleRate,
            screenSize: screenSize,
            cursorType: .arrow
        ).sanitizedForUse()
        
        if let data = try? JSONEncoder().encode(recording) {
            try? data.write(to: fileURL)
        }
        
        return fileURL
    }

    func pause() {
        lock.lock()
        if !isPaused {
            isPaused = true
            pauseStartedAt = CACurrentMediaTime()
        }
        lock.unlock()
    }

    func resume() {
        lock.lock()
        if isPaused, let pauseStartedAt {
            accumulatedPauseDuration += CACurrentMediaTime() - pauseStartedAt
            isPaused = false
            self.pauseStartedAt = nil
            let timestamp = CACurrentMediaTime() - startTime - accumulatedPauseDuration
            lock.unlock()
            recordCurrentPosition(timestamp: max(0, timestamp), force: true)
            return
        }
        isPaused = false
        pauseStartedAt = nil
        lock.unlock()
    }
    
    private func recordEvent(type: CGEventType, event: CGEvent) {
        lock.lock()
        let paused = isPaused
        let pauseDuration = accumulatedPauseDuration
        lock.unlock()
        guard !paused else { return }

        let timestamp = CACurrentMediaTime() - startTime - pauseDuration
        guard timestamp.isFinite, timestamp >= 0 else { return }
        let location = convertGlobalPosition(event.location)
        let clicking = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        
        let clickType: CursorFrame.ClickType? = {
            switch type {
            case .leftMouseDown: return .leftDown
            case .leftMouseUp: return .leftUp
            case .rightMouseDown: return .rightDown
            case .rightMouseUp: return .rightUp
            case .otherMouseDown, .otherMouseUp: return .other
            default: return nil
            }
        }()
        
        appendFrame(
            timestamp: timestamp,
            position: location,
            isClicking: clicking,
            clickType: clickType,
            scrollDelta: type == .scrollWheel ? CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) : nil
        )
    }

    private func recordCurrentPosition(timestamp: Double, force: Bool = false) {
        guard let event = CGEvent(source: nil) else { return }
        let position = convertGlobalPosition(event.location)

        if !force {
            lock.lock()
            let lastPosition = frames.last?.position
            lock.unlock()
            if let lastPosition,
               hypot(lastPosition.x - position.x, lastPosition.y - position.y) < 0.5 {
                return
            }
        }

        appendFrame(
            timestamp: timestamp,
            position: position,
            isClicking: false,
            clickType: nil,
            scrollDelta: nil
        )
    }

    private func appendFrame(
        timestamp: Double,
        position: CGPoint,
        isClicking: Bool,
        clickType: CursorFrame.ClickType?,
        scrollDelta: CGFloat?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard timestamp.isFinite, timestamp >= 0 else { return }
        let frame = CursorFrame(
            timestamp: timestamp,
            position: position,
            isClicking: isClicking,
            clickType: clickType,
            scrollDelta: scrollDelta
        )
        if let clickType,
           let last = frames.last,
           last.clickType == clickType,
           abs(last.timestamp - timestamp) < 0.06,
           hypot(last.position.x - position.x, last.position.y - position.y) < 4 {
            return
        }
        if let last = frames.last,
           CursorRecording.shouldDropDuplicateMovement(
            previous: last,
            next: frame,
            minInterval: Self.minimumMovementFrameInterval
           ) {
            return
        }
        frames.append(frame)
    }

    private func startPollingPositions() {
        pollingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        timer.schedule(deadline: .now() + 0.02, repeating: 1.0 / Self.pollingSampleRate)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let paused = self.isPaused
            let pauseDuration = self.accumulatedPauseDuration
            self.lock.unlock()
            guard !paused else { return }
            let timestamp = CACurrentMediaTime() - self.startTime - pauseDuration
            self.recordCurrentPosition(timestamp: max(0, timestamp))
        }
        pollingTimer = timer
        timer.resume()
    }

    private func startAppKitFallbackMonitors() {
        guard appKitMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel
        ]

        let record: (NSEvent) -> Void = { [weak self] event in
            self?.recordFallback(event: event)
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: record) {
            appKitMonitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            record(event)
            return event
        }) {
            appKitMonitors.append(localMonitor)
        }
    }

    private func recordFallback(event: NSEvent) {
        lock.lock()
        let paused = isPaused
        let pauseDuration = accumulatedPauseDuration
        lock.unlock()
        guard !paused else { return }

        guard let cgEvent = CGEvent(source: nil) else { return }
        let timestamp = CACurrentMediaTime() - startTime - pauseDuration
        let clickType: CursorFrame.ClickType? = {
            switch event.type {
            case .leftMouseDown: return .leftDown
            case .leftMouseUp: return .leftUp
            case .rightMouseDown: return .rightDown
            case .rightMouseUp: return .rightUp
            case .otherMouseDown, .otherMouseUp: return .other
            default: return nil
            }
        }()
        let isClicking = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
        appendFrame(
            timestamp: max(0, timestamp),
            position: convertGlobalPosition(cgEvent.location),
            isClicking: isClicking,
            clickType: clickType,
            scrollDelta: event.type == .scrollWheel ? event.scrollingDeltaY : nil
        )
    }

    private func convertGlobalPosition(_ position: CGPoint) -> CGPoint {
        let displayLocal = CGPoint(
            x: position.x - displayBounds.origin.x,
            y: position.y - displayBounds.origin.y
        )

        let captureLocal = CGPoint(
            x: displayLocal.x - captureRect.origin.x,
            y: displayLocal.y - captureRect.origin.y
        )

        return CGPoint(
            x: min(max(captureLocal.x, 0), max(screenSize.width, 0)),
            y: min(max(captureLocal.y, 0), max(screenSize.height, 0))
        )
    }

    private func currentTimelineTimestamp() -> Double {
        let now = CACurrentMediaTime()
        lock.lock()
        let activePauseDuration = isPaused ? now - (pauseStartedAt ?? now) : 0
        let pauseDuration = accumulatedPauseDuration + activePauseDuration
        lock.unlock()
        return max(0, now - startTime - pauseDuration)
    }

    private func recordedFramesSnapshot() -> [CursorFrame] {
        lock.lock()
        let snapshot = frames
        lock.unlock()
        return snapshot
    }
}
