import HTTPCore
import HTTPTestSupport
@testable import NetworkTransport
import Security
import Testing

/// TLS setup errors say what failed and what to check (#0141): identity import failures, and
/// unsupported TLS versions, which are rejected instead of silently clamped. In-memory import
/// only; no keychain access (AGENTS.md).
@Suite struct TLSErrorTests {
    @Test(.timeLimit(.minutes(1)))
    func identityErrorsDescribeTheCauseAndTheFix() throws {
        let material = try TestIdentity.load()
        do {
            _ = try TLSIdentity(pkcs12: material.pkcs12, password: "wrong password")
            Issue.record("a wrong password was accepted")
        } catch {
            #expect(error == .importFailed(status: errSecAuthFailed))
            #expect(error.description.contains("wrong password"))
            #expect(error.description.contains("tls.password"))
        }
        // A DER certificate is not PKCS#12.
        do {
            _ = try TLSIdentity(pkcs12: material.certificateDER, password: TestIdentity.password)
            Issue.record("a certificate was accepted as PKCS#12")
        } catch {
            guard case .importFailed = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(error.description.contains("OSStatus"))
        }
        do {
            _ = try TLSIdentity(pkcs12Path: "/nonexistent/server.p12", password: "x")
            Issue.record("a missing file was accepted")
        } catch {
            #expect(error.description.contains("/nonexistent/server.p12 cannot be read"))
        }
    }

    @Test func everyIdentityErrorHasAnActionableDescription() {
        let cases: [(TLSIdentityError, String)] = [
            (.fileUnreadable(path: "/x.p12"), "permissions"),
            (.importFailed(status: errSecAuthFailed), "wrong password"),
            (.importFailed(status: errSecPkcs12VerifyFailure), "wrong password"),
            (.importFailed(status: errSecPassphraseRequired), "needs a password"),
            (.importFailed(status: errSecDecode), "not a PKCS#12 file"),
            (.importFailed(status: errSecUnknownFormat), "PBE-SHA1-3DES"),
            (.importFailed(status: -1), "PKCS#12 import failed (OSStatus -1)"),
            (.noIdentity, "private key"),
            (.unsupportedKeyType("unknown"), "RSA or EC"),
            (.notUsableForTLS, "private key belongs to the certificate"),
        ]
        for (error, phrase) in cases {
            #expect(error.description.contains(phrase), "\(error): \(error.description)")
            #expect(!error.description.contains("code: -1"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unsupportedVersionsAreRejectedNotClamped() throws {
        let (identity, _) = try quicTestIdentity()
        let tls10 = TLSVersion(rawValue: 0x0301)
        let unknown = TLSVersion(rawValue: 0x7F1C)

        #expect(throws: TLSConfigurationError.unsupportedMinimumVersion(tls10)) {
            _ = try TCPListener(tls: TLSConfiguration(identity: identity, minimumVersion: tls10))
        }
        #expect(throws: TLSConfigurationError.unsupportedMinimumVersion(unknown)) {
            try TLSConfiguration(identity: identity, minimumVersion: unknown).validate()
        }
        #expect(throws: TLSConfigurationError.unsupportedMaximumVersion(tls10)) {
            _ = try TCPListener(tls: TLSConfiguration(identity: identity, maximumVersion: tls10))
        }
        #expect(throws: TLSConfigurationError.emptyVersionRange(minimum: .v1_3, maximum: .v1_2)) {
            _ = try TCPListener(tls: TLSConfiguration(identity: identity, minimumVersion: .v1_3, maximumVersion: .v1_2))
        }
        // The client side checks the same range.
        #expect(throws: TLSConfigurationError.unsupportedMinimumVersion(tls10)) {
            _ = try TLSClientConfiguration(minimumVersion: tls10).makeOptions()
        }
        // Supported ranges pass.
        try TLSConfiguration(identity: identity, minimumVersion: .v1_3).validate()
        try TLSConfiguration(identity: identity, minimumVersion: .v1_2, maximumVersion: .v1_2).validate()

        let description = TLSConfigurationError.unsupportedMinimumVersion(tls10).description
        #expect(description.contains("TLS(0x301)"))
        #expect(description.contains("TLSv1.2 or TLSv1.3"))
        #expect(TLSConfigurationError.emptyVersionRange(minimum: .v1_3, maximum: .v1_2).description
                == "minimum TLS version TLSv1.3 is above the maximum TLSv1.2")
    }
}
