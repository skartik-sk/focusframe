import SwiftUI

struct DeferredDoubleSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var labelWidth: CGFloat = 76
    var valueWidth: CGFloat = 48
    var formatter: (Double) -> String

    @State private var draftValue: Double?

    private var displayValue: Double {
        draftValue ?? value
    }

    var body: some View {
        HStack(spacing: 10) {
            if !title.isEmpty || labelWidth > 0 {
                Text(title)
                    .frame(width: labelWidth, alignment: .leading)
            }

            slider

            Text(formatter(displayValue))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var slider: some View {
        let binding = Binding<Double>(
            get: { displayValue },
            set: { draftValue = Self.clamped($0, in: range) }
        )

        if let step {
            Slider(value: binding, in: range, step: step, onEditingChanged: handleEditingChanged)
        } else {
            Slider(value: binding, in: range, onEditingChanged: handleEditingChanged)
        }
    }

    private func handleEditingChanged(_ isEditing: Bool) {
        if isEditing {
            if draftValue == nil {
                draftValue = value
            }
        } else {
            if let draftValue {
                value = Self.clamped(draftValue, in: range)
            }
            draftValue = nil
        }
    }

    nonisolated static func clamped(_ newValue: Double, in range: ClosedRange<Double>) -> Double {
        guard newValue.isFinite else {
            return range.lowerBound
        }
        return min(range.upperBound, max(range.lowerBound, newValue))
    }
}

struct DeferredCGFloatSliderRow: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var step: Double?
    var labelWidth: CGFloat = 76
    var valueWidth: CGFloat = 48
    var formatter: (CGFloat) -> String

    var body: some View {
        DeferredDoubleSliderRow(
            title: title,
            value: Binding(
                get: { Double(value) },
                set: { value = CGFloat($0) }
            ),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: step,
            labelWidth: labelWidth,
            valueWidth: valueWidth,
            formatter: { formatter(CGFloat($0)) }
        )
    }
}

struct DeferredFloatSliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Double?
    var labelWidth: CGFloat = 76
    var valueWidth: CGFloat = 48
    var formatter: (Float) -> String

    var body: some View {
        DeferredDoubleSliderRow(
            title: title,
            value: Binding(
                get: { Double(value) },
                set: { value = Float($0) }
            ),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: step,
            labelWidth: labelWidth,
            valueWidth: valueWidth,
            formatter: { formatter(Float($0)) }
        )
    }
}
