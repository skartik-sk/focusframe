import SwiftUI

/// One row of the timeline, described in a way that keeps the fixed left gutter and the
/// scrolling body perfectly aligned: both columns render from the same array of specs,
/// so every gutter cell and its body lane share an identical height.
struct TimelineLaneSpec: Identifiable {
    let id: String
    let height: CGFloat
    let gutterTitle: String
    let gutterIcon: String?
    /// Small trailing text in the gutter cell (e.g. audio edit summary, music length).
    let gutterTrailing: String?
    /// Optional trailing add control (a `+` menu) rendered in the gutter cell.
    let addControl: AnyView?
    /// The lane's scrolling body content.
    let bodyContent: AnyView
    /// A 2px coloured bar at the leading edge of the gutter cell, colour-coding the
    /// group (video / edits / audio) so lanes read as groups without extra header rows.
    let groupAccent: Color?

    init(
        id: String,
        height: CGFloat,
        gutterTitle: String,
        gutterIcon: String? = nil,
        gutterTrailing: String? = nil,
        addControl: AnyView? = nil,
        bodyContent: AnyView,
        groupAccent: Color? = nil
    ) {
        self.id = id
        self.height = height
        self.gutterTitle = gutterTitle
        self.gutterIcon = gutterIcon
        self.gutterTrailing = gutterTrailing
        self.addControl = addControl
        self.bodyContent = bodyContent
        self.groupAccent = groupAccent
    }
}

/// A single cell in the fixed left gutter.
struct TimelineGutterRow: View {
    let spec: TimelineLaneSpec

    var body: some View {
        HStack(spacing: 7) {
            if let icon = spec.gutterIcon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 15)
            }
            Text(spec.gutterTitle)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing = spec.gutterTrailing {
                Text(trailing)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            if let add = spec.addControl {
                add
            }
        }
        .padding(.horizontal, 8)
        .frame(height: spec.height, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            if let accent = spec.groupAccent {
                Rectangle()
                    .fill(accent.opacity(0.75))
                    .frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
