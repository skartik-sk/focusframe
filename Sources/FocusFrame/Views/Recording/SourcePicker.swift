import SwiftUI
import ScreenCaptureKit
import AVFoundation
import AppKit
import CoreGraphics

struct SourcePicker: View {
    @ObservedObject var recordingVM: RecordingVM
    @Environment(\.dismiss) var dismiss
    @State private var hasPermission = false
    @State private var isStarting = false
    @State private var startError: String?
    @State private var displayPreviewRefreshID = UUID()
    @State private var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var inputMonitoringAuthorized = KeyboardCapturePermissions.inputMonitoringAuthorized
    @State private var accessibilityAuthorized = KeyboardCapturePermissions.accessibilityAuthorized
    @StateObject private var microphoneLevelMonitor = MicrophoneLevelMonitor()

    var body: some View {
        VStack(spacing: 0) {
            header
                .layoutPriority(1)

            Divider()

            Group {
                if !hasPermission {
                    permissionView
                } else {
                    recordingSetupView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(0)

            Divider()

            footer
                .layoutPriority(2)
        }
        .frame(width: 960)
        .frame(maxHeight: sheetMaxHeight)
        .task {
            refreshDeviceAuthorization()
            recordingVM.refreshMediaDevices()
            checkPermission()
            refreshInputMonitoringAuthorization()
        }
        .onDisappear {
            microphoneLevelMonitor.stop()
        }
        .onChange(of: recordingVM.selectedMicrophoneID) { _ in
            updateMicrophoneMonitor()
        }
        .onChange(of: recordingVM.capturesMic) { _ in
            updateMicrophoneMonitor()
        }
        .onChange(of: microphoneAuthorization) { _ in
            updateMicrophoneMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAllPermissionState()
        }
    }

    private var sheetMaxHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? .infinity
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Recording")
                    .font(.headline)
                Text("Choose the screen, preview the camera, and confirm audio before recording.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var recordingSetupView: some View {
        HStack(spacing: 0) {
            sourceColumn

            Divider()

            previewColumn

            Divider()

            layersColumn
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    checkPermission()
                    displayPreviewRefreshID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh displays")
            }

            if recordingVM.displays.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading displays")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(recordingVM.displays, id: \.displayID) { display in
                            displayRow(display)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 236)
        .frame(minHeight: 0)
    }

    private var previewColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                displayPreviewSection
                cameraPreviewSection
                readinessPanel
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 374)
        .frame(minHeight: 0)
    }

    private var displayPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Screen Preview", systemImage: "display")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    displayPreviewRefreshID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh screen preview")
            }

            if let display = recordingVM.selectedDisplay {
                DisplaySnapshotView(display: display, refreshID: displayPreviewRefreshID)
                    .frame(height: 154)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                HStack {
                    Label("Display \(display.displayID)", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                    Spacer()
                    Text("\(display.width)x\(display.height)")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            } else {
                placeholderPreview(
                    icon: "display.trianglebadge.exclamationmark",
                    title: "No display selected",
                    detail: "Select a display from the source list."
                )
                .frame(height: 154)
            }
        }
    }

    private var cameraPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Camera Preview", systemImage: "camera")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(cameraStatusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(cameraStatusColor)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if recordingVM.capturesWebcam && cameraAuthorization == .authorized {
                    CameraPreviewView(isEnabled: true, deviceID: recordingVM.selectedCameraID)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    placeholderPreview(
                        icon: cameraPlaceholderIcon,
                        title: cameraPlaceholderTitle,
                        detail: cameraPlaceholderDetail
                    )
                    .padding(14)
                }
            }
            .frame(height: 126)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if recordingVM.capturesWebcam && cameraAuthorization != .authorized {
                Button(cameraPermissionButtonTitle) {
                    handleCameraPermissionButton()
                }
                .font(.caption)
            }
        }
    }

    private var readinessPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ready Check", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))

            readinessRow("Screen", selectedDisplayStatus, systemImage: "display")
            readinessRow("System Audio", recordingVM.capturesSystemAudio ? "On, embedded in screen movie" : "Off", systemImage: "speaker.wave.2")
            readinessRow("Microphone", microphoneStatusText, systemImage: "mic")
            readinessRow("Input Monitoring", keyboardCaptureStatusText, systemImage: "keyboard")
            readinessRow("Camera", cameraStatusText, systemImage: "camera")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var layersColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Layers")
                    .font(.subheadline.weight(.semibold))

                microphoneControl

                captureToggle("System Audio", detail: "Capture app and browser sound into the screen movie.", icon: "speaker.wave.2", isOn: $recordingVM.capturesSystemAudio)

                keyboardCaptureControl

                cameraControl

                captureToggle("Auto Subtitles", detail: "Generate local caption files from recorded audio.", icon: "captions.bubble", isOn: $recordingVM.generatesSubtitles)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Speaker Notes", systemImage: "text.alignleft")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $recordingVM.speakerNotes)
                        .font(.system(size: 13))
                        .frame(height: 92)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Shown in the recording controls and saved with the project.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let message = startError ?? recordingVM.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.top, 4)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 348)
        .frame(minHeight: 0)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            Spacer()
            Button {
                startRecording()
            } label: {
                if isStarting {
                    ProgressView()
                } else {
                    Label("Start Recording", systemImage: "record.circle")
                }
            }
            .disabled(recordingVM.selectedDisplay == nil || isStarting)
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            VStack(spacing: 4) {
                Text("Screen Recording Permission Required")
                    .font(.headline)
                Text("Enable \(AppBrand.name) in System Settings > Privacy & Security > Screen & System Audio Recording. Then quit and reopen the app if macOS asks for it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if let startError {
                    Text(startError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .padding(.top, 6)
                }
            }
            HStack {
                Button("Open Settings") {
                    openScreenRecordingSettings()
                }
                Button("Check Again") {
                    checkPermission()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var selectedDisplayStatus: String {
        guard let display = recordingVM.selectedDisplay else {
            return "Select a display"
        }
        return "Display \(display.displayID), \(display.width)x\(display.height)"
    }

    private var microphoneStatusText: String {
        guard recordingVM.capturesMic else {
            return "Off"
        }
        switch microphoneAuthorization {
        case .authorized:
            return recordingVM.selectedMicrophoneName
        case .notDetermined:
            return "Will ask: \(recordingVM.selectedMicrophoneName)"
        case .denied, .restricted:
            return "Permission needed"
        @unknown default:
            return "Unknown"
        }
    }

    private var keyboardCaptureStatusText: String {
        if inputMonitoringAuthorized {
            return "Ready: Input Monitoring"
        }
        if accessibilityAuthorized {
            return "Needs Input Monitoring"
        }
        return "Permission needed"
    }

    private var keyboardCaptureAuthorized: Bool {
        inputMonitoringAuthorized
    }

    private var cameraStatusText: String {
        guard recordingVM.capturesWebcam else {
            return "Off"
        }
        switch cameraAuthorization {
        case .authorized:
            return recordingVM.selectedCameraName
        case .notDetermined:
            return "Will ask: \(recordingVM.selectedCameraName)"
        case .denied, .restricted:
            return "Permission needed"
        @unknown default:
            return "Unknown"
        }
    }

    private var cameraStatusLabel: String {
        guard recordingVM.capturesWebcam else {
            return "Off"
        }
        return cameraAuthorization == .authorized ? "Live" : "Needs Permission"
    }

    private var cameraStatusColor: Color {
        if !recordingVM.capturesWebcam {
            return .secondary
        }
        return cameraAuthorization == .authorized ? .green : .orange
    }

    private var cameraPlaceholderIcon: String {
        if !recordingVM.capturesWebcam {
            return "camera.slash"
        }
        return "lock.shield"
    }

    private var cameraPlaceholderTitle: String {
        if !recordingVM.capturesWebcam {
            return "Camera off"
        }
        return "Camera permission needed"
    }

    private var cameraPermissionButtonTitle: String {
        switch cameraAuthorization {
        case .notDetermined:
            return "Request Camera Access"
        default:
            return "Open Camera Settings"
        }
    }

    private var cameraPlaceholderDetail: String {
        if !recordingVM.capturesWebcam {
            return "Turn on Webcam to see a live camera preview before recording."
        }
        return "Allow camera access to preview and record \(recordingVM.selectedCameraName)."
    }

    private func displayRow(_ display: SCDisplay) -> some View {
        Button {
            recordingVM.selectedDisplay = display
            displayPreviewRefreshID = UUID()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "display")
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Display \(display.displayID)")
                    Text("\(display.width)x\(display.height)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if recordingVM.selectedDisplay?.displayID == display.displayID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var microphoneControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            captureToggle("Microphone", detail: "Record narration as a separate editable track with export noise cleanup.", icon: "mic", isOn: $recordingVM.capturesMic)
                .onChange(of: recordingVM.capturesMic) { enabled in
                    if enabled {
                        requestMicrophonePermission()
                    } else {
                        refreshDeviceAuthorization()
                    }
                }

            if recordingVM.capturesMic {
                devicePicker(
                    title: "Input",
                    selection: $recordingVM.selectedMicrophoneID,
                    options: recordingVM.microphoneDevices
                )

                if microphoneAuthorization == .authorized {
                    MicrophoneLevelMeter(level: microphoneLevelMonitor.level)
                } else {
                    Text(microphoneStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var keyboardCaptureControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input Monitoring")
                    Text("Capture global clicks for auto zoom and key presses for preview/export badges.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(keyboardCaptureAuthorized ? "Ready" : "Needs Access")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(keyboardCaptureAuthorized ? .accentColor : .orange)
            }

            if !keyboardCaptureAuthorized {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Request Input Monitoring") {
                        requestKeyboardCapturePermissionIfNeeded()
                    }
                    .buttonStyle(.bordered)

                    HStack(spacing: 8) {
                        Button("Open Input Monitoring") {
                            openInputMonitoringSettings()
                        }
                        .buttonStyle(.borderless)

                        Button("Request Accessibility") {
                            requestAccessibilityPermissionIfNeeded()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text(accessibilityAuthorized ? "Accessibility is enabled, but Input Monitoring is still required for reliable click tracking and key badges." : "Input Monitoring records global clicks for auto zoom plus shortcuts for editor badges and export. Accessibility is only a secondary fallback for limited in-app key events.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cameraControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            captureToggle("Webcam", detail: "Record camera as a separate layer that can be moved in the editor.", icon: "camera", isOn: $recordingVM.capturesWebcam)
                .onChange(of: recordingVM.capturesWebcam) { enabled in
                    if enabled {
                        requestCameraPermission()
                    } else {
                        refreshDeviceAuthorization()
                    }
                }

            if recordingVM.capturesWebcam {
                devicePicker(
                    title: "Camera",
                    selection: $recordingVM.selectedCameraID,
                    options: recordingVM.cameraDevices
                )
            }
        }
    }

    private func devicePicker(
        title: String,
        selection: Binding<String>,
        options: [MediaDeviceOption]
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .leading)

            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func captureToggle(
        _ title: String,
        detail: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
    }

    private func placeholderPreview(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readinessRow(_ title: String, _ detail: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }

    private func startRecording() {
        isStarting = true
        startError = nil
        Task { @MainActor in
            await prepareSelectedDevicesForStart()
            do {
                try await recordingVM.startRecording()
                dismiss()
            } catch {
                startError = error.localizedDescription
            }
            refreshDeviceAuthorization()
            isStarting = false
        }
    }

    private func prepareSelectedDevicesForStart() async {
        refreshDeviceAuthorization()

        if recordingVM.capturesMic {
            await prepareMicrophoneForStart()
        }

        if recordingVM.capturesWebcam {
            await prepareCameraForStart()
        }

        requestKeyboardCapturePermissionIfNeeded(openSettingsOnFailure: false)
        recordingVM.refreshMediaDevices()
        updateMicrophoneMonitor()
    }

    private func prepareMicrophoneForStart() async {
        guard PrivacyPermissions.hasUsageDescription(.microphone) else {
            recordingVM.capturesMic = false
            startError = PrivacyPermissions.missingUsageMessage(for: .microphone)
            return
        }

        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphoneAuthorization {
        case .authorized:
            return
        case .notDetermined:
            let granted = await requestAVAccess(for: .audio)
            microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            if !granted {
                recordingVM.capturesMic = false
                startError = "Microphone permission is disabled. Recording will continue without microphone audio."
            }
        case .denied, .restricted:
            recordingVM.capturesMic = false
            startError = "Microphone permission is disabled. Recording will continue without microphone audio."
        @unknown default:
            recordingVM.capturesMic = false
            startError = "Microphone permission status is unknown. Recording will continue without microphone audio."
        }
    }

    private func prepareCameraForStart() async {
        guard PrivacyPermissions.hasUsageDescription(.camera) else {
            recordingVM.capturesWebcam = false
            startError = PrivacyPermissions.missingUsageMessage(for: .camera)
            return
        }

        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraAuthorization {
        case .authorized:
            return
        case .notDetermined:
            let granted = await requestAVAccess(for: .video)
            cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
            if !granted {
                recordingVM.capturesWebcam = false
                startError = "Camera permission is disabled. Recording will continue without webcam."
            }
        case .denied, .restricted:
            recordingVM.capturesWebcam = false
            startError = "Camera permission is disabled. Recording will continue without webcam."
        @unknown default:
            recordingVM.capturesWebcam = false
            startError = "Camera permission status is unknown. Recording will continue without webcam."
        }
    }

    private func requestAVAccess(for mediaType: AVMediaType) async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestMicrophonePermission() {
        guard PrivacyPermissions.hasUsageDescription(.microphone) else {
            recordingVM.capturesMic = false
            startError = PrivacyPermissions.missingUsageMessage(for: .microphone)
            return
        }

        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphoneAuthorization {
        case .authorized:
            updateMicrophoneMonitor()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
                    recordingVM.refreshMediaDevices()
                    if !granted {
                        recordingVM.capturesMic = false
                        startError = "Microphone permission is disabled. Enable it in System Settings to record narration."
                    }
                    updateMicrophoneMonitor()
                }
            }
        default:
            recordingVM.capturesMic = false
            startError = "Microphone permission is disabled. Enable it in System Settings to record narration."
            updateMicrophoneMonitor()
        }
    }

    private func refreshInputMonitoringAuthorization() {
        inputMonitoringAuthorized = KeyboardCapturePermissions.inputMonitoringAuthorized
        accessibilityAuthorized = KeyboardCapturePermissions.accessibilityAuthorized
    }

    private func refreshAllPermissionState() {
        checkPermission()
        refreshDeviceAuthorization()
        refreshInputMonitoringAuthorization()
    }

    private func requestKeyboardCapturePermissionIfNeeded(openSettingsOnFailure: Bool = true) {
        guard PrivacyPermissions.hasUsageDescription(.inputMonitoring) else {
            inputMonitoringAuthorized = false
            startError = PrivacyPermissions.missingUsageMessage(for: .inputMonitoring)
            return
        }

        if keyboardCaptureAuthorized {
            return
        }

        let granted = KeyboardCapturePermissions.requestInputMonitoring()
        refreshInputMonitoringAuthorization()

        if !granted {
            startError = "Input Monitoring is still disabled. Enable \(AppBrand.name) in Input Monitoring for click-driven auto zoom and reliable keyboard badges."
            guard openSettingsOnFailure else { return }
            openInputMonitoringSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                refreshInputMonitoringAuthorization()
            }
        }
    }

    private func requestAccessibilityPermissionIfNeeded(openSettingsOnFailure: Bool = true) {
        guard PrivacyPermissions.hasUsageDescription(.accessibility) else {
            accessibilityAuthorized = false
            startError = PrivacyPermissions.missingUsageMessage(for: .accessibility)
            return
        }

        if accessibilityAuthorized {
            return
        }

        let granted = KeyboardCapturePermissions.requestAccessibility()
        refreshInputMonitoringAuthorization()

        if !granted {
            startError = "Accessibility is still disabled. Enable \(AppBrand.name) in Accessibility only as the fallback when Input Monitoring is unavailable."
            guard openSettingsOnFailure else { return }
            openAccessibilitySettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                refreshInputMonitoringAuthorization()
            }
        }
    }

    private func requestCameraPermission() {
        guard PrivacyPermissions.hasUsageDescription(.camera) else {
            recordingVM.capturesWebcam = false
            startError = PrivacyPermissions.missingUsageMessage(for: .camera)
            return
        }

        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraAuthorization {
        case .authorized:
            recordingVM.refreshMediaDevices()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
                    recordingVM.refreshMediaDevices()
                    if !granted {
                        recordingVM.capturesWebcam = false
                        startError = "Camera permission is disabled. Enable it in System Settings to preview and record webcam."
                    }
                }
            }
        default:
            recordingVM.capturesWebcam = false
            startError = "Camera permission is disabled. Enable it in System Settings to preview and record webcam."
        }
    }

    private func handleCameraPermissionButton() {
        switch cameraAuthorization {
        case .notDetermined:
            requestCameraPermission()
        default:
            openPrivacySettings("Privacy_Camera")
        }
    }

    private func openInputMonitoringSettings() {
        KeyboardCapturePermissions.openInputMonitoringSettings()
    }

    private func openAccessibilitySettings() {
        KeyboardCapturePermissions.openAccessibilitySettings()
    }

    private func refreshDeviceAuthorization() {
        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        recordingVM.refreshMediaDevices()
        updateMicrophoneMonitor()
    }

    private func updateMicrophoneMonitor() {
        if recordingVM.capturesMic && microphoneAuthorization == .authorized {
            microphoneLevelMonitor.start(deviceID: recordingVM.selectedMicrophoneID)
        } else {
            microphoneLevelMonitor.stop()
        }
    }

    private func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording"
        ]

        for urlString in urls {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkPermission() {
        startError = nil

        guard PrivacyPermissions.hasUsageDescription(.screenCapture) else {
            hasPermission = false
            startError = PrivacyPermissions.missingUsageMessage(for: .screenCapture)
            return
        }

        Task { @MainActor in
            do {
                try await refreshDisplaysFromScreenCaptureKit()
            } catch {
                hasPermission = false

                let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
                guard granted else {
                    startError = "Screen Recording is still disabled for \(AppBrand.name). Enable it in System Settings, then quit and reopen the app if prompted."
                    return
                }

                do {
                    try await refreshDisplaysFromScreenCaptureKit()
                } catch {
                    startError = "Screen Recording is enabled, but ScreenCaptureKit could not list displays: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func refreshDisplaysFromScreenCaptureKit() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        recordingVM.displays = content.displays
        let selectedID = recordingVM.selectedDisplay?.displayID
        if selectedID == nil || !recordingVM.displays.contains(where: { $0.displayID == selectedID }) {
            recordingVM.selectedDisplay = recordingVM.displays.first
        }
        recordingVM.lastErrorMessage = recordingVM.displays.isEmpty ? "No displays are available to record." : nil
        hasPermission = true
        displayPreviewRefreshID = UUID()
    }
}
