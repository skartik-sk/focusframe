import SwiftUI

struct KeyboardOverlayPanel: View {
    @Binding var showKeyboardShortcuts: Bool
    @Binding var position: ShortcutPosition
    @Binding var style: ShortcutBadgeStyle

    var body: some View {
        Form {
            Toggle("Show Keyboard Shortcuts", isOn: $showKeyboardShortcuts)

            if showKeyboardShortcuts {
                Picker("Position", selection: $position) {
                    ForEach(ShortcutPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }

                Picker("Badge Style", selection: $style) {
                    ForEach(ShortcutBadgeStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
