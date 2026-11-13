public import HTTPCore
import Dispatch
import Foundation
import Network
import Security

/// Server-side TLS settings for a ``TCPListener`` (#0087, legacy #0057).
///
/// TLS runs inside Network.framework (`NWProtocolTLS` over TCP, docs/ROADMAP.md §2): the
/// listener's accepted connections are handed over only after the handshake, with the
/// negotiated ALPN token and TLS version in ``TCPTransport/info``.
///
/// The identity is a ``TLSIdentity``, imported from PKCS#12 **in memory only**
/// (`kSecImportToMemoryOnly`); nothing here reads or changes keychain items or trust settings
/// (AGENTS.md).
public struct TLSConfiguration: Sendable {
    /// Verifies client certificates (mutual TLS). Off unless set.
    public struct ClientAuthentication: Sendable {
        /// Whether a client must present a certificate. When false, a client without one is
        /// accepted and ``verify`` runs only for clients that send one.
        public var required: Bool
        /// Decides whether to accept a client's certificate chain (DER, leaf first). Called on
        /// a Network.framework queue during the handshake; must not block.
        public var verify: @Sendable (_ chainDER: [[UInt8]]) -> Bool

        public init(required: Bool = true, verify: @escaping @Sendable (_ chainDER: [[UInt8]]) -> Bool) {
            self.required = required
            self.verify = verify
        }
    }

    /// Where the listener gets the server certificate and private key on each handshake.
    /// Replacing the store's identity (``TLSIdentityStore/replace(with:)``) changes the
    /// certificate for new handshakes without restarting the listener (#0140).
    public var identityStore: TLSIdentityStore
    /// The server certificate and private key new handshakes use. Setting it gives this
    /// configuration a new ``identityStore``; other copies keep theirs.
    public var identity: TLSIdentity {
        get { identityStore.identity }
        set { identityStore = TLSIdentityStore(newValue) }
    }
    /// The lowest TLS version accepted. TLS 1.2 by default; Network.framework negotiates the
    /// highest version both sides support, so TLS 1.3 is used whenever the client offers it.
    public var minimumVersion: TLSVersion
    /// The highest TLS version offered, or `nil` for the system's highest (TLS 1.3).
    public var maximumVersion: TLSVersion?
    /// ALPN tokens accepted, in server preference order. Build it from the server's protocol
    /// registry (`ProtocolRegistry.alpnTokens` in HTTPServer) so every registered protocol is
    /// offered; HTTP/1.1 alone is `["http/1.1"]`.
    public var alpn: [String]
    /// Client certificate checking; `nil` (the default) asks for no client certificate.
    public var clientAuthentication: ClientAuthentication?
    /// How long an accepted connection may spend in the TCP and TLS handshakes before it is
    /// reset. Bounds clients that connect and never finish the handshake, which would otherwise
    /// hold a slot of the listener's pending-connection queue.
    public var handshakeTimeout: Duration

    public init(
        identity: TLSIdentity,
        minimumVersion: TLSVersion = .v1_2,
        maximumVersion: TLSVersion? = nil,
        alpn: [String] = ["http/1.1"],
        clientAuthentication: ClientAuthentication? = nil,
        handshakeTimeout: Duration = .seconds(10)
    ) {
        self.init(identityStore: TLSIdentityStore(identity), minimumVersion: minimumVersion,
                  maximumVersion: maximumVersion, alpn: alpn, clientAuthentication: clientAuthentication,
                  handshakeTimeout: handshakeTimeout)
    }

    /// Takes the identity from `identityStore` on every handshake, so it can be replaced while
    /// the listener runs (#0140).
    public init(
        identityStore: TLSIdentityStore,
        minimumVersion: TLSVersion = .v1_2,
        maximumVersion: TLSVersion? = nil,
        alpn: [String] = ["http/1.1"],
        clientAuthentication: ClientAuthentication? = nil,
        handshakeTimeout: Duration = .seconds(10)
    ) {
        precondition(handshakeTimeout > .zero, "handshakeTimeout must be positive")
        self.identityStore = identityStore
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
        self.alpn = alpn
        self.clientAuthentication = clientAuthentication
        self.handshakeTimeout = handshakeTimeout
    }

    /// Loads the identity from a PKCS#12 file (in memory only). Throws
    /// ``TLSIdentityError/fileUnreadable(path:)`` for a missing file and
    /// ``TLSIdentityError/importFailed(status:)`` (`errSecAuthFailed`) for a wrong password.
    public init(
        pkcs12Path: String,
        password: String,
        alpn: [String] = ["http/1.1"]
    ) throws(TLSIdentityError) {
        self.init(identity: try TLSIdentity(pkcs12Path: pkcs12Path, password: password), alpn: alpn)
    }

    /// Checks the version range: only TLS 1.2 and TLS 1.3 are accepted, and the minimum may
    /// not exceed the maximum. Nothing is clamped (#0141). ``TCPListener`` calls it at init.
    public func validate() throws(TLSConfigurationError) {
        try TLSVersion.checkRange(minimum: minimumVersion, maximum: maximumVersion)
    }

