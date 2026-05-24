import SwiftUI

struct CursorSettingsPanel: View {
    @Binding var cursorScale: CGFloat
    @Binding var cursorStyle: CursorMovementStyle
    @Binding var hideStaticCursor: Bool
    @Binding var loopCursorPosition: Bool
    @Binding var useHighResCursors: Bool
    @Binding var fadeDuration: Double

    var body: some View {
        Form {
            Section {
                DeferredCGFloatSliderRow(
                    title: "Cursor Scale",
                    value: $cursorScale,
                    range: 0.5...3.0,
                    step: 0.1,
                    labelWidth: 88,
                    formatter: { String(format: "%.1fx", Double($0)) }
                )

                Picker("Movement Style", selection: $cursorStyle) {
                    Text("Rapid").tag(CursorMovementStyle.rapid)
                    Text("Quick").tag(CursorMovementStyle.quick)
                    Text("Default").tag(CursorMovementStyle.default)
                    Text("Slow").tag(CursorMovementStyle.slow)
                }

                Toggle("Hide Static Cursor", isOn: $hideStaticCursor)
                Toggle("Loop Cursor Position", isOn: $loopCursorPosition)
                Toggle("Use High-Res Cursors", isOn: $useHighResCursors)
            } header: {
                Text("Cursor")
            }

            if hideStaticCursor {
                Section {
                    DeferredDoubleSliderRow(
                        title: "Fade Duration",
                        value: $fadeDuration,
                        range: 0.1...5.0,
                        step: 0.1,
                        labelWidth: 94,
                        formatter: { String(format: "%.1fs", $0) }
                    )
                } header: {
                    Text("Static Cursor Settings")
                }
            }
        }
        .formStyle(.grouped)
    }
}
