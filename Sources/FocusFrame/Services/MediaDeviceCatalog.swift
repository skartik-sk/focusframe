import AVFoundation

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
        return deduplicated(discovery.devices).sorted { lhs, rhs in
            lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
    }

    private static func deduplicated(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        return devices.filter { device in
            seen.insert(device.uniqueID).inserted
        }
    }
}
