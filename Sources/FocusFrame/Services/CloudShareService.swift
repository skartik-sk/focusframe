import Foundation

final class CloudShareService {
    struct Config {
        var uploadEndpoint: URL?
        var authToken: String?

        static var environment: Config {
            let environment = ProcessInfo.processInfo.environment
            return Config(
                uploadEndpoint: environment["FOCUSFRAME_UPLOAD_ENDPOINT"].flatMap(URL.init(string:)),
                authToken: environment["FOCUSFRAME_UPLOAD_TOKEN"]
            )
        }
    }

    private let config: Config

    init(config: Config = .environment) {
        self.config = config
    }

    func upload(fileURL: URL) async throws -> URL {
        guard let endpoint = config.uploadEndpoint else {
            throw CloudShareError.missingEndpoint
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let authToken = config.authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let bodyURL = try makeMultipartBodyFile(fileURL: fileURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudShareError.uploadFailed
        }

        return try shareURL(from: responseData)
    }

    func shareURL(from responseData: Data) throws -> URL {
        if let decoded = try? JSONDecoder().decode(UploadResponse.self, from: responseData),
           let url = [decoded.url, decoded.shareURL, decoded.link].compactMap({ $0 }).first(where: isRemoteShareURL) {
            return url
        }

        if let text = String(data: responseData, encoding: .utf8),
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           isRemoteShareURL(url) {
            return url
        }

        throw CloudShareError.invalidResponse
    }

    func makeMultipartBodyFile(fileURL: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-upload-\(UUID().uuidString).multipart")
        let filename = sanitizedMultipartFilename(fileURL.lastPathComponent)
        let mimeType = mimeType(for: fileURL)
        let header = "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n" +
            "Content-Type: \(mimeType)\r\n\r\n"
        let footer = "\r\n--\(boundary)--\r\n"

        _ = FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: bodyURL)
        defer { try? outputHandle.close() }

        try outputHandle.write(contentsOf: Data(header.utf8))
        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? inputHandle.close() }

        while true {
            guard let chunk = try inputHandle.read(upToCount: 1_048_576),
                  !chunk.isEmpty else {
                break
            }
            try outputHandle.write(contentsOf: chunk)
        }

        try outputHandle.write(contentsOf: Data(footer.utf8))
        return bodyURL
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "gif":
            return "image/gif"
        case "mov":
            return "video/quicktime"
        default:
            return "video/mp4"
        }
    }

    private func sanitizedMultipartFilename(_ filename: String) -> String {
        let safeScalars = filename.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "\r", "\n", "\"", "\\":
                return "_"
            default:
                return Character(scalar)
            }
        }
        let sanitized = String(safeScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "upload.mp4" : String(sanitized.prefix(180))
    }

    private func isRemoteShareURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

private struct UploadResponse: Decodable {
    let url: URL?
    let shareURL: URL?
    let link: URL?
}

enum CloudShareError: LocalizedError {
    case missingEndpoint
    case uploadFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "Set FOCUSFRAME_UPLOAD_ENDPOINT to enable cloud links."
        case .uploadFailed:
            return "Upload failed."
        case .invalidResponse:
            return "Upload response did not include a share URL."
        }
    }
}
