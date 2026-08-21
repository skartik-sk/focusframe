import AVFoundation
import CoreAudio

struct MediaDeviceOption: Identifiable, Equatable {
    static let defaultID = "default"

    let id: String
    let name: String
    let isDefault: Bool
}

enum MediaDeviceCatalog {
    static func microphoneOptions() -> [MediaDeviceOption] {
        options(
            defaultName: defaultDeviceName(for: .audio, fallback: "Default Microphone"),
            defaultDeviceID: AVCaptureDevice.default(for: .audio)?.uniqueID,
            devices: devices(for: .audio)
        )
    }

    static func cameraOptions() -> [MediaDeviceOption] {
        options(
            defaultName: defaultDeviceName(for: .video, fallback: "Default Camera"),
            defaultDeviceID: AVCaptureDevice.default(for: .video)?.uniqueID,
            devices: devices(for: .video)
        )
    }

    static func device(for optionID: String?, mediaType: AVMediaType) -> AVCaptureDevice? {
        guard let optionID, optionID != MediaDeviceOption.defaultID else {
            return AVCaptureDevice.default(for: mediaType)
        }
        return AVCaptureDevice(uniqueID: optionID) ?? AVCaptureDevice.default(for: mediaType)
    }

    private static func options(
        defaultName: String,
        defaultDeviceID: String?,
        devices: [AVCaptureDevice]
    ) -> [MediaDeviceOption] {
        let uniqueDevices = deduplicated(devices)
        var options = [
            MediaDeviceOption(
                id: MediaDeviceOption.defaultID,
                name: defaultName,
                isDefault: true
            )
        ]

        options.append(contentsOf: uniqueDevices.map { device in
            let suffix = device.uniqueID == defaultDeviceID ? " (Default)" : ""
            return MediaDeviceOption(
                id: device.uniqueID,
                name: "\(device.localizedName)\(suffix)",
                isDefault: false
            )
        })

        return options
    }

    private static func defaultDeviceName(for mediaType: AVMediaType, fallback: String) -> String {
        AVCaptureDevice.default(for: mediaType).map { "Default - \($0.localizedName)" } ?? fallback
    }

    private static func devices(for mediaType: AVMediaType) -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType]
        switch mediaType {
        case .audio:
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        case .video:
            deviceTypes = [.builtInWideAngleCamera, .externalUnknown]
        default:
            deviceTypes = [.externalUnknown]
        }

        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: mediaType,
            position: .unspecified
        )
        var found = discovery.devices

        if mediaType == .audio {
            // AVCaptureDevice discovery frequently omits Bluetooth microphones
            // (AirPods, BT headsets) until they become the active system input.
            // CoreAudio always lists them, and their CoreAudio UID matches
            // AVCaptureDevice.uniqueID — so merge both sources.
            for uid in coreAudioInputDeviceUIDs() where !found.contains(where: { $0.uniqueID == uid }) {
                if let device = AVCaptureDevice(uniqueID: uid) {
                    found.append(device)
                }
            }
        }

        return deduplicated(found).sorted { lhs, rhs in
            lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
    }

    /// Enumerates every CoreAudio device that has input streams and returns its UID.
    private static func coreAudioInputDeviceUIDs() -> [String] {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        var uids: [String] = []
        for deviceID in deviceIDs {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString?
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                  let resolved = uid as String? else { continue }
            uids.append(resolved)
        }
        return uids
    }

    private static func deduplicated(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        return devices.filter { device in
            seen.insert(device.uniqueID).inserted
        }
    }
}
