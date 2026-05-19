@preconcurrency import AVFoundation
import Foundation

enum ASRAudioSupportError: LocalizedError {
    case audioConversionFailed(String)
    case requestBodyFailed(String)
    case httpStatus(Int, String)
    case timeout(seconds: TimeInterval)
    case emptyTranscript
    case unsupportedBridgeAudioExtension(String)

    var errorDescription: String? {
        switch self {
        case .audioConversionFailed(let detail):
            return "Could not convert audio for ASR upload: \(detail)"
        case .requestBodyFailed(let detail):
            return "Could not build ASR request body: \(detail)"
        case .httpStatus(let code, let body):
            return "ASR server returned HTTP \(code): \(body)"
        case .timeout(let seconds):
            return "ASR timed out after \(Int(seconds))s"
        case .emptyTranscript:
            return "ASR server returned an empty transcript"
        case .unsupportedBridgeAudioExtension(let ext):
            return "Bridge upload audio must be M4A/AAC; got \(ext)"
        }
    }
}

enum ASRAudioSupport {
    static func cleanTranscriptText(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let markerRange = value.range(of: "<asr_text>") {
            value = String(value[markerRange.upperBound...])
        }
        value = value
            .replacingOccurrences(of: "</asr_text>", with: "")
            .replacingOccurrences(
                of: #"(?i)^\s*language\s+(english|chinese|cantonese|japanese|korean|french|german|spanish|portuguese|indonesian|italian|russian|thai|vietnamese|turkish|hindi|malay|dutch|swedish|danish|finnish|polish|czech|tagalog|filipino|persian|greek|hungarian|macedonian|romanian)\s*[:：,-]?\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    static func wavUploadableAudioURL(for url: URL) async throws -> URL {
        if isASRReadyWAV(url) {
            return url
        }

        let output = AppPaths.asrWorkDir
            .appendingPathComponent("typeforme-asr-\(UUID().uuidString).wav")
        do {
            try AppPaths.ensureDirectories()
            try writeWAV(input: url, output: output)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw ASRAudioSupportError.audioConversionFailed(error.localizedDescription)
        }
    }

    static func llamaUploadableAudioURL(for url: URL) async throws -> URL {
        try await wavUploadableAudioURL(for: url)
    }

    static func bridgeUploadAudioURL(for url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        guard ["m4a", "aac"].contains(ext) else {
            throw ASRAudioSupportError.unsupportedBridgeAudioExtension(ext.isEmpty ? "missing extension" : ext)
        }
        return url
    }

    static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(500) ?? ""
            throw ASRAudioSupportError.httpStatus(http.statusCode, String(body))
        }
    }

    private static func writeWAV(input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "--mix",
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            "-r", "127",
            input.path,
            output.path
        ]

        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                throw ASRAudioSupportError.audioConversionFailed(detail)
            }
            throw ASRAudioSupportError.audioConversionFailed("afconvert exited with \(process.terminationStatus)")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let byteCount = attributes[.size] as? NSNumber
        guard (byteCount?.intValue ?? 0) > 44 else {
            throw ASRAudioSupportError.audioConversionFailed("Converted WAV contains no audio data")
        }
    }

    private static func isASRReadyWAV(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "wav",
              let file = try? AVAudioFile(forReading: url)
        else { return false }
        let format = file.fileFormat
        return format.channelCount == 1 && abs(format.sampleRate - 16_000) < 1
    }
}
