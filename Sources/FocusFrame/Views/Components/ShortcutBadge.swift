import SwiftUI

struct ShortcutBadge: View {
    let text: String
    let style: ShortcutBadgeStyle

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, style == .minimal ? 8 : 12)
            .padding(.vertical, 6)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(Capsule())
    }

    private var background: some ShapeStyle {
        switch style {
        case .pillDark, .roundedRect:
            return AnyShapeStyle(Color.black.opacity(0.75))
        case .pillLight:
            return AnyShapeStyle(Color.white.opacity(0.9))
        case .minimal:
            return AnyShapeStyle(Color.clear)
        }
    }

    private var foreground: Color {
        switch style {
        case .pillDark, .roundedRect:
            return .white
        case .pillLight, .minimal:
            return .black
        }
    }
}
