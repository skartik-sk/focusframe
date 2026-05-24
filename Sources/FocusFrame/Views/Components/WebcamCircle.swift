import SwiftUI

struct WebcamCircle: View {
    let image: Image?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.15))
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Image(systemName: "video.fill")
                    .foregroundColor(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 2))
        .shadow(radius: 10)
    }
}
