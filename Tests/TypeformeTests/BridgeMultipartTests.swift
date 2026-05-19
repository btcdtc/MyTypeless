import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeMultipart")
struct BridgeMultipartTests {
    @Test func bridgeTokenCompareRejectsLengthMismatches() {
        #expect(BridgeHTTPServer.constantTimeEquals("token-123", "token-123"))
        #expect(!BridgeHTTPServer.constantTimeEquals("token-124", "token-123"))
        #expect(!BridgeHTTPServer.constantTimeEquals("token", "token-123"))
        #expect(!BridgeHTTPServer.constantTimeEquals("token-123-extra", "token-123"))
    }

    @Test func dictateUploadUsesMultipartFilePayload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("AUDIOBYTES".utf8).write(to: url)

        let multipart = try RemoteBridgeClient.multipartDictateBody(
            audioURL: url,
            languageIDs: ["zh-CN", "en-US"],
            correctionMode: CorrectionMode.polish.rawValue,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            appCategory: "chat",
            contextBefore: "前一句。",
            contextAfter: "后一句。",
            includeRawTranscript: true
        )

        #expect(multipart.contentType.hasPrefix("multipart/form-data; boundary="))
        let bodyText = String(data: multipart.body, encoding: .utf8) ?? ""
        #expect(bodyText.contains(#"name="audio"; filename="audio.m4a""#))
        #expect(bodyText.contains("Content-Type: audio/mp4"))
        #expect(bodyText.contains("AUDIOBYTES"))
        #expect(bodyText.contains(#"name="language_ids""#))
        #expect(bodyText.contains(#"["zh-CN","en-US"]"#))
        #expect(bodyText.contains(#"name="context_before""#))
        #expect(bodyText.contains("前一句。"))
        #expect(bodyText.contains(#"name="context_after""#))
        #expect(bodyText.contains("后一句。"))
        #expect(!bodyText.contains("audio_base64"))
    }

    @Test func dictateUploadRejectsUnsupportedAudioExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("AUDIOBYTES".utf8).write(to: url)

        #expect(throws: BridgeMultipartError.self) {
            try RemoteBridgeClient.multipartDictateBody(
                audioURL: url,
                languageIDs: ["zh-CN"],
                correctionMode: CorrectionMode.polish.rawValue,
                appName: "Notes",
                bundleID: "com.apple.Notes",
                appCategory: "chat",
                contextBefore: "",
                contextAfter: "",
                includeRawTranscript: true
            )
        }
    }
}
