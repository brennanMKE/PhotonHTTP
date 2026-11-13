import Foundation
import Security

/// A TLS server identity (certificate and private key) loaded from PKCS#12 **in memory only**
/// (#0072; reused by the TLS listener in #0087 and by ``QUICListener``).
///
/// `SecPKCS12Import` is always called with `kSecImportToMemoryOnly: true`. Without it, macOS
/// adds the key to the login keychain, and the first TLS signature then blocks on a
/// SecurityAgent prompt, so the handshake silently hangs (docs/spikes/quic-spike.md, gotcha 1;
/// AGENTS.md). Nothing here reads, adds or changes keychain items or trust settings.
public struct TLSIdentity: @unchecked Sendable {
    // @unchecked: SecIdentity and sec_identity_t are immutable objects and safe to share.
    let secIdentity: SecIdentity
    /// The identity as Network.framework's `sec_identity_t`, created once at import (#0141).
    let networkIdentity: sec_identity_t
    /// The leaf certificate in DER form.
    public let certificateDER: [UInt8]

    /// Imports the first identity in a PKCS#12 bundle and checks that TLS can use it: a
    /// private key comes with the certificate, and the key is RSA or EC (#0141).
    public init(pkcs12 bytes: [UInt8], password: String) throws(TLSIdentityError) {
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        let status = SecPKCS12Import(Data(bytes) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw .importFailed(status: status) }
        guard let array = items as? [[String: Any]],
              let value = array.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
        else { throw .noIdentity }
        let identity = value as! SecIdentity   // checked by the type ID above
        var certificate: SecCertificate?
        let copyStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard copyStatus == errSecSuccess, let certificate else { throw .importFailed(status: copyStatus) }
        // The key type is read from the certificate's public key: no private-key operation and
        // no keychain lookup.
        guard let publicKey = SecCertificateCopyKey(certificate) else { throw .unsupportedKeyType("unknown") }
        let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any]
        let keyType = attributes?[kSecAttrKeyType as String] as? String
        guard keyType == (kSecAttrKeyTypeRSA as String) || keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) else {
            throw .unsupportedKeyType(keyType ?? "unknown")
        }
        guard let networkIdentity = sec_identity_create(identity) else { throw .notUsableForTLS }
        self.secIdentity = identity
        self.networkIdentity = networkIdentity
        self.certificateDER = [UInt8](SecCertificateCopyData(certificate) as Data)
    }

    /// Reads and imports a PKCS#12 file.
    public init(pkcs12Path path: String, password: String) throws(TLSIdentityError) {
        guard let data = FileManager.default.contents(atPath: path) else { throw .fileUnreadable(path: path) }
        try self.init(pkcs12: [UInt8](data), password: password)
    }
}

/// Why a ``TLSIdentity`` could not be loaded. The ``description`` says what failed and what to
/// check (#0141).
public enum TLSIdentityError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The file could not be read.
    case fileUnreadable(path: String)
    /// `SecPKCS12Import` (or reading the certificate) failed with this `OSStatus`, for example
    /// `errSecAuthFailed` (-25293) for a wrong password.
    case importFailed(status: Int32)
    /// The bundle contained no identity: no certificate with its private key.
    case noIdentity
    /// The certificate's key is not RSA or EC. The value is the Security framework key type,
    /// or `unknown` when Security.framework cannot read the key (for example Ed25519 or DSA).
    case unsupportedKeyType(String)
    /// Network.framework could not make a TLS identity of it (`sec_identity_create` failed).
    case notUsableForTLS

    public var description: String {
        switch self {
        case .fileUnreadable(let path):
            return "the file \(path) cannot be read; check the path (relative paths resolve against the config file's directory) and its permissions"
        case .importFailed(let status):
            switch status {
            case errSecAuthFailed, errSecPkcs12VerifyFailure:
                return "wrong password (OSStatus \(status)); check tls.password or tls.passwordEnv"
            case errSecPassphraseRequired:
                return "the file needs a password (OSStatus \(status)); set tls.password or tls.passwordEnv"
            case errSecDecode, errSecUnknownFormat:
                return "not a PKCS#12 file Security.framework can read (OSStatus \(status)); export it with openssl pkcs12 -export (OpenSSL 3: add -legacy, or -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)"
            default:
                return "PKCS#12 import failed (OSStatus \(status)); check the file and its password"
            }
        case .noIdentity:
            return "the file holds no certificate with its private key; export both with openssl pkcs12 -export -inkey KEY.pem -in CERT.pem"
        case .unsupportedKeyType(let type):
            return "the certificate's key type (\(type)) is not supported; use an RSA or EC (P-256, P-384) key"
        case .notUsableForTLS:
            return "Network.framework cannot use the certificate and key as a TLS identity; check that the private key belongs to the certificate"
        }
    }
}
