import SwiftUI
import AppKit

@main
struct FocusFrameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            HomeView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private var fallbackMainWindow: NSWindow?
    private var isRecording = false
    private var isPaused = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        KeyboardShortcutManager.shared.startMonitoring()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingStatusDidChange(_:)),
            name: .recordingStatusChanged,
            object: nil
        )

        DispatchQueue.main.async {
            self.presentMainWindowIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.presentMainWindowIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyboardShortcutManager.shared.stopMonitoring()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentMainWindowIfNeeded()
        return true
    }

    @MainActor
    private func presentMainWindowIfNeeded() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        if let fallbackMainWindow {
            fallbackMainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppBrand.name
        window.center()
        window.setFrameAutosaveName("FocusFrameMainWindow")
        window.contentView = NSHostingView(rootView: HomeView())
        window.makeKeyAndOrderFront(nil)
        fallbackMainWindow = window
    }

    @MainActor
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "video.circle.fill", accessibilityDescription: AppBrand.name)
        }

        rebuildMenuBarMenu()
    }

    @MainActor
    private func rebuildMenuBarMenu() {
        let menu = NSMenu()

        if isRecording {
            let pauseResumeItem = NSMenuItem(
                title: isPaused ? "Resume" : "Pause",
                action: #selector(toggleRecordingPause),
                keyEquivalent: ""
            )
            pauseResumeItem.target = self
            menu.addItem(pauseResumeItem)

            let stopItem = NSMenuItem(
                title: "Stop",
                action: #selector(stopRecordingFromMenuBar),
                keyEquivalent: ""
            )
            stopItem.target = self
            menu.addItem(stopItem)

            statusItem?.menu = menu
            statusItem?.button?.image = NSImage(
                systemSymbolName: isPaused ? "pause.circle.fill" : "record.circle.fill",
                accessibilityDescription: isPaused ? "Recording paused" : "Recording"
            )
            return
        }

        let recordItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(startRecording),
            keyEquivalent: ""
        )
        recordItem.target = self
        menu.addItem(recordItem)

        let shortcutsItem = NSMenuItem(
            title: "Keyboard Shortcuts...",
            action: #selector(showKeyboardShortcuts),
            keyEquivalent: ""
        )
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(AppBrand.name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.image = NSImage(systemSymbolName: "video.circle.fill", accessibilityDescription: AppBrand.name)
    }

    @objc private func startRecording() {
        // Post notification to start recording
        NotificationCenter.default.post(name: .startRecording, object: nil)
    }

    @objc private func showKeyboardShortcuts() {
        NotificationCenter.default.post(name: .shortcutShowShortcuts, object: nil)
    }

    @objc private func toggleRecordingPause() {
        NotificationCenter.default.post(name: .menuToggleRecordingPause, object: nil)
    }

    @objc private func stopRecordingFromMenuBar() {
        NotificationCenter.default.post(name: .menuStopRecording, object: nil)
    }

    @objc private func recordingStatusDidChange(_ notification: Notification) {
        isRecording = notification.userInfo?["isRecording"] as? Bool ?? false
        isPaused = notification.userInfo?["isPaused"] as? Bool ?? false
        rebuildMenuBarMenu()
    }
}

extension Notification.Name {
    static let startRecording = Notification.Name("startRecording")
    static let menuToggleRecordingPause = Notification.Name("menuToggleRecordingPause")
    static let menuStopRecording = Notification.Name("menuStopRecording")
    static let recordingStatusChanged = Notification.Name("recordingStatusChanged")
}
