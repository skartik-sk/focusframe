import XCTest
@testable import FocusFrame

final class CloudShareServiceTests: XCTestCase {
    func testMultipartUploadBodyIsWrittenToTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-cloud-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("demo.mp4")
        try Data("video-bytes".utf8).write(to: videoURL)
        let service = CloudShareService(
            config: .init(uploadEndpoint: URL(string: "https://example.com/upload"), authToken: nil)
        )

        let bodyURL = try service.makeMultipartBodyFile(fileURL: videoURL, boundary: "Boundary-Test")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let body = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertTrue(body.contains("--Boundary-Test"))
        XCTAssertTrue(body.contains("filename=\"demo.mp4\""))
        XCTAssertTrue(body.contains("Content-Type: video/mp4"))
        XCTAssertTrue(body.contains("video-bytes"))
        XCTAssertTrue(body.contains("--Boundary-Test--"))
    }

    func testMultipartFilenameIsEscapedBeforeWritingHeader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-cloud-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("bad\"\r\nX-Evil: yes.mp4")
        try Data("video-bytes".utf8).write(to: videoURL)
        let service = CloudShareService(
            config: .init(uploadEndpoint: URL(string: "https://example.com/upload"), authToken: nil)
        )

        let bodyURL = try service.makeMultipartBodyFile(fileURL: videoURL, boundary: "Boundary-Test")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let body = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertTrue(body.contains("filename=\"bad___X-Evil: yes.mp4\""))
        XCTAssertFalse(body.contains("\r\nX-Evil: yes"))
    }

    func testShareURLParserAcceptsOnlyRemoteHTTPURLs() throws {
        let service = CloudShareService(
            config: .init(uploadEndpoint: URL(string: "https://example.com/upload"), authToken: nil)
        )

        let json = Data(#"{"url":"https://cdn.example.com/demo.mp4"}"#.utf8)
        XCTAssertEqual(try service.shareURL(from: json).absoluteString, "https://cdn.example.com/demo.mp4")

        XCTAssertThrowsError(try service.shareURL(from: Data(#"{"url":"file:///tmp/demo.mp4"}"#.utf8)))
        XCTAssertThrowsError(try service.shareURL(from: Data("file:///tmp/demo.mp4".utf8)))
        XCTAssertThrowsError(try service.shareURL(from: Data("/tmp/demo.mp4".utf8)))
    }
}
