import Foundation
import CoreImage
import CoreGraphics

final class MotionBlurFilter {
    struct Config {
        var radius: Float = 10.0
        var angle: Float = 0.0
        var threshold: Float = 0.5
    }

    func apply(
        to image: CIImage,
        velocity: CGPoint,
        config: Config = .init()
    ) -> CIImage {
        let speed = sqrt(velocity.x * velocity.x + velocity.y * velocity.y)

        guard Float(speed) > config.threshold else {
            return image
        }

        let angle = atan2(velocity.y, velocity.x)
        let dynamicRadius = min(Float(speed) * 2.0, config.radius)

        let motionBlur = CIFilter(name: "CIMotionBlur")
        motionBlur?.setValue(image, forKey: kCIInputImageKey)
        motionBlur?.setValue(dynamicRadius, forKey: kCIInputRadiusKey)
        motionBlur?.setValue(angle, forKey: kCIInputAngleKey)

        return motionBlur?.outputImage ?? image
    }

    func applyDirectionalBlur(
        to image: CIImage,
        direction: CGVector,
        radius: Float = 10.0
    ) -> CIImage {
        let length = sqrt(direction.dx * direction.dx + direction.dy * direction.dy)
        guard length > 0.1 else { return image }

        let angle = atan2(direction.dy, direction.dx)

        let blurFilter = CIFilter(name: "CIMotionBlur")
        blurFilter?.setValue(image, forKey: kCIInputImageKey)
        blurFilter?.setValue(radius, forKey: kCIInputRadiusKey)
        blurFilter?.setValue(angle, forKey: kCIInputAngleKey)

        return blurFilter?.outputImage ?? image
    }

    func applyZoomMotionBlur(
        to image: CIImage,
        fromScale: CGFloat,
        toScale: CGFloat,
        center: CGPoint,
        maxRadius: Float = 15.0
    ) -> CIImage {
        let scaleDelta = abs(toScale - fromScale)

        guard scaleDelta > 0.01 else { return image }

        let normalizedDelta = min(Float(scaleDelta), 1.0)
        let radius = normalizedDelta * maxRadius

        let radialZoomFilter = CIFilter(name: "CIZoomBlur")
        radialZoomFilter?.setValue(image, forKey: kCIInputImageKey)
        radialZoomFilter?.setValue(CIVector(cgPoint: center), forKey: kCIInputCenterKey)
        radialZoomFilter?.setValue(radius, forKey: kCIInputAmountKey)

        return radialZoomFilter?.outputImage ?? image
    }

    func applyRadialBlur(
        to image: CIImage,
        center: CGPoint,
        radius: Float = 20.0
    ) -> CIImage {
        let radialBlur = CIFilter(name: "CIRadialBlur")
        radialBlur?.setValue(image, forKey: kCIInputImageKey)
        radialBlur?.setValue(CIVector(x: center.x, y: center.y), forKey: kCIInputCenterKey)
        radialBlur?.setValue(radius, forKey: kCIInputRadiusKey)

        return radialBlur?.outputImage ?? image
    }
}