    /// Network.framework TLS options for the listener.
    func makeOptions() throws(TLSConfigurationError) -> NWProtocolTLS.Options {
        try validate()
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        identityStore.install(on: options)
        sec_protocol_options_set_min_tls_protocol_version(options, minimumVersion.supportedProtocolVersion!)
        if let maximumVersion {
            sec_protocol_options_set_max_tls_protocol_version(options, maximumVersion.supportedProtocolVersion!)
        }
        for token in alpn {
            sec_protocol_options_add_tls_application_protocol(options, token)
        }
        if let clientAuthentication {
            sec_protocol_options_set_peer_authentication_required(options, clientAuthentication.required)
            let verify = clientAuthentication.verify
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                complete(verify(certificateChain(of: trust)))
            }, DispatchQueue.global())
        }
        return tls
    }
}

/// Client-side TLS settings for ``TCPTransport/connect(host:port:configuration:tls:)``: tests and
/// tools that talk to a ``TCPListener`` with TLS.
public struct TLSClientConfiguration: Sendable, Hashable {
    /// ALPN tokens offered, in preference order. Empty offers none.
    public var alpn: [String]
    /// Accept exactly this leaf certificate (DER) with no trust evaluation, for the self-signed
    /// test identity (no keychain or trust-settings change); `nil` uses the system's evaluation.
    public var pinnedCertificate: [UInt8]?
    /// TLS server name (SNI), or `nil` for none.
    public var serverName: String?
    /// The lowest TLS version offered.
    public var minimumVersion: TLSVersion
    /// The highest TLS version offered, or `nil` for the system's highest.
    public var maximumVersion: TLSVersion?

    public init(
        alpn: [String] = ["http/1.1"],
        pinnedCertificate: [UInt8]? = nil,
        serverName: String? = nil,
        minimumVersion: TLSVersion = .v1_2,
        maximumVersion: TLSVersion? = nil
    ) {
        self.alpn = alpn
        self.pinnedCertificate = pinnedCertificate
        self.serverName = serverName
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
    }

    func makeOptions() throws(TLSConfigurationError) -> NWProtocolTLS.Options {
        try TLSVersion.checkRange(minimum: minimumVersion, maximum: maximumVersion)
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for token in alpn {
            sec_protocol_options_add_tls_application_protocol(options, token)
        }
        if let serverName {
            sec_protocol_options_set_tls_server_name(options, serverName)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, minimumVersion.supportedProtocolVersion!)
        if let maximumVersion {
            sec_protocol_options_set_max_tls_protocol_version(options, maximumVersion.supportedProtocolVersion!)
        }
        if let expected = pinnedCertificate {
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                complete(certificateChain(of: trust).first == expected)
            }, DispatchQueue.global())
        }
        return tls
    }
}

extension TLSVersion {
    /// The Security framework value for a version this server supports (TLS 1.2 and 1.3), or
    /// `nil`. Nothing is clamped: an older or unknown version is an error (#0141).
    var supportedProtocolVersion: tls_protocol_version_t? {
        switch self {
        case .v1_2: .TLSv12
        case .v1_3: .TLSv13
        default: nil
        }
    }

    /// Throws unless both bounds are supported versions and `minimum` does not exceed `maximum`.
    static func checkRange(minimum: TLSVersion, maximum: TLSVersion?) throws(TLSConfigurationError) {
        guard minimum.supportedProtocolVersion != nil else { throw .unsupportedMinimumVersion(minimum) }
        guard let maximum else { return }
        guard maximum.supportedProtocolVersion != nil else { throw .unsupportedMaximumVersion(maximum) }
        guard minimum <= maximum else { throw .emptyVersionRange(minimum: minimum, maximum: maximum) }
    }
}

/// Why TLS settings cannot be used (#0141). The ``description`` says what to change.
public enum TLSConfigurationError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The minimum version is not TLS 1.2 or TLS 1.3. Older versions are not offered, and the
    /// value is never silently changed to a supported one.
    case unsupportedMinimumVersion(TLSVersion)
    /// The maximum version is not TLS 1.2 or TLS 1.3.
    case unsupportedMaximumVersion(TLSVersion)
    /// The minimum version is above the maximum.
    case emptyVersionRange(minimum: TLSVersion, maximum: TLSVersion)

    public var description: String {
        switch self {
        case .unsupportedMinimumVersion(let version):
            "unsupported minimum TLS version \(version): use TLSv1.2 or TLSv1.3 (TLS 1.0 and 1.1 are not offered)"
        case .unsupportedMaximumVersion(let version):
            "unsupported maximum TLS version \(version): use TLSv1.2, TLSv1.3, or none for the system's highest"
        case .emptyVersionRange(let minimum, let maximum):
            "minimum TLS version \(minimum) is above the maximum \(maximum)"
        }
    }
}

/// The DER bytes of the peer's certificate chain, leaf first. Reads the chain only; no trust
/// evaluation, no keychain access.
func certificateChain(of trust: sec_trust_t) -> [[UInt8]] {
    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
    guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] else { return [] }
    return chain.map { [UInt8](SecCertificateCopyData($0) as Data) }
}
