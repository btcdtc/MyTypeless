import Foundation

enum BridgeMultipartError: LocalizedError {
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        }
    }
}

enum BridgeMultipart {
    struct Part {
        let name: String
        let filename: String?
        let contentType: String?
        let data: Data
    }

    struct Body {
        let body: Data
        let contentType: String
    }

    static func dictateBody(
        audioURL: URL,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool
    ) throws -> Body {
        try dictateBody(
            audioURL: audioURL,
            audioExtension: nil,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript
        )
    }

    static func dictateBody(
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: String,
        appName: String,
        appCategory: String,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool
    ) throws -> Body {
        try dictateBody(
            audioURL: audioURL,
            audioExtension: audioExtension,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: nil,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript
        )
    }

    private static func dictateBody(
        audioURL: URL,
        audioExtension: String?,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool
    ) throws -> Body {
        let boundary = "Typeforme-\(UUID().uuidString)"
        var body = Data()

        appendField("language_ids", jsonString(languageIDs), to: &body, boundary: boundary)
        appendField("correction_mode", correctionMode, to: &body, boundary: boundary)
        appendField("app_category", appCategory, to: &body, boundary: boundary)
        appendField("context_before", contextBefore, to: &body, boundary: boundary)
        appendField("context_after", contextAfter, to: &body, boundary: boundary)
        appendField("include_raw_transcript", includeRawTranscript ? "true" : "false", to: &body, boundary: boundary)
        if let appName, !appName.isEmpty {
            appendField("app_name", appName, to: &body, boundary: boundary)
        }
        if let bundleID, !bundleID.isEmpty {
            appendField("bundle_id", bundleID, to: &body, boundary: boundary)
        }

        let explicitExtension = audioExtension?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (
            explicitExtension?.isEmpty == false
                ? explicitExtension!
                : (audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension)
        ).lowercased()
        guard ["m4a", "aac"].contains(ext) else {
            throw BridgeMultipartError.invalidRequest("Unsupported audio extension: \(ext)")
        }
        appendField("audio_extension", ext, to: &body, boundary: boundary)
        try appendFile(
            name: "audio",
            filename: "audio.\(ext)",
            contentType: mimeType(forExtension: ext),
            fileURL: audioURL,
            to: &body,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n")
        return Body(body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    static func parseFormData(
        _ body: Data,
        contentType: String,
        maxHeaderBytes: Int
    ) throws -> [Part] {
        guard contentType.lowercased().contains("multipart/form-data") else {
            throw BridgeMultipartError.invalidRequest("Content-Type must be multipart/form-data")
        }
        guard let boundary = boundary(from: contentType) else {
            throw BridgeMultipartError.invalidRequest("Missing multipart boundary")
        }
        return try parseFormData(body, boundary: boundary, maxHeaderBytes: maxHeaderBytes)
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "aac": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func boundary(from contentType: String) -> String? {
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, pair[0].lowercased() == "boundary" else { continue }
            let boundary = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return isValidBoundary(boundary) ? boundary : nil
        }
        return nil
    }

    private static func isValidBoundary(_ boundary: String) -> Bool {
        let bytes = Array(boundary.utf8)
        guard !bytes.isEmpty, bytes.count <= 70 else { return false }
        for byte in bytes {
            let isAlphaNumeric = (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
            let isAllowedPunctuation = [39, 40, 41, 43, 44, 45, 46, 47, 58, 61, 63, 95].contains(byte)
            guard isAlphaNumeric || isAllowedPunctuation else { return false }
        }
        return true
    }

    private static func parseFormData(_ body: Data, boundary: String, maxHeaderBytes: Int) throws -> [Part] {
        let delimiter = Data("--\(boundary)".utf8)
        let prefixedDelimiter = Data("\r\n--\(boundary)".utf8)
        let headerSeparator = Data([13, 10, 13, 10])
        let closing = Data("--".utf8)
        var parts: [Part] = []
        var cursor = body.startIndex

        while let boundaryRange = body.range(of: delimiter, in: cursor..<body.endIndex) {
            cursor = boundaryRange.upperBound
            if body[cursor...].starts(with: closing) {
                break
            }
            if body[cursor...].starts(with: Data([13, 10])) {
                cursor += 2
            }

            guard let headerRange = body.range(of: headerSeparator, in: cursor..<body.endIndex)
            else {
                throw BridgeMultipartError.invalidRequest("Malformed multipart headers")
            }
            let headerData = body[cursor..<headerRange.lowerBound]
            guard headerData.count <= maxHeaderBytes,
                  let headerText = String(data: headerData, encoding: .utf8)
            else {
                throw BridgeMultipartError.invalidRequest("Malformed multipart headers")
            }
            cursor = headerRange.upperBound

            guard let nextBoundary = body.range(of: prefixedDelimiter, in: cursor..<body.endIndex) else {
                throw BridgeMultipartError.invalidRequest("Malformed multipart body")
            }

            let partData = Data(body[cursor..<nextBoundary.lowerBound])
            if let part = part(from: headerText, data: partData) {
                parts.append(part)
            }
            cursor = nextBoundary.lowerBound + 2
        }

        if parts.isEmpty {
            throw BridgeMultipartError.invalidRequest("Multipart request contains no form parts")
        }
        return parts
    }

    private static func part(from headerText: String, data: Data) -> Part? {
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        guard let disposition = headers["content-disposition"],
              let name = headerParameter("name", in: disposition)
        else {
            return nil
        }
        return Part(
            name: name,
            filename: headerParameter("filename", in: disposition),
            contentType: headers["content-type"],
            data: data
        )
    }

    private static func headerParameter(_ name: String, in header: String) -> String? {
        for parameter in header.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, pair[0].lowercased() == name.lowercased() else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func appendField(_ name: String, _ value: String, to body: inout Data, boundary: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append(value)
        body.append("\r\n")
    }

    private static func appendFile(
        name: String,
        filename: String,
        contentType: String,
        fileURL: URL,
        to body: inout Data,
        boundary: String
    ) throws {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n")
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
