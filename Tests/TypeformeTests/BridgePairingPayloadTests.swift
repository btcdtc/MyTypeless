import Foundation
import Testing
@testable import Typeforme

@Suite("BridgePairingPayload")
struct BridgePairingPayloadTests {
    @Test func pairingJSONOnlyContainsEnabledRoutesAndToken() throws {
        let payload = BridgePairingPayload(
            lanBridgeURL: "http://192.168.1.10:18081",
            lanBridgeURLs: [
                "http://192.168.1.10:18081",
                "http://10.0.0.5:18081",
            ],
            publicBridgeURL: "https://voice.example.com",
            token: "token-123"
        )
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["lan_bridge_url", "lan_bridge_urls", "public_bridge_url", "token"])
        #expect(object["lan_bridge_url"] as? String == "http://192.168.1.10:18081")
        #expect(object["lan_bridge_urls"] as? [String] == [
            "http://192.168.1.10:18081",
            "http://10.0.0.5:18081",
        ])
        #expect(object["public_bridge_url"] as? String == "https://voice.example.com")
        #expect(object["token"] as? String == "token-123")
    }

    @Test func pairingJSONOmitsDisabledRoutes() throws {
        let payload = BridgePairingPayload(
            lanBridgeURL: nil,
            publicBridgeURL: "https://voice.example.com",
            token: "token-123"
        )
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["public_bridge_url", "token"])
        #expect(object["public_bridge_url"] as? String == "https://voice.example.com")
        #expect(object["token"] as? String == "token-123")
    }
}
