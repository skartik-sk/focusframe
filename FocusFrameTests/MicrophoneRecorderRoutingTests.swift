import XCTest
@testable import FocusFrame
import AVFoundation

/// Guards the macOS 27 mic-capture regression: routing the engine input unit to the
/// device that is already the system default must be skipped — that AudioUnit property
/// call can leave the input unit started-but-silent, killing the whole recording.
final class MicrophoneRecorderRoutingTests: XCTestCase {
    func testRoutableDeviceReturnsNilForNilDevice() {
        XCTAssertNil(MicrophoneRecorder.routableDevice(nil))
    }

    func testRoutableDeviceReturnsNilForSystemDefaultDevice() throws {
        guard let defaultDevice = AVCaptureDevice.default(for: .audio) else {
            throw XCTSkip("No default audio input device on this machine")
        }
        XCTAssertNil(
            MicrophoneRecorder.routableDevice(defaultDevice),
            "Routing to the default device is redundant and, on macOS 27, breaks the input unit — it must be skipped."
        )
    }

    func testRoutableDeviceReturnsDeviceForNonDefaultDevice() throws {
        let candidates = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external, .builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        guard let defaultDevice = AVCaptureDevice.default(for: .audio),
              let nonDefault = candidates.first(where: { $0.uniqueID != defaultDevice.uniqueID }) else {
            throw XCTSkip("Only one audio input device available; nothing non-default to route to")
        }
        XCTAssertEqual(MicrophoneRecorder.routableDevice(nonDefault)?.uniqueID, nonDefault.uniqueID)
    }

    func testLivenessCounterCountsConcurrentIncrements() {
        let counter = LivenessCounter()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.liveness", attributes: .concurrent)
        for _ in 0..<1_000 {
            group.enter()
            queue.async {
                counter.increment()
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(counter.count(), 1_000)
    }
}
