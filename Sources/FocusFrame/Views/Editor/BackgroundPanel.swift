import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BackgroundPanel: View {
    @Binding var style: StylePreset
    @State private var recentBackgroundImages = BackgroundImageHistory.load()
    
    var body: some View {
        Form {
            Section(header: Text("Background")) {
                Picker("Type", selection: $style.backgroundType) {
                    ForEach(BackgroundType.allCases, id: \.self) { type in
                        Text(typeDisplayName(type)).tag(type)
                    }
                }
                
                switch style.backgroundType {
                case .solid:
                    ColorPicker("Color", selection: Binding(
                        get: { Color(cgColor: style.backgroundColor.cgColor) },
                        set: { color in
                            style.backgroundColor = CodableColor(from: color)
                        }
                    ))
                    
                case .gradient:
                    ColorPicker("Start Color", selection: Binding(
                        get: { 
                            Color(cgColor: style.backgroundGradientColors.first?.cgColor ?? CGColor(gray: 0, alpha: 1))
                        },
                        set: { color in
                            if !style.backgroundGradientColors.isEmpty {
                                style.backgroundGradientColors[0] = CodableColor(from: color)
                            }
                        }
                    ))
                    
                    ColorPicker("End Color", selection: Binding(
                        get: { 
                            Color(cgColor: style.backgroundGradientColors.last?.cgColor ?? CGColor(gray: 1, alpha: 1))
                        },
                        set: { color in
                            if style.backgroundGradientColors.count >= 2 {
                                style.backgroundGradientColors[1] = CodableColor(from: color)
                            }
                        }
                    ))
                    
                    DeferredDoubleSliderRow(
                        title: "Angle",
                        value: $style.backgroundGradientAngle,
                        range: 0...360,
                        labelWidth: 72,
                        formatter: { "\(Int($0))deg" }
                    )
                    
                case .image:
                    if let imageURL = style.backgroundImageURL {
                        Text(imageURL.lastPathComponent)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Button("Select Image") {
                            selectBackgroundImage()
                        }
                        Button("Use Desktop Wallpaper") {
                            useDesktopWallpaper()
                        }
                        historyMenu
                    }
                }
            }
            
            Section(header: Text("Layout")) {
                DeferredCGFloatSliderRow(
                    title: "Padding",
                    value: $style.padding,
                    range: 0...200,
                    labelWidth: 92,
                    formatter: { "\(Int($0))px" }
                )
                
                DeferredCGFloatSliderRow(
                    title: "Corner Radius",
                    value: $style.cornerRadius,
                    range: 0...100,
                    labelWidth: 92,
                    formatter: { "\(Int($0))px" }
                )
            }
            
            Section(header: Text("Shadow")) {
                Toggle("Enable Shadow", isOn: $style.shadowEnabled)
                
                if style.shadowEnabled {
                    DeferredCGFloatSliderRow(
                        title: "Radius",
                        value: $style.shadowRadius,
                        range: 0...100,
                        labelWidth: 72,
                        formatter: { "\(Int($0))px" }
                    )
                    
                    DeferredCGFloatSliderRow(
                        title: "Offset X",
                        value: $style.shadowOffsetX,
                        range: -50...50,
                        labelWidth: 72,
                        formatter: { "\(Int($0))px" }
                    )
                    
                    DeferredCGFloatSliderRow(
                        title: "Offset Y",
                        value: $style.shadowOffsetY,
                        range: -50...50,
                        labelWidth: 72,
                        formatter: { "\(Int($0))px" }
                    )
                    
                    DeferredFloatSliderRow(
                        title: "Opacity",
                        value: $style.shadowOpacity,
                        range: 0...1,
                        labelWidth: 72,
                        formatter: { String(format: "%.2f", $0) }
                    )
                    
                    ColorPicker("Shadow Color", selection: Binding(
                        get: { Color(cgColor: style.shadowColor.cgColor) },
                        set: { color in
                            style.shadowColor = CodableColor(from: color)
                        }
                    ))
                }
            }
            
            Section(header: Text("Preset")) {
                Button("Reset to Default") {
                    style = StylePreset.default
                }
            }
        }
        .formStyle(.grouped)
    }
    
    private func typeDisplayName(_ type: BackgroundType) -> String {
        switch type {
        case .solid: return "Solid Color"
        case .gradient: return "Gradient"
        case .image: return "Image"
        }
    }
    
    private func selectBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            applyBackgroundImage(url)
        }
    }

    private func useDesktopWallpaper() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return
        }
        applyBackgroundImage(url)
    }

    @ViewBuilder
    private var historyMenu: some View {
        if !recentBackgroundImages.isEmpty {
            Menu {
                ForEach(recentBackgroundImages, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        applyBackgroundImage(url)
                    }
                }
                Divider()
                Button("Clear History") {
                    BackgroundImageHistory.clear()
                    recentBackgroundImages = []
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private func applyBackgroundImage(_ url: URL) {
        guard BackgroundImageHistory.add(url) else { return }
        style.backgroundType = .image
        style.backgroundImageURL = url
        recentBackgroundImages = BackgroundImageHistory.load()
    }
}

// Helper extension for Color -> CodableColor conversion
extension CodableColor {
    init(from color: Color) {
        let nsColor = NSColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        nsColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        self.r = red
        self.g = green
        self.b = blue
        self.a = alpha
    }
}
