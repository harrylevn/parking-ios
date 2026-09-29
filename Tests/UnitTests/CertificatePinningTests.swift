import Security
import XCTest
@testable import Parking

/// Certificate pinning (6.5), against real certificates evaluated by the real Security framework.
///
/// The fixtures are a throwaway P-256 CA and a `localhost` certificate it issued, generated for
/// these tests only. Their private keys were deleted as soon as they existed, so these are
/// public certificates and nothing here can impersonate anything. The expected pins come from
/// `openssl`, not from the code under test, so a wrong SPKI encoding cannot agree with itself.
final class CertificatePinningTests: XCTestCase {

    // swiftlint:disable line_length
    // Base64 DER, one certificate per literal; wrapping them would only add noise.
    private static let caDER = "MIIBqTCCAU+gAwIBAgIUMKZ6nBwrAcV2TJGW5VJmycc9h0gwCgYIKoZIzj0EAwIwIjEgMB4GA1UEAwwXUGFya2luZyB0ZXN0IGZpeHR1cmUgQ0EwHhcNMjYwOTI5MDcyNTQ5WhcNMzYwOTI2MDcyNTQ5WjAiMSAwHgYDVQQDDBdQYXJraW5nIHRlc3QgZml4dHVyZSBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABAonbk/53EGkvJvsNoa/5m64PAfInjRpssC+2NQqZomjficwZvmuatGTW7KmJ0OFmcrBkKr3ohedJZ9K8UO3pAajYzBhMB0GA1UdDgQWBBRmv2990w7srARbxWPy9ISCgy0y/zAfBgNVHSMEGDAWgBRmv2990w7srARbxWPy9ISCgy0y/zAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAgNIADBFAiEA0tbx3zPOPM/rzypKOFYMZ9psTp5g68PI8lU4C5R3gtwCIDkqde6kZSJX7hNmUXy6GgAP2n7H2YY9v2Kp7nq/G/R0"
    private static let leafDER = "MIIByjCCAXGgAwIBAgIUcTRa8gwySVEl4pB8jqDMdE3meJQwCgYIKoZIzj0EAwIwIjEgMB4GA1UEAwwXUGFya2luZyB0ZXN0IGZpeHR1cmUgQ0EwHhcNMjYwOTI5MDcyNTQ5WhcNMjgxMjA3MDcyNTQ5WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASqyhZYAog4ZSn4Yz40sgjKZHaGHpkpslVka8iVvRL9XXkqGGOZLJ55u6CIqYZaNn/FlckEk1BhDF2ih2yleaawo4GSMIGPMBoGA1UdEQQTMBGCCWxvY2FsaG9zdIcEfwAAATAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAdBgNVHQ4EFgQUlgHO0GMnO8yKQHVIBBPF85fTCC8wHwYDVR0jBBgwFoAUZr9vfdMO7KwEW8Vj8vSEgoMtMv8wCgYIKoZIzj0EAwIDRwAwRAIgMKwWGghdGX3LmI0p+dVgqPoSAIrCzEs23EOaraGB6HQCIC6z/Z6mAqjXbXCKt8XTnja2lekZrGa5mhJ9JE8DoQge"
    // swiftlint:enable line_length

    /// `openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 | base64`
    private static let leafPin = "67cqse5Y4jsnlAsf68VgN0k7KlYk9aWoTRMT6v7/jLY="
    private static let caPin = "uMfAFI2fDi6/deBXul7+c6RKnJMOS1FU2O1lDt720ac="
    private static let unrelatedPin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    private func certificate(_ base64: String) throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    /// A trust object as a TLS handshake would present it: the server's certificate first,
    /// anchored to the fixture CA only, with no network fetches for revocation.
    private func serverTrust(anchored: Bool = true) throws -> SecTrust {
        let leaf = try certificate(Self.leafDER)
        let ca = try certificate(Self.caDER)
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, "localhost" as CFString)
        let status = SecTrustCreateWithCertificates([leaf, ca] as CFArray, policy, &trust)
        XCTAssertEqual(status, errSecSuccess)
        let created = try XCTUnwrap(trust)
        if anchored {
            SecTrustSetAnchorCertificates(created, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(created, true)
        }
        SecTrustSetNetworkFetchAllowed(created, false)
        SecTrustSetVerifyDate(created, Self.verifyDate as CFDate)
        return created
    }

    /// 2026-10-01, just after the fixtures were issued. Fixed, so the tests do not start failing
    /// in 2028 when the leaf expires: iOS refuses TLS certificates valid for more than 825
    /// days, so a leaf that outlasts the repository is not an option.
    private static let verifyDate = Date(timeIntervalSince1970: 1_790_812_800)

    private func trusts(pins: Set<String>, host: String = "localhost", anchored: Bool = true) throws -> Bool {
        PinnedTrustEvaluator.evaluate(try serverTrust(anchored: anchored), host: host, pins: pins)
    }

    // MARK: - The hash

    func testSPKIHashMatchesOpenSSL() throws {
        XCTAssertEqual(SPKIPin.hash(of: try certificate(Self.leafDER)), Self.leafPin)
        XCTAssertEqual(SPKIPin.hash(of: try certificate(Self.caDER)), Self.caPin)
    }

    // MARK: - The evaluator

    func testPinnedServerKeyIsTrusted() throws {
        XCTAssertTrue(try trusts(pins: [Self.leafPin]))
    }

    /// The deliberately wrong pin the plan asks to demonstrate: a valid, trusted chain whose
    /// key is not the pinned one. This is what a certificate mis-issued by a trusted CA, or one
    /// installed by whoever controls the network, looks like to the app.
    func testValidChainWithTheWrongKeyIsRefused() throws {
        XCTAssertFalse(try trusts(pins: [Self.unrelatedPin]))
    }

    /// Pinning narrows ordinary validation; it never replaces it. The right key on a chain the
    /// device does not trust is still refused.
    func testRightKeyOnAnUntrustedChainIsRefused() throws {
        XCTAssertFalse(try trusts(pins: [Self.leafPin], anchored: false))
    }

    func testRightKeyForTheWrongHostIsRefused() throws {
        XCTAssertFalse(try trusts(pins: [Self.leafPin], host: "example.com"))
    }

    /// No pins configured for an HTTPS server fails closed, rather than quietly not pinning.
    func testNoPinsTrustsNothing() throws {
        XCTAssertFalse(try trusts(pins: []))
    }

    /// A backup pin on the issuing CA's key lets the server key rotate without an app release.
    func testCAPinAsBackupIsTrusted() throws {
        XCTAssertTrue(try trusts(pins: [Self.unrelatedPin, Self.caPin]))
    }

    // MARK: - Configuration

    func testPinsAndServerComeFromTheEnvironmentInDebugBuilds() {
        let configuration = APIConfiguration.fromEnvironment([
            "PARKING_BASE_URL": "https://localhost:8443",
            "PARKING_SPKI_PINS": " \(Self.leafPin), \(Self.caPin) ,"
        ])
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://localhost:8443")
        XCTAssertEqual(configuration.pinnedKeys, [Self.leafPin, Self.caPin])
    }

    func testDefaultIsThePlaintextLocalBackendWithNoPins() {
        let configuration = APIConfiguration.fromEnvironment([:])
        XCTAssertEqual(configuration.baseURL, APIConfiguration.localBackend.baseURL)
        XCTAssertTrue(configuration.pinnedKeys.isEmpty)
    }
}
