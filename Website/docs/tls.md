# TLS

How PhotonHTTP does TLS: where the handshake runs, what identity formats it loads, how
ALPN picks HTTP/1.1, HTTP/2 or HTTP/3, what you can and cannot tune, how to get and test a
certificate without touching the keychain, and what the identity errors mean. The config keys
and the short HTTPS recipe are in [Running on a Mac](https://photon-http.sstools.co/docs/running-on-a-mac.md#https-with-a-pkcs12-identity);
this guide goes deeper and links there rather than repeating it.

## How TLS is done

TLS runs entirely inside Network.framework; there is no TLS code of our own.

```
PKCS#12 file ─▶ TLSIdentity (SecPKCS12Import, memory only) ─┬─▶ TLSConfiguration ─▶ TCPListener (TLS over TCP: h2, http/1.1)
                                                             └─▶ QUICListener (TLS 1.3 inside QUIC: h3)
```

| Type | File | Role |
|---|---|---|
| `TLSIdentity` | [TLSIdentity.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/NetworkTransport/TLSIdentity.swift) | Certificate and private key imported from PKCS#12 in memory; `certificateDER` is the leaf |
| `TLSIdentityError` | same | `fileUnreadable(path:)`, `importFailed(status:)`, `noIdentity`, `unsupportedKeyType`, `notUsableForTLS`; the description says what to check |
| `TLSIdentityStore` | same | The identity listeners present, replaceable while they run (`replace(with:)`, used by SIGHUP) |
| `TLSConfiguration` | [TLSConfiguration.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/NetworkTransport/TLSConfiguration.swift) | Server TLS settings for a `TCPListener`: identity (or `identityStore`), version range, ALPN, client certificates, handshake timeout |
| `TLSConfigurationError` | same | An unsupported minimum or maximum TLS version, or an empty range |
| `TLSClientConfiguration` | same | Client settings for `TCPTransport.connect(…, tls:)`, used by tests and tools (ALPN, pinned certificate, SNI, versions) |
| `TCPListener` | [TCPListener.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/NetworkTransport/TCPListener.swift) | `TCPListener(configuration:tls:)`: Network.framework TCP with `NWProtocolTLS` |
| `QUICListener` | [QUICListener.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/NetworkTransport/QUICListener.swift) | `QUICListener(configuration:identity:)` or `(configuration:identityStore:)`: QUIC with the same identity |
| `ConnectionInfo` | [Transport.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/HTTPCore/Transport.swift) | `isSecure`, `negotiatedALPN`, `tlsVersion` of each connection, visible to handlers as `context.connection` |
| `TLSNegotiated` | [TLSNegotiated.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/HTTPServer/TLSNegotiated.swift) | Runs HTTP/2 when ALPN chose `h2`, HTTP/1.1 otherwise |

Points that follow from this design:

- **Two listeners can use TLS**: `TCPListener` with a `TLSConfiguration` (HTTPS: HTTP/1.1 and
  HTTP/2) and `QUICListener` (HTTP/3). The BSD-socket listener (`BSDSocketListener`, the
  default cleartext transport) has no TLS. `"transport": "nw"` changes only the cleartext
  listener; HTTPS is always Network.framework.
- **Handshake first, then hand-over.** An accepted TLS connection is handed to the server only
  after its handshake is done, so the negotiated ALPN token and TLS version are final when the
  protocol is chosen. A connection whose handshake fails (cleartext on the TLS port, an ALPN
  offer the server does not accept, a rejected certificate) is closed, logged under the
  `PhotonHTTP` subsystem, category `TLS`, and counted in `TCPListener.failedHandshakeCount`.
  It never reaches the handler.
- **Handshake timeout.** A connection that does not finish the TCP and TLS handshakes within
  `TLSConfiguration.handshakeTimeout` (default 10 s) is reset, so silent clients cannot hold
  the listener's pending-connection slots (`pendingConnectionLimit`, default 64). The executable
  uses the default; it has no config key.
- **No half-close over TLS.** Network.framework sends neither `close_notify` nor a FIN for a
  final-message send on TLS; both go out only when the connection is closed (#0118). Clients
  see the response end normally; only code that relies on a TLS half-close notices.

### No keychain, ever

`TLSIdentity` always calls `SecPKCS12Import` with `kSecImportToMemoryOnly: true`. Without that
option macOS adds the private key to the login keychain, and the first TLS signature then blocks
on a SecurityAgent prompt: the handshake simply hangs. Nothing in the server reads, adds or
changes keychain items or certificate trust settings. Test clients accept the test certificate
by pinning its DER bytes in a verify block (`TLSClientConfiguration.pinnedCertificate`,
`QUICPeerVerification.pinnedCertificate`), again without the keychain. The same rules apply to
anything you add: see [AGENTS.md](https://github.com/brennanMKE/PhotonHTTP/blob/main/AGENTS.md).

### Identity format and password

- **PKCS#12 only.** The identity is one `.p12` file with the private key and the certificate
  chain (leaf first, then intermediates). PEM certificate and key files are not loaded directly;
  convert them (see [Converting PEM to PKCS#12](#converting-pem-to-pkcs12)). The first identity
  in the bundle is used.
- **One identity per server.** The executable loads it at startup and gives the same
  `TLSIdentityStore` to the HTTPS and the HTTP/3 listener; SIGHUP rereads the file and swaps
  the identity in that store (see **Reload** below).
- **Password**: `tls.password` (inline) or `tls.passwordEnv` (the name of an environment
  variable), exactly one of the two. An unset variable stops startup with
  `"tls.passwordEnv": environment variable NAME is not set`. Prefer `passwordEnv` and keep the
  `.p12` at mode `0600`.
- **Paths** are relative to the directory holding the config file
  ([`Root/http-config.tls.json`](https://github.com/brennanMKE/PhotonHTTP/blob/main/Root/http-config.tls.json) points at
  `../.test-identity/server.p12`).

## ALPN and protocol selection

ALPN ([RFC 7301](https://www.rfc-editor.org/rfc/rfc7301)) lets the client and server agree on
the application protocol inside the TLS handshake, so no bytes are sniffed on TLS.

**What the server offers.** A listener's ALPN list is not configured by hand. When `Server`
binds a listener created with the `make` form (`.byteStream(name:) { bind in … }`), it passes
`bind.alpnTokens`:

- for a byte-stream (TCP/TLS) listener, the protocol registry's tokens in registration
  (preference) order: `TLSNegotiated(HTTP2(), fallback: HTTP1())` gives `["h2", "http/1.1"]`,
  `[HTTP1()]` alone gives `["http/1.1"]`;
- for a multiplexed (QUIC) listener, its protocol's own tokens: `HTTP3` gives `["h3"]`.

So the TLS listener offers exactly what the server can speak. Network.framework fixes the TLS
options when the listener is created, which is why the listener is built at bind time.

**What a connection runs** ([ProtocolRegistry.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/HTTPServer/ProtocolRegistry.swift)):

| Client offers | Negotiated | Executable default (`TLSNegotiated(HTTP2(), fallback: HTTP1())`) |
|---|---|---|
| `h2, http/1.1` (browsers, curl) | `h2` | HTTP/2 |
| `http/1.1` (`curl --http1.1`) | `http/1.1` | HTTP/1.1 |
| no ALPN | none (`negotiatedALPN == nil`) | HTTP/1.1, the TLS default |
| only tokens the server does not accept | handshake fails with a `no_application_protocol` alert | nothing; counted as a failed handshake |
| cleartext bytes on the TLS port | handshake fails | nothing |

With `"http2": false` the server registers only HTTP/1.1 and offers only `http/1.1`; a client
that offers only `h2` then fails the handshake.

### `TLSNegotiated`

`TLSNegotiated<Preferred, Fallback>` (HTTPServer, public since #0130) is one
`ConnectionProtocol` that runs `Preferred` when the connection is TLS and negotiated one of
`Preferred.alpnTokens`, and `Fallback` for everything else: `http/1.1`, no ALPN, and cleartext.
Its `alpnTokens` are `Preferred`'s followed by `Fallback`'s without duplicates.

Because it is the only registered protocol, cleartext connections are neither sniffed nor
wrapped in a replay transport: the cleartext port costs exactly what HTTP/1.1 alone costs. This
is what the executable registers unless `"http2": {"cleartext": true}`, in which case it
registers `[HTTP2(), HTTP1()]` and sniffs every cleartext connection for the HTTP/2 preface
(h2c prior knowledge). HTTP/2 over TLS is selected by ALPN only, as
[RFC 9113 §3.3](https://www.rfc-editor.org/rfc/rfc9113#section-3.3) requires; there is no
h2c `Upgrade`.

### HTTP/3: TLS 1.3 inside QUIC

QUIC carries its own TLS 1.3 handshake ([RFC 9001](https://www.rfc-editor.org/rfc/rfc9001));
there is no TLS 1.2 for HTTP/3. `QUICListener` takes the same `TLSIdentity` (or the same
`TLSIdentityStore`, so a reload reaches both listeners) and sets only the identity and the
ALPN list (`h3`) on its security options. `TLSConfiguration`'s version range,
client certificates and handshake timeout apply to the TCP listener only.

Browsers find HTTP/3 through `Alt-Svc`. The `AltSvc` middleware (HTTP3 target) adds
`Alt-Svc: h3=":PORT"; ma=SECONDS` to responses on TLS connections that are not HTTP/3 (it
tests `isSecure && negotiatedALPN != "h3"`); cleartext responses never carry it, because a
client must not trust an alternative learned over an unauthenticated connection. The executable
registers it only when `http3` is on and sets the port once the UDP listener is bound;
`http3.altSvcMaxAge` (default 86400) is the `ma`. Details: [HTTP/3](https://photon-http.sstools.co/docs/http3.md#how-clients-find-it-alt-svc).

### Seeing what was negotiated

Every handler and middleware sees the connection's TLS state in `context.connection`:

```swift
struct ShowTLS: HTTPMiddleware {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        let connection = context.connection
        // isSecure: true for TLS and QUIC. negotiatedALPN: "h2", "http/1.1", "h3" or nil.
        // tlsVersion: .v1_2, .v1_3, or nil on cleartext.
        if connection.isSecure, connection.tlsVersion == .v1_2 { /* … */ }
        return try await next.handle(request, context: context)
    }
}
```

`TLSVersion` prints as `TLSv1.2` / `TLSv1.3`.

## Versions, ciphers and other knobs

| Setting | Swift (`TLSConfiguration`) | `http-config.json` |
|---|---|---|
| Minimum version | `minimumVersion`, default `.v1_2` | none: TLS 1.2 |
| Maximum version | `maximumVersion`, default `nil` (the system's highest, TLS 1.3) | none: TLS 1.3 |
| ALPN | `alpn`, default `["http/1.1"]`; pass `bind.alpnTokens` | from `http2` (`h2` on by default) |
| Client certificates | `clientAuthentication`, default `nil` | none |
| Handshake timeout | `handshakeTimeout`, default 10 s | none |

- **Versions.** Network.framework negotiates the highest version both sides support, so TLS 1.3
  is used whenever the client offers it. To require TLS 1.3 on HTTPS, set
  `minimumVersion: .v1_3` in a custom server. Only `.v1_2` and `.v1_3` are accepted: any other
  `minimumVersion` or `maximumVersion` (TLS 1.0, 1.1, an unknown value) or a minimum above the
  maximum makes `TCPListener.init` throw `TLSConfigurationError` (for example `unsupported
  minimum TLS version TLS(0x301): use TLSv1.2 or TLSv1.3`); nothing is clamped.
  `TLSConfiguration.validate()` runs the same check up front.
- **Ciphers, curves, session resumption, 0-RTT.** The server sets none of these: whatever
  Network.framework's defaults are for the macOS release applies. There is no cipher list to
  tune, and the server does not use 0-RTT (early data) on either TLS or QUIC.
- **SNI and virtual hosts.** The server does not read the SNI name and cannot pick a
  certificate per name: there is one identity. With [virtual hosts](https://photon-http.sstools.co/docs/static-sites.md#virtual-hosts),
  which route by `Host` / `:authority` after the handshake, the certificate must cover every
  name as a subject alternative name (one SAN certificate, or a wildcard). Requests are routed
  by `Host`, whatever SNI the client sent.
- **Client certificates (mutual TLS)** are Swift-only. `TLSConfiguration.ClientAuthentication`
  has `required` (default `true`) and a `verify` closure that receives the client's chain as DER
  (leaf first) and returns whether to accept it. It runs on a Network.framework queue during the
  handshake, so it must not block. A required certificate that is missing fails the handshake
  (with TLS 1.3 the client may see this only as the connection ending after it thinks it is
  connected). The verified chain is not passed on to handlers; `ConnectionInfo` has no
  client-certificate field.
- **Reload.** SIGHUP rereads the identity file (in memory only, like at startup), whether or
  not `tls` changed in the config, so a renewal written over the same path is picked up without
  a restart. New HTTPS and HTTP/3 handshakes present the new certificate; connections already
  open keep the one they negotiated, and no listener is closed or rebound. stderr says which
  happened: `reload: TLS identity PATH reloaded; new HTTPS and HTTP/3 handshakes use the new
  certificate`, `reload: TLS identity PATH unchanged`, or `warning: reload: cannot load TLS
  identity PATH: …; keeping the current TLS certificate` (bad file or password: the old
  certificate stays). `tls.identity` and `tls.password` / `tls.passwordEnv` may change too (a
  `passwordEnv` is read from the environment the server started with); adding or removing
  `tls`, or changing `tls.port`, still needs a restart
  ([reload table](https://photon-http.sstools.co/docs/running-on-a-mac.md#shutdown-restart-and-reload)). If the config file itself
  fails to reload, the identity is not reread either.
  In a custom server, build listeners from one `TLSIdentityStore` (`TLSConfiguration(identityStore:)`,
  `QUICListener(configuration:identityStore:)`) and call `store.replace(with:)`: the listeners
  ask the store for the identity on every handshake (`sec_protocol_options_set_challenge_block`),
  because Network.framework fixes a listener's options when it is created.

### HSTS

The server does not send `Strict-Transport-Security` itself. Add it with a small middleware
that marks only TLS responses (a browser ignores the header over cleartext anyway):

```swift
import HTTPCore

struct HSTS: HTTPMiddleware {
    // StaticString: appended without building a String per response.
    static let name: StaticString = "strict-transport-security"
    static let value: StaticString = "max-age=31536000"

    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        var response = try await next.handle(request, context: context)
        if context.connection.isSecure {
            response.headers.append(name: Self.name, value: Self.value)
        }
        return response
    }
}
```

Put it early in the chain (before `StaticFiles` and the router). The shipped executable has no
key for it; a server built from `ConfigFile` can wrap the built chain. Turn HSTS on only once
HTTPS works for every name the site serves (and every subdomain, if you add
`includeSubDomains`): browsers remember it for `max-age` seconds. If the site is reached through a TLS-terminating proxy and
PhotonHTTP itself speaks cleartext, `isSecure` is false; send the header from the proxy.

## Getting a certificate

### The test identity

```bash
scripts/make-test-identity.sh            # creates it if missing (idempotent)
scripts/make-test-identity.sh --force    # replaces it
scripts/make-test-identity.sh --name second   # a second identity in .test-identity/second/
```

The second identity (`TestIdentity.load(name: "second")`) has its own key and certificate;
the certificate-reload tests (#0140) swap between the two.

It writes the gitignored `.test-identity/` folder at the repository root:

| File | What |
|---|---|
| `server.p12` | PKCS#12 identity, password `sws-test-password` |
| `cert.pem` | The certificate (PEM) |
| `cert.der` | The certificate (DER), for pinning in test clients |
| `key.pem` | The private key, unencrypted |

The certificate is self-signed, ECDSA P-256, valid 825 days, `CN=localhost` with SANs
`DNS:localhost`, `IP:127.0.0.1`, `IP:::1`, and `extendedKeyUsage=serverAuth`. The script only
runs `openssl` on files (Homebrew's `/opt/homebrew/bin/openssl` when installed; override with
`OPENSSL=…`). Tests call `TestIdentity.load()` (HTTPTestSupport), which runs the script when
the identity is missing. A local CA for browser testing is still open work (#0072, #0062,
#0105); until then browsers reject this certificate unless you trust it by hand.

### Let's Encrypt

See [A real certificate (Let's Encrypt)](https://photon-http.sstools.co/docs/running-on-a-mac.md#a-real-certificate-lets-encrypt):
any ACME client that writes PEM files, HTTP-01 through `/.well-known/` on your site's root,
then the conversion below and a SIGHUP on renewal (write the new `.p12` over the old path).

### Tailscale

On a tailnet with HTTPS certificates enabled, `tailscale cert` fetches a Let's Encrypt
certificate for the machine's `*.ts.net` name and writes PEM files:

```bash
tailscale cert mymac.example-tailnet.ts.net
# writes mymac.example-tailnet.ts.net.crt and .key in the current directory
```

Convert them as below. `tailscale cert` depends on the Tailscale control plane and Let's
Encrypt, and it can fail; it has returned an HTTP 500 for us. Retry later, and keep the
previous `.p12` in place until a new one is made. The name is reachable only on your tailnet,
so the server can bind the Tailscale address or stay on loopback behind `tailscale serve`.

### Converting PEM to PKCS#12

```bash
export SWS_P12_PASSWORD='a long random password'
openssl pkcs12 -export \
  -inkey example.key -in example.crt \
  -out certs/example.p12 -passout env:SWS_P12_PASSWORD \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
chmod 600 certs/example.p12
```

- `-in` must be the full chain, leaf first. If the intermediates are in a separate file, add
  `-certfile chain.pem`.
- The legacy algorithms matter: `SecPKCS12Import` does not reliably accept OpenSSL 3's default
  AES-256/PBKDF2 encryption, and fails with an import error (see
  [Troubleshooting](#troubleshooting)). The test-identity script uses the same flags.
- This only writes a file. Do not double-click the `.p12` or import it with Keychain Access:
  the server does not need it in a keychain, and importing it is exactly what the server avoids.

Check a bundle without the server:

```bash
openssl pkcs12 -info -in certs/example.p12 -passin env:SWS_P12_PASSWORD -nokeys | openssl x509 -noout -subject -ext subjectAltName -enddate
```

## Testing safely

Start the server on loopback (as `Root/http-config.tls.json` does) and test with clients that
accept the certificate per command, never by trusting it system-wide:

```bash
scripts/make-test-identity.sh
.build/release/photon --config Root/http-config.tls.json

# Verify against the test certificate (OpenSSL treats the self-signed cert as its own anchor;
# `openssl verify -CAfile .test-identity/cert.pem .test-identity/cert.pem` prints OK)
/opt/homebrew/opt/curl/bin/curl --cacert .test-identity/cert.pem https://localhost:8443/
# Or skip verification entirely (any curl)
curl -k https://127.0.0.1:8443/                       # HTTP/2 via ALPN
curl -k --http1.1 -sv https://127.0.0.1:8443/ 2>&1 | grep -i 'alpn\|SSL connection'
/opt/homebrew/opt/curl/bin/curl -k --http3-only https://127.0.0.1:8443/

# Look at the handshake: ALPN, version, certificate
openssl s_client -connect 127.0.0.1:8443 -servername localhost -alpn h2,http/1.1 </dev/null 2>/dev/null \
  | grep -E 'ALPN|Protocol|subject='
openssl s_client -connect 127.0.0.1:8443 -tls1_2 -alpn http/1.1 </dev/null    # force TLS 1.2
```

`--cacert` needs the name to match a SAN: use `localhost` or `127.0.0.1`, not the Mac's
hostname. The system `/usr/bin/curl` is built on SecureTransport; if it rejects `--cacert`,
use Homebrew curl or `-k`. Run servers you start for tests through `scripts/guarded.sh -t SECS
-- …` so they are killed on time, and stop them afterwards.

**Do not add the test certificate to a keychain or mark it trusted.** `security
add-trusted-cert`, Keychain Access, or double-clicking the certificate changes trust settings,
which raises an authorization prompt and leaves a trusted self-signed root on the machine
(its private key sits unencrypted in `.test-identity/key.pem`). Tests never need it: Swift
clients pin `cert.der`, curl uses `--cacert` or `-k`. Trusting a local CA for browser checks
is a deliberate manual step for the owner, tracked in #0072.

Other macOS prompts to keep out of the way:

| Prompt | Cause | Avoid it |
|---|---|---|
| Keychain "wants to use your confidential information" / a hung handshake | `SecPKCS12Import` without `kSecImportToMemoryOnly`, keychain lookups | Load identities only with `TLSIdentity` |
| Certificate trust settings | Trusting a certificate | Pin, `--cacert` or `-k` |
| "Accept incoming network connections?" | A fresh unsigned binary listening on a non-loopback address | Bind `127.0.0.1` / `::1` for testing ([firewall](https://photon-http.sstools.co/docs/running-on-a-mac.md#binding-to-all-interfaces-and-the-firewall-prompt)) |
| Local Network | Connecting to LAN addresses | Test over loopback |

## Using TLS from a custom server

A server package (see [Choosing components](https://photon-http.sstools.co/docs/choosing-components.md#a-custom-server-package))
with cleartext HTTP/1.1 and HTTPS with HTTP/2, in the style of
[`Examples/custom-server`](https://github.com/brennanMKE/PhotonHTTP/blob/main/Examples/custom-server/Sources/MySite/MySite.swift):

```swift
import Foundation   // ProcessInfo
import HTTP1
import HTTP2
import HTTPCore
import HTTPServer
import NetworkTransport
import StaticFiles

@main
struct SecureSite {
    static func main() async throws {
        guard let password = ProcessInfo.processInfo.environment["SWS_P12_PASSWORD"] else {
            fatalError("set SWS_P12_PASSWORD")
        }
        // In memory only: SecPKCS12Import with kSecImportToMemoryOnly. Throws TLSIdentityError.
        let identity = try TLSIdentity(pkcs12Path: "certs/site.p12", password: password)
        let files = try StaticFiles(root: "Public")

        let listeners: [ServerListener] = [
            .byteStream(try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: 8080)), name: "http"),
            .byteStream(name: "https") { bind in
                // bind.alpnTokens is ["h2", "http/1.1"] for the protocols below.
                try TCPListener(configuration: .init(host: "127.0.0.1", port: 8443),
                                tls: TLSConfiguration(identity: identity, minimumVersion: .v1_2,
                                                      alpn: bind.alpnTokens))
            },
        ]
        // HTTP/2 when TLS negotiates h2; HTTP/1.1 for http/1.1, no ALPN, and cleartext.
        let server = Server(listeners: listeners, protocols: [TLSNegotiated(HTTP2(), fallback: HTTP1())]) {
            HSTS()        // the middleware above
            files
        }
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.run() }
            group.addTask {
                for address in try await server.waitUntilRunning() { print("listening \(address)") }
            }
        }
    }
}
```

`ProcessInfo` needs `import Foundation` (startup only, not the request path). Add SIGINT and
SIGTERM handling as in the example (`server.requestShutdown()`). For HTTP/3 add a
`.multiplexed(name: "h3", protocol: HTTP3())` listener with the same identity and the `AltSvc`
middleware: see [HTTPS, HTTP/2 and HTTP/3 in Swift](https://photon-http.sstools.co/docs/choosing-components.md#https-http2-and-http3-in-swift)
and [HTTP/3 in a custom server](https://photon-http.sstools.co/docs/http3.md#in-a-custom-server). Use `0.0.0.0` only when the
server must be reachable from other machines.

## Troubleshooting

### Startup errors

The executable loads the identity before binding and exits with status 1 on failure. Messages
come from `TLSIdentityError`'s description and the config parser:

| Message | Meaning | Fix |
|---|---|---|
| `cannot load TLS identity PATH: the file PATH cannot be read; …` | `fileUnreadable`: missing file or no permission | Check the path (relative to the config file) and its mode |
| `cannot load TLS identity PATH: wrong password (OSStatus -25293); …` | `importFailed(-25293)` (or `-25264`, MAC check failed) | Fix `password` / the `passwordEnv` variable's value |
| `cannot load TLS identity PATH: not a PKCS#12 file Security.framework can read (OSStatus N); …` | `SecPKCS12Import` rejected the file: not PKCS#12 (a PEM file, say) or an encryption it does not accept | Re-export with `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1` |
| `cannot load TLS identity PATH: PKCS#12 import failed (OSStatus N); …` | Another `SecPKCS12Import` failure | Re-export the file as above |
| `cannot load TLS identity PATH: the file holds no certificate with its private key; …` | `noIdentity`: the bundle has certificates but no private key | Export with `-inkey` |
| `cannot load TLS identity PATH: the certificate's key type (…) is not supported; …` | `unsupportedKeyType`: not RSA or EC (Ed25519, DSA) | Issue an RSA or EC P-256/P-384 certificate |
| `cannot load TLS identity PATH: Network.framework cannot use the certificate and key as a TLS identity; …` | `notUsableForTLS`: `sec_identity_create` failed | Check that the key belongs to the certificate |
| `"tls.passwordEnv": environment variable NAME is not set` | The variable is missing from the server's environment | Set it (under launchd: `EnvironmentVariables`) |
| `config file …: "tls.identity" must be set to a PKCS#12 file` | `tls` without `identity` | Add it |
| `config file …: "tls.password" or "tls.passwordEnv" must be set` / `must have "password" or "passwordEnv", not both` | Password keys missing or doubled | Use exactly one |
| `"tls.port" 8080 is the cleartext port too; both are TCP` | Same TCP port twice | Pick another `tls.port` (`http3.port` may equal it: UDP) |
| `"http3" needs "tls": HTTP/3 uses the TLS identity` | `http3` without `tls` | Add `tls` |
| `cannot serve on HOST:PORTS: …` | Binding failed (port in use, `EACCES` below 1024 on a specific address) | See [ports 80 and 443](https://photon-http.sstools.co/docs/running-on-a-mac.md#ports-80-and-443-without-root) |

### Handshake failures

The server logs each failed handshake at info level (`handshake with ADDRESS failed: …;
closing`, or `TLS handshake with ADDRESS timed out; closing`). Watch them with:

```bash
log stream --level info --predicate 'subsystem == "PhotonHTTP" AND category == "TLS"'
```

| Symptom | Likely cause |
|---|---|
| curl: `SSL certificate problem: self signed certificate` / browser warning | Expected for the test identity: use `--cacert`, `-k`, or pin |
| curl: `no alternative certificate subject name matches` | The name is not a SAN of the certificate (for the test identity: only `localhost`, `127.0.0.1`, `::1`) |
| Client: `no application protocol` alert | It offered only ALPN tokens the server does not have, e.g. `h2` alone with `"http2": false` |
| `wrong version number` / garbage | A cleartext client on the TLS port, or `https://` against the cleartext port |
| Client reports `protocol version` alert | It cannot do TLS 1.2 or later (or your custom server set `minimumVersion: .v1_3`) |
| Handshake hangs, then the server resets it after 10 s | The client stalls; or, in your own code, a keychain prompt from importing without `kSecImportToMemoryOnly` (stop: see [AGENTS.md](https://github.com/brennanMKE/PhotonHTTP/blob/main/AGENTS.md)) |
| Browser connects but uses `http/1.1` | HTTP/2 off, or a proxy in between does not offer `h2` |
| Browser never uses h3 | No `Alt-Svc` on HTTPS responses (HTTP/3 off), UDP port blocked, or the certificate is not trusted by the browser (#0105) |

### ALPN mismatches

`openssl s_client … -alpn h2,http/1.1` should print `ALPN protocol: h2` with HTTP/2 on, and
`No ALPN negotiated` when the client offered none (the server then runs HTTP/1.1). If a custom
server answers h2 clients with HTTP/1.1 bytes or closes them, check that the TLS listener is
built with `bind.alpnTokens` (a hand-written list can offer `h2` while no HTTP/2 protocol is
registered, or the reverse) and that `HTTP2` is registered inside `TLSNegotiated` or before
`HTTP1`.

## Standards

- [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446): TLS 1.3 (and the version numbers in
  `TLSVersion`)
- [RFC 5246](https://www.rfc-editor.org/rfc/rfc5246): TLS 1.2
- [RFC 7301](https://www.rfc-editor.org/rfc/rfc7301): TLS ALPN (`http/1.1`, `h2`; §3.2 the
  `no_application_protocol` alert)
- [RFC 9113 §3.3](https://www.rfc-editor.org/rfc/rfc9113#section-3.3): starting HTTP/2 for
  `https` URIs via ALPN `h2`
- [RFC 9001](https://www.rfc-editor.org/rfc/rfc9001): Using TLS to secure QUIC
- [RFC 9114 §3.1](https://www.rfc-editor.org/rfc/rfc9114#section-3.1) and
  [RFC 7838](https://www.rfc-editor.org/rfc/rfc7838): HTTP/3 discovery with `Alt-Svc`
- [RFC 6797](https://www.rfc-editor.org/rfc/rfc6797): HTTP Strict Transport Security
- [RFC 7292](https://www.rfc-editor.org/rfc/rfc7292): PKCS#12
