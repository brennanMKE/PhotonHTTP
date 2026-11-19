# HTTP/3

PhotonHTTP serves HTTP/3 (RFC 9114) over QUIC. It has no QUIC stack of its own: QUIC,
TLS 1.3, loss recovery and congestion control come from Network.framework (`NWProtocolQUIC`).
HTTP/3 framing, stream handling and QPACK header compression are written in Swift in the
`HTTP3` and `QPACK` targets. The QUIC listener runs next to the TCP listeners in the same
`Server`, and HTTPS responses tell clients where to find it with an `Alt-Svc` header.

Why Network.framework: implementing QUIC ourselves would need a TLS 1.3 server that exposes
its handshake secrets (no public API does), packet protection, RFC 9002 recovery, migration
and anti-amplification. ROADMAP §6 chose Option A (Network.framework) after a spike;
Option B (our own QUIC) was rejected. The spike's findings are in
[quic-spike.md](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/spikes/quic-spike.md), and the adapter's in
[notes/nw-transport.md](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/notes/nw-transport.md).

## How it fits together

| Layer | Where | Role |
|---|---|---|
| QUIC listener | `QUICListener` ([NetworkTransport](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/NetworkTransport/QUICListener.swift)) | `NWListener` with `newConnectionGroupHandler`: one `NWConnectionGroup`, so one `QUICConnection`, per QUIC connection. Binds UDP with `requiredLocalEndpoint` |
| QUIC connection | `QUICConnection`, `QUICStreamTransport` | A `MultiplexedTransport`: inbound streams as a demand-driven sequence, our own unidirectional streams, FIN, RESET_STREAM / STOP_SENDING codes, MAX_STREAMS credit |
| QUIC options | `QUICConfiguration` ([source](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/NetworkTransport/QUICConfiguration.swift)) | ALPN (`h3`), flow-control windows, stream limits, idle timeout |
| HTTP/3 | `HTTP3`, `H3Configuration` ([Sources/HTTP3](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/HTTP3/HTTP3.swift)) | Control and QPACK streams, SETTINGS, request streams to `HTTPHandler`, GOAWAY, limits |
| QPACK | `QPACKEncoder`, `QPACKDecoder`, `QPACKDynamicDecoder` ([Sources/QPACK](https://github.com/brennanMKE/PhotonHTTP/tree/main/Sources/QPACK)) | Static table, Huffman, the decoder side of the dynamic table |
| Discovery | `AltSvc` middleware ([AltSvc.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/HTTP3/AltSvc.swift)) | `Alt-Svc: h3=":PORT"; ma=SECONDS` on HTTPS responses |

`HTTP3` is a `MultiplexedConnectionProtocol`; a `ServerListener.multiplexed(...)` entry
pairs it with the QUIC listener. The handler chain is the same one HTTP/1.1 and HTTP/2 use,
so every component works over HTTP/3 unchanged. Requests report `version` `.http3` and
the connection's negotiated ALPN is `h3`.

## Requirements

- **A TLS identity.** QUIC always uses TLS 1.3, so HTTP/3 needs the same PKCS#12 identity as
  HTTPS, loaded in memory only. In `http-config.json`, `http3` without `tls` fails at startup
  (`"http3" needs "tls"`). See the TLS guide, [tls.md](https://photon-http.sstools.co/docs/tls.md), and
  [HTTPS with a PKCS#12 identity](https://photon-http.sstools.co/docs/running-on-a-mac.md#https-with-a-pkcs12-identity).
- **A UDP port.** By default the TLS port number, over UDP (TCP and UDP ports do not clash;
  the spike confirmed both listen on one number). Any firewall or router in front of the Mac
  must pass UDP as well as TCP.
- **macOS 15 or later**, like the rest of the package. The executable must be built with the
  `HTTP3` package trait, which is on by default; without it an `http3` key fails at startup
  ("this build has no HTTP/3"). See [package traits](https://photon-http.sstools.co/docs/choosing-components.md#package-traits-for-the-executable).

Binding rules are the same as for TCP: `QUICListener` defaults to `127.0.0.1`, and loopback
never triggers the macOS firewall prompt. Binding `0.0.0.0` or `::` with an unsigned, freshly
built binary can ([the firewall prompt](https://photon-http.sstools.co/docs/running-on-a-mac.md#binding-to-all-interfaces-and-the-firewall-prompt)).
Tests and local checks therefore bind loopback and port 0.

## Turning it on in `http-config.json`

```json
{
  "host": "127.0.0.1",
  "port": 8080,
  "root": "Public",
  "tls": { "identity": "certs/server.p12", "passwordEnv": "SWS_P12_PASSWORD", "port": 8443 },
  "http3": true
}
```

`"http3": true` uses every default. The object form:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `http3.enabled` | bool | `true` | `false` turns it off (as do `"http3": false` and `null`) |
| `http3.port` | integer 0–65535 or `null` | TLS port number | UDP port. `null` or absent takes the TLS listener's bound port, including one picked when `tls.port` is 0 |
| `http3.altSvcMaxAge` | integer seconds | `86400` | `ma` of the `Alt-Svc` header |
| `http3.qpackMaxTableCapacity` | integer 0–1048576 | `0` | QPACK dynamic table offered to clients; `0` decodes with the static table only |
| `http3.qpackBlockedStreams` | integer 0–1000 | `0` | Request streams that may wait for QPACK inserts at once (only with a table) |

The full config reference is in [Running on a Mac](https://photon-http.sstools.co/docs/running-on-a-mac.md#tls-http2-and-http3).
`http3` is a restart-only key: `SIGHUP` reports a change to it and ignores it.

What else the executable sets (`makeListeners` in
[ServerMain.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/Photon/ServerMain.swift)):

- Listeners bind in order cleartext, TLS, QUIC, and print `listening HOST:PORT (h3)`.
- The QUIC listener offers ALPN `h3` and uses the default `QUICConfiguration`.
- `AltSvc` is the outermost element of the chain (the [chain table](https://photon-http.sstools.co/docs/overview.md#the-chain-the-executable-builds)),
  added only when `http3` is on, and rendered once the UDP port is bound.
- `H3Configuration` keeps its defaults (tables below) except the two QPACK keys and
  `timeouts.closeLinger`, which is set to `drainTimeout` (at least 1 s; 30 s when
  `drainTimeout` is `null`).
- The general `maxBodySize` and `timeouts` keys are **not** applied to HTTP/3. HTTP/3 keeps
  its own 10 MiB body limit and its own timeouts, whatever those keys say.
- `maxConnections` is shared by every listener, so QUIC connections count against it too.

## How clients find it: Alt-Svc

Browsers do not try QUIC first. They connect over TCP and TLS, see

```
alt-svc: h3=":8443"; ma=86400
```

on the response, and use HTTP/3 for that origin for the next `ma` seconds (RFC 7838,
RFC 9114 §3.1.1). The `AltSvc` middleware adds the header only to responses on TLS
connections that are not HTTP/3: HTTPS over HTTP/1.1 or HTTP/2. Cleartext responses never
carry it (a client must not take an alternative for an `https` origin from an
unauthenticated connection), and HTTP/3 responses do not repeat it. It is added to every
such response, error pages included, at the cost of one atomic load and a copy of the
pre-rendered bytes.

```swift
let altSvc = AltSvc(port: 8443, maxAge: 86_400)  // port known up front
let altSvc = AltSvc(maxAge: 86_400)              // or: nothing until advertise(port:)
altSvc.advertise(port: boundPort)                 // the first call wins
```

## Streams

### Connection setup and SETTINGS

For each connection the server opens three unidirectional streams: its control stream
(type `0x00`, starting with SETTINGS), and its QPACK encoder (`0x02`) and decoder (`0x03`)
streams. They stay open for the life of the connection. The SETTINGS it sends:

| Setting | Value |
|---|---|
| `SETTINGS_QPACK_MAX_TABLE_CAPACITY` | `qpackMaxTableCapacity` (default 0) |
| `SETTINGS_MAX_FIELD_SECTION_SIZE` | `maxFieldSectionSize` (default 16,384) |
| `SETTINGS_QPACK_BLOCKED_STREAMS` | `qpackBlockedStreams` when the table is on, else 0 |
| `SETTINGS_ENABLE_CONNECT_PROTOCOL` | `1`, only when extended CONNECT is enabled (below); otherwise not sent |

From the client, the server accepts exactly one control stream (SETTINGS first, once), one
QPACK encoder and one decoder stream. A second one of any of them, or a client push stream,
is `H3_STREAM_CREATION_ERROR`; a missing first SETTINGS is `H3_MISSING_SETTINGS`; one of them
closing is `H3_CLOSED_CRITICAL_STREAM`. HTTP/2-only frame types and setting identifiers are
errors as RFC 9114 requires. Reserved (GREASE) and unknown unidirectional streams are refused
with STOP_SENDING `H3_STREAM_CREATION_ERROR`; unknown frames are skipped without buffering.
The peer's `SETTINGS_MAX_FIELD_SECTION_SIZE` is honoured: a response head larger than it is
replaced by a bare `500`.

The server never pushes. It tracks the client's `MAX_PUSH_ID` only to validate
`CANCEL_PUSH`.

### Request streams

Each client-initiated bidirectional stream is one request: HEADERS, optional DATA, optional
trailers. The handler runs as a child task of the stream's task, next to a body reader that
feeds `request.body` under backpressure (the reader stops reading the QUIC stream while
`bodyQueueCapacity` chunks wait). Request trailers reach `HTTPRequestBody.trailers`.
`priority` request fields and `PRIORITY_UPDATE` frames (RFC 9218) are applied (see
[Known limitations](#known-limitations) for what they can change).

Every failure is signalled as the `H3Failure` table in
[H3Failure.swift](https://github.com/brennanMKE/PhotonHTTP/blob/main/Sources/HTTP3/H3Failure.swift) says: a stream error resets one
stream with a code; a connection error closes QUIC with a code. Cancellation works both ways
(#0104): a client RESET_STREAM or STOP_SENDING cancels the handler's task (even while it is
still computing, since `QUICStreamTransport` watches for peer aborts), and a handler that is
cancelled or throws `CancellationError` resets its stream with `H3_REQUEST_CANCELLED`. A
response body that fails after its head was sent is reset with `H3_INTERNAL_ERROR`, so a
truncated response never looks complete.

### GOAWAY and graceful shutdown

When the server drains (`requestShutdown()`, or SIGINT/SIGTERM in the executable) or a
connection has had no open request for `timeouts.idle`:

1. The server sends GOAWAY with the next unprocessed client stream ID. With
   `timeouts.goawayGrace` set, it first sends GOAWAY with the largest possible ID
   (2^62 − 4), waits the grace period, then sends the final one (RFC 9114 §5.2).
2. Streams at or above that ID are reset with `H3_REQUEST_REJECTED` (safe to retry);
   requests below it run to completion.
3. When the last one finishes, or `timeouts.drain` passes, the server waits
   `timeouts.closeLinger` (or until the client closes) so the client can read the GOAWAY and
   the last responses, then closes with `H3_NO_ERROR`.

The server's own `drainTimeout` still bounds the whole drain: at that deadline every
connection is cancelled. See [Lifecycle](https://photon-http.sstools.co/docs/overview.md#lifecycle).

### Extended CONNECT and WebSockets (RFC 9220)

WebSockets run over HTTP/3 with extended CONNECT. `HTTP3` advertises
`SETTINGS_ENABLE_CONNECT_PROTOCOL = 1` when the handler chain contains an
`ExtendedConnectProvider`, which `WebSocketUpgrade` is, and so is a `ReverseProxy` with a
`websocket` mount. `H3Configuration.enableConnectProtocol = true` forces it on. Without
it, a request carrying `:protocol` is malformed.

An extended CONNECT reaches the handler like any request, with `request.connectProtocol`
set. A `2xx` response with a `.tunnel` body keeps the request stream open as a byte stream:
DATA payloads in, one DATA frame per send out, FIN as end of stream. Request body limits do
not apply to a tunnel; the send timeout does. The same `WebSocketUpgrade` endpoint serves
HTTP/1.1, HTTP/2 and HTTP/3; see the [WebSockets guide](https://photon-http.sstools.co/docs/websockets.md).

## QPACK

**Responses** are encoded with the static table only (RFC 9204 Appendix A, 99 entries):
an indexed line when the table has the name and value, a name reference when it has the
name, a literal otherwise. Strings are Huffman-coded when that is shorter. `authorization`,
`cookie` and `set-cookie` are always literals with the never-indexed bit. The encoder never
inserts into a dynamic table, so the server's encoder stream carries only its type byte.

**Requests** are decoded with the static table by default. The server advertises
`SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0`, any dynamic reference is
`QPACK_DECOMPRESSION_FAILED`, and nothing is shared between request streams.

**The dynamic table** (decoder side, #0106) is off by default and turned on by a non-zero
capacity:

```json
"http3": { "qpackMaxTableCapacity": 4096, "qpackBlockedStreams": 16 }
```

```swift
H3Configuration(qpackMaxTableCapacity: 4_096, qpackBlockedStreams: 16)
```

With it on, the connection keeps a table (a ring over one byte arena of twice the capacity,
sized once) behind a `Mutex`, reads the client's encoder stream (Set Dynamic Table Capacity,
Insert With Name Reference, Insert With Literal Name, Duplicate), and sends Section
Acknowledgment, Stream Cancellation and Insert Count Increment on its decoder stream. A
request whose field section refers to inserts that have not arrived yet waits for them; that
wait counts against `timeouts.header`, and at most `qpackBlockedStreams` requests may wait
(one more is `QPACK_DECOMPRESSION_FAILED`). Homebrew curl (nghttp3) uses the table when it is
offered (`H3CurlTests.curlUsesTheQPACKDynamicTable`).

It is off by default because it adds connection-shared state, a lock per field section and
blocked streams. Decoding a dynamic section serializes head decoding across the streams of
one connection.

## Limits, timeouts and abuse defences

[HTTP2.md](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/HTTP2.md#http3-default-limits-0102) ("HTTP/3 default limits" and "HTTP/3
abuse limits") is the authoritative list, with the wire code for each. In summary, for a
custom server (`H3Configuration`, `H3Timeouts`, `H3AbuseLimits`); in the executable only the
two QPACK values and `closeLinger` are configurable.

### `H3Configuration`

| Setting | Default | When it is exceeded |
|---|---|---|
| `maxConcurrentRequestStreams` | 100 | QUIC MAX_STREAMS is raised to this at the start and by one per finished request; a stream beyond it is reset `H3_REQUEST_REJECTED` |
| `maxFieldSectionSize` | 16,384 | `431` when the pseudo-header fields make a valid request, else `H3_MESSAGE_ERROR` |
| `maxEncodedFieldSectionLength` | 65,536 | One HEADERS frame (the only frame buffered whole): connection error `H3_EXCESSIVE_LOAD` |
| `maxRequestBodySize` | 10 MiB | `413` (declared `content-length` before the handler runs; an undeclared body when it grows past) |
| `maxUnreadBodySize` | 64 KiB | Unread request body discarded after the response; past it, STOP_SENDING `H3_NO_ERROR` |
| `bodyQueueCapacity` | 4 chunks | Read-ahead between the stream and the handler |
| `receiveSize` | 16 KiB | Most bytes asked for per stream receive |
| `qpackMaxTableCapacity` | 0 | Dynamic table off; at most 1 MiB |
| `qpackBlockedStreams` | 0 | One more blocked stream is `QPACK_DECOMPRESSION_FAILED` |
| `enableConnectProtocol` | `false` | Turned on automatically by an `ExtendedConnectProvider` in the chain |

### `H3Timeouts`

Handler time itself is never limited. `nil` turns a limit off.

| Timeout | Default | Runs while | When it passes |
|---|---|---|---|
| `header` | 10 s | A request stream has not delivered its HEADERS (not renewed by progress) | RESET_STREAM `H3_REQUEST_REJECTED` |
| `idle` | 30 s | The connection has no open request | GOAWAY, then close `H3_NO_ERROR` |
| `body` | 30 s | The handler waits for request body bytes (renewed per chunk) | `408`, or `H3_REQUEST_CANCELLED` once the response started |
| `send` | 30 s | One response send waits (slow reader or send budget) | RESET_STREAM `H3_REQUEST_CANCELLED` |
| `unreadBody` | 2 s | Unread body is discarded after the response | STOP_SENDING `H3_NO_ERROR` |
| `drain` | off | Requests below the final GOAWAY finish | Close `H3_NO_ERROR` (off: the server's drain deadline decides) |
| `goawayGrace` | off | Between the provisional and the final GOAWAY | The final GOAWAY |
| `closeLinger` | 1 s (executable: `drainTimeout`) | After the drain, until the client closes | Close `H3_NO_ERROR` |

### `H3AbuseLimits`

Counted per connection in a fixed window (`window`, 10 s) that starts at the first event.
Each `H3_EXCESSIVE_LOAD` below closes the connection. `nil` turns a limit off;
`H3AbuseLimits.disabled` turns them all off.

| Limit | Default | Counts |
|---|---|---|
| `maxAbortedRequestsPerWindow` | 100 | Rapid reset: request streams the client resets or stops before the response completes, or ends without a request |
| `maxIgnoredUniStreamsPerWindow` | 16 | Reserved and unknown unidirectional streams |
| `maxQPACKInstructionsPerWindow` | 1,000 | Instructions on the client's QPACK encoder and decoder streams |
| `maxControlFramesPerWindow` | 1,000 | Control-stream frames, unknown ones included |
| `maxUnknownRequestFramesPerWindow` | 1,000 | Reserved and unknown frames on request streams |
| `maxUnknownFrameLength` | 16 KiB | Declared length of one unknown frame, any stream (skipped, never buffered) |
| `maxConnectionSendBuffer` | 4 MiB | Response bytes in sends not yet completed, across the connection; further sends wait, and `timeouts.send` resets stalled streams |
| `maxIdleConnections` | 1,000 | Connections of one `HTTP3` value with no open request; the longest-idle one is shut down gracefully |

A QPACK decoder-stream backlog over 64 KiB (the client does not read it) is also
`H3_EXCESSIVE_LOAD`.

### QUIC transport (`QUICConfiguration`, `QUICListener.Configuration`)

These bound what a client can make Network.framework buffer.

| Setting | Default | Meaning |
|---|---|---|
| `maxStreamsBidirectional` | 100 | `initial_max_streams_bidi`; replenished by the adapter as streams finish (Network.framework does not) |
| `maxStreamsUnidirectional` | 8 | `initial_max_streams_uni` (HTTP/3 needs at least 3) |
| `initialMaxData` | 4 MiB | Connection receive window |
| `initialMaxStreamDataBidirectionalRemote` / `Local` | 256 KiB | Per-stream receive window |
| `initialMaxStreamDataUnidirectional` | 64 KiB | Per unidirectional stream |
| `idleTimeoutMilliseconds` | 30,000 | QUIC `max_idle_timeout` |
| `sendChunkSize` | 64 KiB | A larger send is split; each chunk waits for Network.framework to accept it |
| `pendingStreamLimit` | streams + 2 | Inbound streams held before HTTP/3 takes them; more are reset `H3_REQUEST_REJECTED` |
| `pendingConnectionLimit` (listener) | 64 | Accepted connections not yet taken; more are closed at once |

## In a custom server

Add the `HTTP3` product (it brings `QPACK`) next to `HTTPServer` and `NetworkTransport` in
your package, as in [A custom server package](https://photon-http.sstools.co/docs/choosing-components.md#a-custom-server-package).
This server serves HTTPS (HTTP/1.1 and HTTP/2 by ALPN) and HTTP/3 on the same port number,
with a tuned `H3Configuration`:

```swift
import HTTP1
import HTTP2
import HTTP3
import HTTPCore
import HTTPServer
import NetworkTransport
import StaticFiles

@main
struct MySite {
    static func main() async throws {
        // PKCS#12 loaded in memory only; never the keychain.
        let identity = try TLSIdentity(pkcs12Path: ".test-identity/server.p12", password: "sws-test-password")
        let files = try StaticFiles(root: "Public")
        let altSvc = AltSvc(maxAge: 3_600)   // adds nothing until advertise(port:)

        var h3 = H3Configuration(maxRequestBodySize: 1 << 20,
                                 qpackMaxTableCapacity: 4_096, qpackBlockedStreams: 16)
        h3.timeouts.idle = .seconds(60)
        h3.timeouts.drain = .seconds(5)

        let listeners: [ServerListener] = [
            .byteStream(name: "https") { bind in
                try TCPListener(configuration: .init(host: "127.0.0.1", port: 8443),
                                tls: TLSConfiguration(identity: identity, alpn: bind.alpnTokens))
            },
            .multiplexed(name: "h3", protocol: HTTP3(configuration: h3)) { bind in
                // The HTTPS port number, over UDP.
                try QUICListener(configuration: .init(host: "127.0.0.1", port: bind.boundAddresses[0].port,
                                                      quic: QUICConfiguration(alpn: bind.alpnTokens)),
                                 identity: identity)
            },
        ]
        let server = Server(listeners: listeners, protocols: [TLSNegotiated(HTTP2(), fallback: HTTP1())]) {
            altSvc
            files
        }
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.run() }
            group.addTask {
                let addresses = try await server.waitUntilRunning()   // in listener order
                altSvc.advertise(port: addresses[1].port)
                for address in addresses { print("listening \(address)") }
            }
        }
    }
}
```

This snippet type-checks against this checkout (2026-11-13). Add the SIGINT/SIGTERM
handling from `Examples/custom-server/Sources/MySite/MySite.swift` for a graceful drain.

- `bind.alpnTokens` for a multiplexed listener is the protocol's own tokens (`["h3"]`).
- `bind.boundAddresses` lets the QUIC listener take the TLS listener's port, which matters
  when that was 0.
- Put `AltSvc` first so error pages and every other response carry it.
- To reuse `http-config.json` and only add routes, see
  [Reuse http-config.json](https://photon-http.sstools.co/docs/choosing-components.md#reuse-http-configjson-and-add-your-own-routes);
  the executable's `makeListeners` shows how it adds the TLS and QUIC listeners.

## Testing it

The system curl (`/usr/bin/curl`) has no HTTP/3. Homebrew's does (ngtcp2 and nghttp3):

```bash
scripts/make-test-identity.sh             # .test-identity/server.p12, self-signed, memory-only use
swift build -j 2 --product photon
scripts/guarded.sh -t 120 -- .build/debug/photon --config Root/http-config.tls.json
```

In another terminal (`Root/http-config.tls.json` uses TCP and UDP 8443):

```bash
curl -sk -o /dev/null -D - https://127.0.0.1:8443/ | grep -i alt-svc
# alt-svc: h3=":8443"; ma=86400

/opt/homebrew/opt/curl/bin/curl --http3-only -sk -o /dev/null -w '%{http_version} %{http_code}\n' https://127.0.0.1:8443/
# 3 200
```

`--http3-only` fails rather than falling back to TCP, so a `3` proves QUIC was used; `--http3`
tries QUIC and falls back. `-k` accepts the self-signed test certificate without changing any
trust settings. Browsers need a trusted certificate before they will use the `Alt-Svc`
alternative; see the TLS guide.

These checks were run against a loopback server with the test identity on 2026-11-13: the
HTTPS response (HTTP/2) carried `alt-svc: h3=":PORT"; ma=600` as configured, `--http3-only`
got `HTTP/3 200` with no `alt-svc` header, a cleartext response had none, and SIGINT stopped
the server cleanly.

### The test suites

| Suite | What it covers |
|---|---|
| `HTTP3Tests` (in-memory) | Frame parser, control streams, connection state, request streams, limits, abuse limits, cancellation, shutdown, priorities, QPACK dynamic table, WebSockets, proxying, Alt-Svc. Driven over `InMemoryMultiplexedTransport`, so close codes are checked exactly |
| `HTTP3Tests` over real QUIC | `H3CurlTests` (Homebrew curl: GET, body echo, 20 parallel requests, dynamic table, shutdown mid-request), `H3QUICCancellationTests`, `H3QUICPriorityTests`, `H3QUICWebSocketTests` (an in-repo QUIC client) |
| `QPACKTests` | Static table, codec, stream instructions, RFC 9204 Appendix B examples for the dynamic table, fuzzing |
| `NetworkTransportTests` | `QUICTransportTests`, `MultiplexedTransportConformanceTests` (the same scenarios against QUIC and the in-memory transport), `QUICCloseCodeTests` |

```bash
scripts/guarded.sh -t 600 -- swift test -j 2 --filter HTTP3Tests
```

Real-QUIC tests bind `127.0.0.1` port 0 and load `.test-identity` in memory (the test
support runs `scripts/make-test-identity.sh` when it is missing). Suites that drive curl are
skipped when `/opt/homebrew/opt/curl/bin/curl` does not exist.

**The four known issues.** A full `swift test` reports 4 known issues. They are not
failures: they are the four parameter combinations (two close modes × codes `0x100` and
`0x107`) of `QUICCloseCodeTests.applicationCloseCode`, which wraps one expectation in
`withKnownIssue(..., isIntermittent: true)`. The test runs curl through a loopback UDP relay,
decrypts what the server sent after closing with curl's key log, and records that our
application close code never reaches the peer (the limitation below). If a macOS release
starts sending it, the known issue stops being recorded and the test says so.

## Known limitations

- **Connection close codes do not reach the client.** Network.framework never sends an
  application CONNECTION_CLOSE frame, so the code HTTP/3 closes with (`H3_NO_ERROR`,
  `H3_EXCESSIVE_LOAD`, `H3_CLOSED_CRITICAL_STREAM`, ...) is not on the wire. The client sees
  the connection end, not why. Per-stream codes (RESET_STREAM, STOP_SENDING) do arrive.
  Details: [notes/nw-transport.md](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/notes/nw-transport.md#spike-open-question-6-is-our-connection_close-code-on-the-wire-no).
- **No 0-RTT and no session resumption.** The Network.framework listener issues no session
  tickets and has no public server-side switch, so there is also no replay risk.
- **Priorities barely change delivery.** RFC 9218 priorities order only the sends that wait
  for the connection's send budget. Packet scheduling between streams belongs to
  Network.framework, which has no per-stream priority API; measured, two downloads finish
  within half a millisecond of each other whatever their urgency
  ([M10-priorities](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/benchmarks/M10-priorities.md#http3)).
- **Network.framework's per-stream buffer is not configurable.** A client that stops reading
  can leave a few MiB per stream inside Network.framework beyond the flow-control window;
  `sendChunkSize`, `maxConnectionSendBuffer` and `timeouts.send` bound what the server
  itself holds.
- **No server push, no response trailers, no HTTP datagrams** (the server reads a client's
  `SETTINGS_H3_DATAGRAM` but does not advertise or use it), **no encoder-side QPACK
  insertion.**
- **The executable exposes few HTTP/3 settings.** Only the QPACK values, the port and
  `altSvcMaxAge` are in `http-config.json`; `maxBodySize` and `timeouts` do not apply to
  HTTP/3 there. A custom server sets any `H3Configuration` value.
- **Browser interop is not yet recorded.** Issue #0105 (browsers, `URLSession`, load numbers
  under several connections) is open. The spike showed `URLSession` with
  `assumesHTTP3Capable` negotiating `h3` against a minimal HTTP/3 server; this server has
  been tested with curl and the in-repo client.

## Performance

| Measurement | Result | Record |
|---|---|---|
| Shipped binary, one curl process, 16 parallel requests on one QUIC connection, 626-byte file | about 8,600 req/s over HTTP/3, against about 32,300 for HTTPS from the same curl (load average about 7) | [M5-listeners](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/benchmarks/M5-listeners.md) |
| Network.framework per-stream cost (spike) | 0.4–0.8 ms per stream round trip (concurrent vs sequential), about 590 server-side allocations per stream, mostly inside Network.framework | [quic-spike](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/spikes/quic-spike.md) |
| QPACK decode of a 10-field request head | 661 ns static only; 114 ns from the dynamic table | [M10-qpack-dynamic](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/benchmarks/M10-qpack-dynamic.md) |
| QPACK encode, same head | 955 ns | [M10-qpack-dynamic](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/benchmarks/M10-qpack-dynamic.md) |
| HTTP/3 frame parse | 11.87 ns per frame whole; 41.55 ns fed in 37-byte chunks | [M10-qpack-dynamic](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/benchmarks/M10-qpack-dynamic.md) |

The M5 HTTP/3 figure is limited partly by curl (one QUIC connection on one thread) and partly
by the per-stream cost; it is not a load benchmark. Proper HTTP/3 load numbers are #0105.
More in [Performance notes](https://photon-http.sstools.co/docs/performance.md).

## Standards

- [RFC 9114](https://www.rfc-editor.org/rfc/rfc9114) — HTTP/3
- [RFC 9204](https://www.rfc-editor.org/rfc/rfc9204) — QPACK: Field Compression for HTTP/3
- [RFC 9000](https://www.rfc-editor.org/rfc/rfc9000) — QUIC: A UDP-Based Multiplexed and Secure Transport (provided by Network.framework)
- [RFC 9220](https://www.rfc-editor.org/rfc/rfc9220) — Bootstrapping WebSockets with HTTP/3
- [RFC 9218](https://www.rfc-editor.org/rfc/rfc9218) — Extensible Prioritization Scheme for HTTP
- [RFC 7838](https://www.rfc-editor.org/rfc/rfc7838) — HTTP Alternative Services
