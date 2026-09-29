import CryptoKit
import Foundation
import Security

/// The SHA-256 of a certificate's SubjectPublicKeyInfo, base64-encoded.
///
/// The public key rather than the whole certificate, because a certificate is renewed every
/// year or so while its key need not be: pinning the key survives a routine renewal, and only a
/// key change (rotation) needs a new pin. It is the value `scripts/tls-proxy.sh pin` prints,
/// computed the same way `openssl pkey -pubin -outform der | openssl dgst -sha256` does.
enum SPKIPin {
    /// Security hands back the bare key, not the SubjectPublicKeyInfo around it, so the
    /// algorithm header is put back before hashing. These are the fixed DER prefixes for the
    /// key types a TLS certificate uses today. Anything else is not pinned: no hash, so no match.
    private static let headers: [String: [Int: [UInt8]]] = [
        kSecAttrKeyTypeECSECPrimeRandom as String: [
            256: [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                  0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00],
            384: [0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                  0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00]
        ],
        kSecAttrKeyTypeRSA as String: [
            2048: [0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7,
                   0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00],
            4096: [0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7,
                   0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0F, 0x00]
        ]
    ]

    static func hash(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let type = attributes[kSecAttrKeyType as String] as? String,
              let size = attributes[kSecAttrKeySizeInBits as String] as? Int,
              let header = headers[type]?[size],
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let digest = SHA256.hash(data: Data(header) + raw)
        return Data(digest).base64EncodedString()
    }
}

/// Decides whether to trust the server a connection reached.
///
/// Both checks, not either: the chain must validate the ordinary way, for this host name, and
/// some certificate in it must carry a pinned key. Pinning replaces nothing; it narrows "any
/// CA the device trusts" to "this server's key", so a certificate mis-issued by a trusted CA,
/// or one installed by whoever controls the network, is still refused.
enum PinnedTrustEvaluator {
    /// - Parameter pins: SPKI hashes. Empty means nothing is trusted: a pinned connection with
    ///   no pins configured fails closed rather than falling back to no pinning.
    static func evaluate(_ trust: SecTrust, host: String, pins: Set<String>) -> Bool {
        guard !pins.isEmpty else { return false }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        guard SecTrustEvaluateWithError(trust, nil) else { return false }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return false }
        // Any certificate in the chain, so a backup pin can be the issuing CA's key: the server
        // key can then rotate without an app release. Which of the two to pin is a policy
        // choice, written up in docs/security.md.
        return chain.contains { certificate in
            SPKIPin.hash(of: certificate).map(pins.contains) ?? false
        }
    }
}

/// Answers the server-trust challenge for one request, and remembers whether it refused.
///
/// Per request rather than per session (`URLSession.data(for:delegate:)`), so the client can
/// tell a refused certificate apart from every other transport failure: both surface as a
/// cancelled `URLError`, and only this object knows which one it was.
final class PinningTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pins: Set<String>
    private let lock = NSLock()
    private var refused = false

    init(pins: Set<String>) {
        self.pins = pins
    }

    /// True once this request's server has been refused.
    var didRefuseServer: Bool {
        lock.withLock { refused }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if PinnedTrustEvaluator.evaluate(trust, host: challenge.protectionSpace.host, pins: pins) {
            return (.useCredential, URLCredential(trust: trust))
        }
        lock.withLock { refused = true }
        return (.cancelAuthenticationChallenge, nil)
    }
}
