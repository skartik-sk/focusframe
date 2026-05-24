import Foundation

enum EffectOverride: String, Codable, CaseIterable, Identifiable {
    case inherit
    case on
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inherit:
            return "Inherit"
        case .on:
            return "On"
        case .off:
            return "Off"
        }
    }

    func resolved(base: Bool) -> Bool {
        switch self {
        case .inherit:
            return base
        case .on:
            return true
        case .off:
            return false
        }
    }
}

struct EffectSegment: Codable, Identifiable, Equatable {
    let id: UUID
    var startTime: Double
    var endTime: Double
    var name: String
    var music: EffectOverride
    var clickSound: EffectOverride
    var keyboardSound: EffectOverride
    var keyboardBadges: EffectOverride
    var cursor: EffectOverride
    var subtitles: EffectOverride
    var overlays: EffectOverride
    var webcam: EffectOverride
    var watermark: EffectOverride
    var sourceAudioVolume: Float?
    var micAudioVolume: Float?
    var musicVolume: Float?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        name: String = "Effect Segment",
        music: EffectOverride = .inherit,
        clickSound: EffectOverride = .inherit,
        keyboardSound: EffectOverride = .inherit,
        keyboardBadges: EffectOverride = .inherit,
        cursor: EffectOverride = .inherit,
        subtitles: EffectOverride = .inherit,
        overlays: EffectOverride = .inherit,
        webcam: EffectOverride = .inherit,
        watermark: EffectOverride = .inherit,
        sourceAudioVolume: Float? = nil,
        micAudioVolume: Float? = nil,
        musicVolume: Float? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.name = name
        self.music = music
        self.clickSound = clickSound
        self.keyboardSound = keyboardSound
        self.keyboardBadges = keyboardBadges
        self.cursor = cursor
        self.subtitles = subtitles
        self.overlays = overlays
        self.webcam = webcam
        self.watermark = watermark
        self.sourceAudioVolume = sourceAudioVolume
        self.micAudioVolume = micAudioVolume
        self.musicVolume = musicVolume
        self.createdAt = createdAt
    }

    var duration: Double {
        max(0, endTime - startTime)
    }

    func intersects(time: Double) -> Bool {
        time >= startTime && time <= endTime
    }

    func overlaps(startTime otherStart: Double, endTime otherEnd: Double) -> Bool {
        !(endTime <= otherStart || startTime >= otherEnd)
    }
}

enum EffectSegmentPreset: String, CaseIterable, Identifiable {
    case quiet
    case focus
    case voiceOnly
    case screenOnly
    case inherit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quiet:
            return "Quiet Section"
        case .focus:
            return "Focus Section"
        case .voiceOnly:
            return "Voice Only"
        case .screenOnly:
            return "Screen Only"
        case .inherit:
            return "Custom Segment"
        }
    }

    var subtitle: String {
        switch self {
        case .quiet:
            return "No music, no click sounds, no key sounds."
        case .focus:
            return "Hide keyboard badges and cursor distractions."
        case .voiceOnly:
            return "Keep mic, mute music and screen audio."
        case .screenOnly:
            return "Keep screen audio, mute mic and camera."
        case .inherit:
            return "Start with inherited project settings."
        }
    }

    func apply(to segment: inout EffectSegment) {
        switch self {
        case .quiet:
            segment.music = .off
            segment.clickSound = .off
            segment.keyboardSound = .off
            segment.name = title
        case .focus:
            segment.keyboardBadges = .off
            segment.cursor = .off
            segment.clickSound = .off
            segment.keyboardSound = .off
            segment.name = title
        case .voiceOnly:
            segment.music = .off
            segment.clickSound = .off
            segment.keyboardSound = .off
            segment.sourceAudioVolume = 0
            segment.micAudioVolume = 1
            segment.name = title
        case .screenOnly:
            segment.music = .off
            segment.clickSound = .off
            segment.keyboardSound = .off
            segment.micAudioVolume = 0
            segment.webcam = .off
            segment.name = title
        case .inherit:
            segment.name = title
        }
    }
}

struct ResolvedEffectSettings {
    var style: StylePreset
    var showKeyboardShortcuts: Bool
    var cursorVisibility: EffectOverride
    var subtitlesEnabled: Bool
    var overlaysEnabled: Bool
    var webcamEnabled: Bool
}

enum EffectSegmentResolver {
    static func activeSegments(in project: RecordingProject, at time: Double) -> [EffectSegment] {
        (project.effectSegments ?? [])
            .filter { $0.intersects(time: time) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func resolve(project: RecordingProject, at time: Double) -> ResolvedEffectSettings {
        var style = project.style
        var showKeyboardShortcuts = project.showKeyboardShortcuts || style.showKeyboardShortcuts
        var cursorVisibility = EffectOverride.inherit
        var subtitlesEnabled = project.subtitlesEnabled == true || project.captionsFileURL != nil
        var overlaysEnabled = true
        var webcamEnabled = project.webcamEnabled

        for segment in activeSegments(in: project, at: time) {
            if segment.music != .inherit {
                style.backgroundMusicVolume = segment.music.resolved(base: style.backgroundMusicVolume > 0) ? max(style.backgroundMusicVolume, 0.001) : 0
            }
            if let musicVolume = segment.musicVolume {
                style.backgroundMusicVolume = clampedVolume(musicVolume)
            }
            if let sourceAudioVolume = segment.sourceAudioVolume {
                style.sourceAudioVolume = clampedVolume(sourceAudioVolume)
            }
            if let micAudioVolume = segment.micAudioVolume {
                style.micAudioVolume = clampedVolume(micAudioVolume)
            }
            if segment.clickSound != .inherit {
                style.clickSoundEnabled = segment.clickSound.resolved(base: style.clickSoundEnabled)
            }
            if segment.keyboardSound != .inherit {
                style.keyboardSoundEnabled = segment.keyboardSound.resolved(base: style.keyboardSoundEnabled)
            }
            if segment.keyboardBadges != .inherit {
                showKeyboardShortcuts = segment.keyboardBadges.resolved(base: showKeyboardShortcuts)
                style.showKeyboardShortcuts = showKeyboardShortcuts
            }
            if segment.cursor != .inherit {
                cursorVisibility = segment.cursor
            }
            if segment.subtitles != .inherit {
                subtitlesEnabled = segment.subtitles.resolved(base: subtitlesEnabled)
            }
            if segment.overlays != .inherit {
                overlaysEnabled = segment.overlays.resolved(base: overlaysEnabled)
            }
            if segment.webcam != .inherit {
                webcamEnabled = segment.webcam.resolved(base: webcamEnabled)
            }
            if segment.watermark != .inherit {
                style.watermarkEnabled = segment.watermark.resolved(base: style.watermarkEnabled)
            }
        }

        return ResolvedEffectSettings(
            style: style,
            showKeyboardShortcuts: showKeyboardShortcuts,
            cursorVisibility: cursorVisibility,
            subtitlesEnabled: subtitlesEnabled,
            overlaysEnabled: overlaysEnabled,
            webcamEnabled: webcamEnabled
        )
    }

    private static func clampedVolume(_ value: Float) -> Float {
        max(0, min(value, 1))
    }
}
