import Testing
@testable import T3Code

struct PairingTests {
    @Test func pairingLinkKeepsCredentialsOutOfTheOrigin() throws {
        let target = try PairingTarget(address: "https://host.example:443/pair?token=legacy#token=abc%2Bdef", code: "")
        #expect(target.origin.absoluteString == "https://host.example")
        #expect(target.credential == "abc+def")
    }

    @Test func hostedPairingUsesTheEnvironmentOrigin() throws {
        let target = try PairingTarget(address: "https://app.t3.codes/pair?host=https%3A%2F%2Fhost.example#token=abc", code: "")
        #expect(target.origin.absoluteString == "https://host.example")
        #expect(target.credential == "abc")
    }
}
