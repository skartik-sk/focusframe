import SwiftUI
import AppKit

struct ShortcutSettingsView: View {
    @ObservedObject var manager: KeyboardShortcutManager
    @Environment(\.dismiss) private var dismiss
    @State private var capturingAction: ShortcutAction?
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ShortcutAction.allCases) { action in
                        shortcutRow(for: action)
                        if action != ShortcutAction.allCases.last {
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .padding(20)
            }

            Divider()

            HStack {
                Button("Reset All") {
                    manager.resetAllShortcuts()
                    capturingAction = nil
                    statusMessage = "Shortcuts reset to defaults."
                }

                Spacer()

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 620, height: 620)
        .onChange(of: capturingAction) { action in
            manager.isCapturingShortcut = action != nil
        }
        .onDisappear {
            manager.isCapturingShortcut = false
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("Keyboard Shortcuts")
                    .font(.title3.weight(.semibold))
                Text("Record a shortcut, reset one action, or restore the defaults.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }

    private func shortcutRow(for action: ShortcutAction) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.rawValue)
                    .font(.callout.weight(.semibold))
                Text(action.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if capturingAction == action {
                ShortcutCapturePill(
                    onCapture: { shortcut in
                        apply(shortcut, to: action)
                    },
                    onCancel: {
                        capturingAction = nil
                        statusMessage = "Shortcut recording cancelled."
                    }
                )
            } else {
                Text(manager.getShortcut(for: action)?.displayString ?? "Unassigned")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .frame(minWidth: 112, alignment: .center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }

            Button("Record") {
                capturingAction = action
                statusMessage = "Press the new shortcut for \(action.rawValue)."
            }
            .disabled(capturingAction != nil && capturingAction != action)

            Button("Reset") {
                manager.resetShortcut(action)
                capturingAction = nil
                statusMessage = "\(action.rawValue) reset."
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func apply(_ shortcut: KeyboardShortcut, to action: ShortcutAction) {
        if let conflict = conflictingAction(for: shortcut, excluding: action) {
            statusMessage = "\(shortcut.displayString) is already used by \(conflict.rawValue)."
            return
        }

        manager.registerShortcut(action, shortcut: shortcut)
        capturingAction = nil
        manager.isCapturingShortcut = false
        statusMessage = "\(action.rawValue) set to \(shortcut.displayString)."
    }

    private func conflictingAction(for shortcut: KeyboardShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { candidate in
            candidate != action && manager.getShortcut(for: candidate) == shortcut
        }
    }
}

private struct ShortcutCapturePill: View {
    let onCapture: (KeyboardShortcut) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.accentColor.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                )

            Text("Press keys")
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)

            ShortcutCaptureField(onCapture: onCapture, onCancel: onCancel)
                .opacity(0.02)
        }
        .frame(width: 132, height: 32)
    }
}

private struct ShortcutCaptureField: NSViewRepresentable {
    let onCapture: (KeyboardShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onCapture: ((KeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        if let shortcut = KeyboardShortcut.from(event: event) {
            onCapture?(shortcut)
        }
    }
}
