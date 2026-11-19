# WebSockets

The `WebSockets` target serves RFC 6455 WebSockets inside your own Swift server: one
`WebSocketUpgrade` component answers the opening handshake over HTTP/1.1 (`Upgrade`), HTTP/2
(RFC 8441 extended CONNECT) and HTTP/3 (RFC 9220 extended CONNECT), then runs a `WebSocket`
session that your handler reads and writes with `async`/`await`. It validates frames, masking
and UTF-8, reassembles fragmented messages, answers pings, runs the close handshake, applies
backpressure in both directions and optionally compresses messages (permessage-deflate,
RFC 7692).

The short version is in [Dynamic websites](dynamic-sites.md#websockets); this guide is the
in-depth one.

| You want | Use |
|---|---|
| A WebSocket endpoint whose logic is Swift running in the server | `WebSocketUpgrade` in a [custom server package](choosing-components.md#a-custom-server-package) (this guide) |
| To put an existing WebSocket app (Node, Go, Python, another server) behind SwiftWebServer | The shipped executable's reverse proxy with `"websocket": true` on a mount ([below](#proxying-websockets-to-a-backend)) |

**In-process endpoints need Swift code.** `http-config.json` has no key that defines a
WebSocket endpoint, and the shipped `SwiftWebServer` executable does not link the `WebSockets`
target; the config file can only *proxy* WebSockets to a backend. There is also no
`WebSockets` package trait: it was removed because there was nothing for it to switch (issue
#0130, [Choosing components](choosing-components.md#package-traits-for-the-executable)).

## Depend on the target

```swift
// Package.swift of your server
dependencies: [
    .package(url: "https://github.com/brennanMKE/PhotonHTTP.git", branch: "main"),
],
targets: [
    .executableTarget(name: "MySite", dependencies: [
        .product(name: "HTTPCore", package: "PhotonHTTP"),
        .product(name: "HTTP1", package: "PhotonHTTP"),
        .product(name: "HTTPServer", package: "PhotonHTTP"),
        .product(name: "NetworkTransport", package: "PhotonHTTP"),
        .product(name: "WebSockets", package: "PhotonHTTP"),
        // .product(name: "HTTP2", …), .product(name: "HTTP3", …) for h2 and h3 WebSockets
    ]),
]
```

`WebSockets` depends only on `HTTPCore` and `Compression` (zlib, for permessage-deflate). It
does not depend on any protocol target: the session runs over whatever byte stream the
protocol hands it. [`Examples/custom-server`](../../Examples/custom-server/README.md) is a
complete package with a `/ws` echo next to a router and static files.

## A first endpoint: echo

```swift
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport
import WebSockets

@main
struct EchoServer {
    static func main() async throws {
        let echo = WebSocketUpgrade(path: "/ws") { socket, request in
            for await message in socket.messages {
                try await socket.send(message)        // .text or .binary, as received
            }
            // messages ended: the peer closed, the connection dropped, or the server is shutting down
        }
        let listener = try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: 8080))
        let server = Server(listeners: [listener], protocols: [HTTP1()]) {
            echo
            NotFoundHandler()       // everything that is not /ws
        }
        try await server.run()
    }
}
```

```bash
websocat ws://127.0.0.1:8080/ws     # type a line, get it back
```

Put `WebSocketUpgrade` before the components that would otherwise answer its path (a
`Router`, `StaticFiles`). Requests on other paths pass through it untouched. Middleware such
as `Compression` leaves the handshake response (a `.tunnel` body) alone, so the order relative
to it does not matter.

## The session API

The handler gets a `WebSocket` and a `WebSocketRequest`, and runs for the life of the
connection.

| Member | What it does |
|---|---|
| `messages` | `AsyncSequence` of `WebSocketMessage`: `.text(String)` (already validated UTF-8) or `.binary(ByteBuffer)`, in order, each a complete (reassembled, inflated) message. Ends when the connection closes. Iterate it from one task at a time |
| `send(_ message:)`, `send(text:)`, `send(binary:)` | Sends one message as one frame. Suspends while the outbound queue is full. Throws `WebSocketError.closed` once the connection is closing or closed |
| `ping(_ payload: ByteBuffer = ByteBuffer(), timeout: Duration = .seconds(10))` | Sends a ping and waits up to `timeout` for the pong with the same payload. Payload at most 125 bytes (`WebSocketError.pingPayloadTooLong`). Throws `.pingTimedOut` when no pong arrives in time (the connection stays open), `.closed` if the connection closes first |
| `close(code: = .normalClosure, reason: = "")` | Starts the close handshake and returns once the Close frame is queued. The reason is at most 123 UTF-8 bytes (`.closeReasonTooLong`); the code must be sendable (`.invalidCloseCode`, see [close codes](#close-codes)). Closing a connection that is already closing does nothing |
| `state` | `.open`, `.closing` (we sent Close, waiting for the peer's) or `.closed` |
| `closeCode`, `closeReason` | What the peer closed with: its code, `1005` for a Close with no code, `1006` if the stream ended without a Close; `nil` while no Close was received |
| `failureCode` | Set when the peer violated the protocol and the server failed the connection |
| `subprotocol`, `compression`, `connectionInfo`, `configuration` | What the handshake agreed, the connection's addresses, the limits in force |

The `WebSocketRequest` owns copies of what the handshake carried, so it stays valid for the
whole session: `path` (still percent-encoded), `query` (without `?`), `origin`,
`offeredSubprotocols`, `headers` (every request field) and `connection` (addresses).

### Lifecycle

| The handler… | The session… |
|---|---|
| returns while the connection is open | closes it with 1000 (normal closure) |
| throws | closes it with 1011 (internal error) |
| is still running when the server shuts down | starts the close handshake with 1001 (going away); `messages` ends once the peer answers or `closeTimeout` passes |
| stops iterating `messages` but keeps running | drops buffered and later messages, so reading the socket never stalls on it |

Messages still buffered when the handler returns are dropped. The session reads, writes and
times the close handshake in child tasks of one task group; nothing outlives the handler and
the connection.

`send` and `ping` can be called from any task (the outbound side is a queue); only the
iteration of `messages` must stay in one task at a time.

### Sending

```swift
try await socket.send(text: "hello")
try await socket.send(binary: ByteBuffer(bytes: [0x01, 0x02, 0x03]))
try await socket.send(.text(#"{"type":"ready"}"#))
```

Each message goes out as a single frame; the server never fragments what it sends, and there
is no size limit on outgoing messages (the client may have one). Text is sent as its UTF-8
bytes.

### Ping and pong

Pings from the client are answered automatically with a pong carrying the same payload; your
handler never sees them. The session also keeps the connection alive by itself (see
[keepalive](#keepalive) below), so most handlers never ping.

`ping()` is for the server's own checks, such as measuring round-trip time. It waits up to
`timeout` (10 s by default) for the matching pong and throws `WebSocketError.pingTimedOut`
when none arrives; the connection stays open and what to do next is your call:

```swift
do {
    try await socket.ping(timeout: .seconds(5))
} catch WebSocketError.pingTimedOut {
    try await socket.close(code: .policyViolation, reason: "no pong")
}
```

`ping()` is cancellable, and a pong answers every waiting ping with the same payload. Control
frames do not wait for your handler to read `messages`: the session answers pings and sees
pongs and Close frames while messages wait unread, up to the next data frame (see
[backpressure](#backpressure)).

### Keepalive

`WebSocketConfiguration.keepalive` (on by default) pings a quiet peer and drops one that has
gone away:

- When nothing has arrived from the peer for `interval` (20 s), the session sends an empty
  ping.
- If nothing arrives within `timeout` (10 s) after it (its pong, or any other frame), the peer
  is presumed gone: the session closes the transport without a close handshake (there is no
  one to answer), `messages` ends, and `closeCode` reads 1006 (`.abnormalClosure`).
- A peer that sends anything, data or its own pings, is never pinged. A peer whose messages
  wait behind a slow handler is not either: it is ahead of you, not gone, and its pong could
  not be read past its unread messages anyway.

So a vanished peer (a laptop lid closed, a phone that lost coverage, a NAT that forgot the
mapping) holds its session for at most 30 s, over any protocol. The 20 s interval also keeps
an HTTP/3 WebSocket below QUIC's 30 s idle timeout, and clients' pongs keep NATs and proxies
with 60 s idle timeouts from dropping the connection. Browsers and `URLSessionWebSocketTask`
answer pings without any code on the client side.

```swift
var configuration = WebSocketConfiguration()
configuration.keepalive = .init(interval: .seconds(10), timeout: .seconds(5))   // mobile clients
// configuration.keepalive = nil                                                // off
WebSocketUpgrade(path: "/live", configuration: configuration) { socket, _ in /* … */ }
```

Keep `interval` below the shortest idle timeout on the path: QUIC's (`QUICConfiguration.idleTimeoutMilliseconds`,
30 s by default) for HTTP/3, and any load balancer's in front of the server. Turn it off only
when the application pings on its own schedule.

### Closing

```swift
try await socket.close()                                         // 1000, no reason
try await socket.close(code: .goingAway, reason: "deploying")
try await socket.close(code: WebSocketCloseCode(rawValue: 4001), reason: "token expired")   // private use
```

After `close`, `state` is `.closing`, `send` throws `.closed`, data frames from the peer are
discarded, and `messages` ends when the peer's Close arrives or `closeTimeout` (5 s) passes,
after which the transport is closed anyway. When the peer closes first, the server echoes its
code (without a reason, as RFC 6455 §5.5.1 allows) and closes the connection; read
`socket.closeCode` and `socket.closeReason` after the loop to see why.

### Backpressure

Both directions are bounded, so a slow side slows the other instead of growing memory:

- **Inbound.** The session buffers at most `inboundMessageCapacity` complete messages (default
  1). When the handler is behind, the session stops reading the transport; TCP (or HTTP/2 and
  QUIC flow control) then pushes back on the client. While the queue is full, the session holds
  one more received message and keeps reading up to the next data frame, so pings are still
  answered and pongs and a Close are still seen; a Close ends `messages` after the messages
  already received. What comes after that next data frame waits until the handler takes a
  message. Keepalive treats this as a live peer.
- **Outbound.** `send` suspends while `outboundFrameCapacity` frames (default 8) wait for the
  transport. A client that does not read makes your `send` wait; give long-lived senders a
  timeout or drop slow clients.

## Example: a JSON chat room

A broadcast endpoint needs the set of open sockets shared between sessions. `WebSocket` is a
`Sendable` class, so a `Mutex`-protected dictionary works:

```swift
import Foundation          // JSONEncoder/Decoder in your handler code
import Synchronization
import WebSockets

final class ChatRoom: Sendable {
    private let members = Mutex<[ObjectIdentifier: WebSocket]>([:])

    func join(_ socket: WebSocket) { members.withLock { $0[ObjectIdentifier(socket)] = socket } }
    func leave(_ socket: WebSocket) { _ = members.withLock { $0.removeValue(forKey: ObjectIdentifier(socket)) } }

    /// Sends to every member concurrently; one slow member delays this call, not the others.
    func broadcast(_ text: String) async {
        let sockets = members.withLock { Array($0.values) }
        await withDiscardingTaskGroup { group in
            for socket in sockets {
                group.addTask { try? await socket.send(text: text) }   // .closed for members on their way out
            }
        }
    }
}

struct Incoming: Decodable { var name: String; var text: String }
struct Outgoing: Encodable { var name: String; var text: String; var at: Date }

let room = ChatRoom()
let chat = WebSocketUpgrade(
    path: "/chat",
    configuration: WebSocketConfiguration(maxMessageSize: 64 * 1024),     // chat lines, not files
    origin: { $0.origin == "https://chat.example.com" }
) { socket, _ in
    room.join(socket)
    defer { room.leave(socket) }
    let decoder = JSONDecoder(), encoder = JSONEncoder()
    for await message in socket.messages {
        guard case .text(let text) = message,
              let incoming = try? decoder.decode(Incoming.self, from: Data(text.utf8)) else {
            try await socket.close(code: .unsupportedData, reason: "expected JSON text")
            continue                                      // messages ends once the client answers
        }
        let out = Outgoing(name: incoming.name, text: incoming.text, at: Date())
        await room.broadcast(String(decoding: try encoder.encode(out), as: UTF8.self))
    }
}
```

`broadcast` waits for the slowest member's outbound queue. For rooms with clients you do not
control, bound it (race each `send` against a timer in a task group) and close
members that fall behind with `.policyViolation` or `.tryAgainLater`.

## The opening handshake

### Path matching

`WebSocketUpgrade(path:)` compares the request path byte for byte, still percent-encoded and
without the query (`/ws?room=1` matches `path: "/ws"`; read the query from
`request.query`). There are no patterns or prefixes; use one component per endpoint, or
`path: nil` and branch on `request.path` in the handler.

| Request | `path: "/ws"` | `path: nil` |
|---|---|---|
| Another path | Next handler | Next handler if it has no `Upgrade: websocket`, otherwise handled here |
| The path, valid handshake | `101` (HTTP/1.1) or `200` (extended CONNECT), session starts | same |
| The path, `GET` without `Upgrade: websocket` | `426 Upgrade Required` with `Upgrade: websocket` | Next handler |
| The path, `Sec-WebSocket-Version` missing, repeated or not `13` | `426` with `Sec-WebSocket-Version: 13` (`400` with that field over extended CONNECT) | same |
| Not `GET`, no `upgrade` token in `Connection`, bad `Sec-WebSocket-Key` (missing, repeated, not base64 of 16 bytes), HTTP/1.0 | `400` | same |
| Rejected by `origin` | `403` | same |

HTTP/1.0 requests are never upgraded (RFC 9110 ignores `Upgrade` there). Frames a client
sends right behind its handshake request, before seeing `101`, are kept and replayed into the
session.

### Origin checks

Browsers send `Origin` with every WebSocket handshake, and a WebSocket is not subject to
CORS: any page can open one to your server, with the user's cookies. If the endpoint relies on
cookies or other ambient credentials, check the origin:

```swift
let allowed: Set<String> = ["https://example.com", "https://www.example.com"]
WebSocketUpgrade(path: "/ws", origin: { request in
    guard let origin = request.origin else { return false }   // false also rejects non-browser clients
    return allowed.contains(origin)
}) { socket, request in … }
```

`origin` returns `false` → `403`, and the handler never runs. It sees the whole
`WebSocketRequest`, so it is also the place for other accept/reject decisions made from the
request alone (a token in the query or a header). Authentication middleware (`Auth`) placed
before the component applies too.

### Subprotocols

The client lists subprotocols in `Sec-WebSocket-Protocol`, in its order of preference; they
arrive as `request.offeredSubprotocols`. `subprotocol` picks one:

```swift
WebSocketUpgrade(path: "/rpc", subprotocol: { request in
    ["v2.rpc.example", "v1.rpc.example"].first { request.offeredSubprotocols.contains($0) }
}) { socket, _ in
    switch socket.subprotocol {
    case "v2.rpc.example": …
    default: …
    }
}
```

The choice is returned in the response's `Sec-WebSocket-Protocol`. A choice the client did
not offer is ignored (no field is sent), as is `nil`. Without a `subprotocol` closure no
subprotocol is ever agreed.

### Extensions

The only extension is permessage-deflate, accepted when `WebSocketConfiguration.compression`
is set ([below](#permessage-deflate)). Other extensions in `Sec-WebSocket-Extensions` are
ignored, and frames with RSV bits that no negotiated extension allows fail the connection
with 1002.

### HTTP/1.1, HTTP/2 and HTTP/3

The same component and handler serve all three; the handshake differs, the session does not.

| | HTTP/1.1 | HTTP/2 | HTTP/3 |
|---|---|---|---|
| Standard | RFC 6455 §4 | RFC 8441 | RFC 9220 |
| Client sends | `GET` + `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13` | `CONNECT` with `:protocol websocket`, `Sec-WebSocket-Version: 13` (no key) | same as HTTP/2 |
| Server answers | `101 Switching Protocols` with `Sec-WebSocket-Accept` | `200` | `200` |
| Session runs over | the TCP (or TLS) connection, which is then used for nothing else | one stream; other requests share the connection | one QUIC request stream |
| Advertised by | – | `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1` | `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1` |
| Register | `HTTP1()` | `HTTP2()` (usually `TLSNegotiated(HTTP2(), fallback: HTTP1())`) | `HTTP3()` on a QUIC listener |

`HTTP2` and `HTTP3` turn `SETTINGS_ENABLE_CONNECT_PROTOCOL` on by themselves when an
`ExtendedConnectProvider` is anywhere in the handler chain (including inside `VirtualHosts`);
`WebSocketUpgrade` is one, and so is `ReverseProxy` when a mount has `websocket` on. You can
also force it with `enableConnectProtocol` in `HTTP2Configuration` / `H3Configuration`.
Without the setting, an HTTP/2 request carrying `:protocol` is reset with `PROTOCOL_ERROR`
and an HTTP/3 one is malformed.

An extended CONNECT's DATA is the tunnel's byte stream, not a request body, so
`maxRequestBodySize` does not apply to it. On HTTP/2, a reset stream ends the session as an
abnormal closure (1006); the tunnel's data goes through the stream's flow control like a
response body. Listener and TLS setup for h2 and h3 are in
[Choosing components](choosing-components.md#https-http2-and-http3-in-swift); the same
WebSocket component needs nothing extra.

## permessage-deflate

```swift
let ws = WebSocketUpgrade(
    path: "/feed",
    configuration: WebSocketConfiguration(compression: PerMessageDeflate.Configuration())
) { socket, _ in
    // socket.compression is nil when the client did not offer the extension
    …
}
```

With `compression` set, a client's `permessage-deflate` offer is accepted and answered in
`Sec-WebSocket-Extensions`; with it `nil` (the default) the extension is declined and every
message travels uncompressed. Compression is per message: each data message the server sends
is deflated into one frame with RSV1 set, and RSV1 messages from the client are inflated as
their frames arrive. Messages below `minimumMessageSize` go out uncompressed, as do (without
context takeover) messages that do not get smaller.

### Negotiation

The client may offer the extension several times with different parameters; the first offer
the server can honour is accepted. An offer with an unknown or repeated parameter or an
invalid value is declined.

| Parameter | When the client offers it | In the response |
|---|---|---|
| `server_no_context_takeover` | The server resets its compressor after each message | Sent when offered or when `serverNoContextTakeover` is set |
| `client_no_context_takeover` | The client resets its compressor | Sent when offered or when `clientNoContextTakeover` is set |
| `server_max_window_bits=N` | The server's window may be at most 2^N | `min(N, serverMaxWindowBits)`; also sent unasked when `serverMaxWindowBits` is below 15. An agreed window of 2^8 declines the offer (zlib's raw deflate needs at least 2^9) |
| `client_max_window_bits[=N]` | The client can limit its window | `clientMaxWindowBits` when that is below 15 (only if the client offered the parameter) |

The server always inflates with a 2^15 window, which decodes whatever window the client uses.
`URLSessionWebSocketTask` on macOS offers a bare `permessage-deflate` and compresses every
message it sends (covered by `URLSessionDeflateTests`).

### `PerMessageDeflate.Configuration`

| Field | Default | Range | Meaning |
|---|---|---|---|
| `serverNoContextTakeover` | `false` | | Reset the compressor after every message (always on when the client asks) |
| `clientNoContextTakeover` | `false` | | Ask the client to reset its compressor after every message |
| `serverMaxWindowBits` | `15` | 9…15 | The server's LZ77 window |
| `clientMaxWindowBits` | `15` | 8…15 | The window the client may use |
| `compressionLevel` | `6` | 1…9 | zlib level |
| `memoryLevel` | `8` | 1…9 | zlib memory level (state size and speed) |
| `minimumMessageSize` | `32` | ≥ 0 | Smaller messages are sent uncompressed |

Values out of range trap at initialization.

### Cost and when to enable it

From [M15-websockets](../benchmarks/M15-websockets.md) (1,000 typical JSON messages, 124 bytes
on average):

| Setting | Stream size | Compress, per message | Inflate, per message |
|---|---|---|---|
| Default (level 6, context takeover) | 19% of original | 2.5 µs | 0.2 µs |
| Level 1 | 26% | 1.7 µs | |
| Level 9 | 18% | 5.9 µs | |
| Window 2^10 | 29% | 3.7 µs | |
| `server_no_context_takeover` | 86% | 5.0 µs | |
| `client_no_context_takeover` | | | 0.7 µs |

- **Memory:** at the defaults about 256 KiB of zlib state for the compressor and 44 KiB for
  the decompressor per connection, held for the connection's whole life. 1,000 connections
  cost about 300 MB. A smaller `serverMaxWindowBits` and `memoryLevel` shrink the compressor's
  state at a cost in ratio and CPU; no context takeover does not free the state.
- **Enable it** for streams of many small, similar messages (JSON APIs, market data, chat,
  presence, game state) over real networks: context takeover is what makes small messages
  shrink (19% of the original against 86% without it).
- **Leave it off** for already-compressed payloads (images, video, protobuf over compressed
  transports), for loopback or LAN traffic where bytes are free, and for endpoints with very
  many mostly idle connections where the per-connection state dominates.
- **Inbound is bounded:** a message that inflates past `maxMessageSize` fails the connection
  with 1009 as soon as the excess is produced, so a decompression bomb costs at most
  `maxMessageSize`. Data that does not inflate is 1007. If zlib cannot allocate its state at
  the start of a session, the session is refused with a Close 1011.

## Limits and timeouts

`WebSocketConfiguration`, passed to `WebSocketUpgrade(configuration:)`:

| Field | Default | What happens at the limit |
|---|---|---|
| `maxFrameSize` | 16 MiB | A received frame with a longer payload fails the connection with 1009, decided from the frame header before the payload is buffered. Must be ≥ 125 |
| `maxMessageSize` | 16 MiB | A received message longer than this after reassembly (and after inflating, with compression) fails the connection with 1009, also detected from frame headers for uncompressed messages |
| `closeTimeout` | 5 s | How long to wait for the peer's Close after ours (or for its end of stream after it closed), then the transport is closed anyway |
| `inboundMessageCapacity` | 1 | Complete messages buffered for the handler before the session stops reading |
| `outboundFrameCapacity` | 8 | Frames queued for sending before `send` suspends |
| `receiveSize` | 64 KiB | Largest single read from the transport |
| `compression` | `nil` | permessage-deflate settings; `nil` declines the extension |
| `keepalive` | 20 s interval, 10 s timeout | A ping after `interval` without anything from the peer; nothing within `timeout` after it closes the connection as 1006. `nil` turns it off. See [keepalive](#keepalive) |

Fragmentation is accepted inbound with any number of fragments, limited only by
`maxMessageSize`; control frames may arrive between fragments. Outbound messages are never
fragmented.

**Memory per connection** is bounded by these numbers: roughly one message being assembled
(up to `maxMessageSize`), `inboundMessageCapacity` complete messages, `outboundFrameCapacity`
queued frames, the receive buffer, and the zlib state when compression is on. The 16 MiB
defaults suit trusted clients; for a public endpoint set `maxMessageSize` and `maxFrameSize`
to the largest message your protocol needs.

### Timeouts, and what ends a quiet connection

The `WebSockets` component's [keepalive](#keepalive) (on by default) pings a peer that has been
quiet for 20 s and closes the connection when nothing answers within 10 s, over every protocol.
A quiet but healthy peer stays connected indefinitely: there is no idle timeout and no
handshake-to-first-message timeout. What else applies depends on the protocol under it:

| Over | What applies after the handshake |
|---|---|
| HTTP/1.1 | None of HTTP/1.1's timeouts: they stop at `101`. A peer that vanishes without a FIN or reset is found by keepalive. With keepalive off it keeps the session until a send fails, unless TCP keep-alive is on for the listener (`TCPConfiguration(keepAlive: .init())`, off by default; 60 s idle, 10 s interval, 6 probes) |
| HTTP/2 | The stream is running, so the connection's `idleTimeout` does not fire. Each WebSocket counts against `maxConcurrentStreams` (default 100 per connection). A client that stops reading while the server sends trips `windowStallTimeout` (30 s by default) |
| HTTP/3 | QUIC's idle timeout (`QUICConfiguration.idleTimeoutMilliseconds`, 30 s by default) closes the connection when no packets flow. Keepalive's 20 s pings keep a quiet WebSocket under it; with keepalive off, or an `interval` at or above the idle timeout, quiet WebSockets are dropped |
| Server shutdown | 1001 to every in-process session, then `closeTimeout` for the peer's answer, within the server's `drainTimeout` (10 s by default) |

## Protocol violations and close codes

A violation by the client *fails* the connection (RFC 6455 §7.1.7): the server sends a Close
with the code below (if it has not sent one yet), closes the transport, and `messages` ends.
`socket.failureCode` holds the code.

| Violation | Close code |
|---|---|
| Unmasked frame from the client | 1002 |
| Reserved opcode (3–7, 11–15) | 1002 |
| RSV bit set without a negotiated extension; RSV1 on a continuation or control frame | 1002 |
| Control frame fragmented or longer than 125 bytes | 1002 |
| 64-bit length with the most significant bit set | 1002 |
| Continuation without a message in progress; new text/binary frame inside a fragmented message | 1002 |
| Close frame with a 1-byte payload, or a code no endpoint may send | 1002 |
| Text that is not UTF-8 (checked as it arrives, across fragments; the first bad byte fails it), or a message ending inside a code point | 1007 |
| Close reason that is not UTF-8 | 1007 |
| Compressed data that does not inflate | 1007 |
| Frame over `maxFrameSize`, message over `maxMessageSize` (inflated size with compression) | 1009 |

Binary messages are not inspected. Overlong (non-minimal) length encodings are accepted, as
RFC 6455 leaves them to the sender. A violation while the server is already closing just
closes the transport.

### Close codes

`WebSocketCloseCode` has constants for the registered codes:

| Code | Constant | Sent by this server when |
|---|---|---|
| 1000 | `.normalClosure` | The handler returned; your default for `close()` |
| 1001 | `.goingAway` | Server shutdown |
| 1002 | `.protocolError` | Protocol violation (table above) |
| 1003 | `.unsupportedData` | – (for you: wrong message type) |
| 1005 | `.noStatusReceived` | Never sent; reported in `closeCode` for a Close without a code |
| 1006 | `.abnormalClosure` | Never sent; reported when the stream ended without a Close, or keepalive found the peer gone |
| 1007 | `.invalidFramePayloadData` | Invalid UTF-8 or deflate data |
| 1008 | `.policyViolation` | – (for you: a generic policy refusal) |
| 1009 | `.messageTooBig` | Frame or message over the limits |
| 1010 | `.mandatoryExtension` | – (sent by clients) |
| 1011 | `.internalServerError` | The handler threw; zlib could not allocate |
| 1012–1014 | `.serviceRestart`, `.tryAgainLater`, `.badGateway` | – |
| 1015 | `.tlsHandshake` | Never sent |

`close(code:)` accepts 1000–1003, 1007–1014 and 3000–4999 (3000–3999 are registered with
IANA, 4000–4999 are for private use between your server and your clients); anything else
throws `WebSocketError.invalidCloseCode`. The same rule applies to codes received: a Close
from the client with 1004–1006, 1015, 1016–2999 or a value outside 1000–4999 is a 1002.

## Proxying WebSockets to a backend

The shipped executable forwards WebSockets to an app on localhost when the proxy mount has
`"websocket": true`:

```json
{
  "root": "Public",
  "proxy": [
    { "path": "/socket", "upstream": "http://127.0.0.1:9000", "websocket": true,
      "timeouts": { "connect": 2, "idle": 600 } }
  ]
}
```

- **HTTP/1.1 clients:** a request with `Connection: upgrade` and `Upgrade: websocket` is sent
  upstream on a dedicated connection with its `Upgrade`/`Connection` fields. A `101` from the
  backend becomes a `101` to the client and the two byte streams are spliced; any other answer
  is proxied as a normal response.
- **HTTP/2 and HTTP/3 clients:** an extended CONNECT with `:protocol websocket` becomes an
  HTTP/1.1 `GET` with `Upgrade: websocket` and a fresh `Sec-WebSocket-Key` upstream. A `101`
  whose `Sec-WebSocket-Accept` matches that key becomes a `200` to the client; a `101` that
  does not match is `502`. The backend only ever needs to speak HTTP/1.1 WebSockets. With any
  mount set to `websocket`, `HTTP2` and `HTTP3` advertise extended CONNECT.
- Other request fields (`Sec-WebSocket-Protocol`, `Sec-WebSocket-Extensions`, `Origin`,
  cookies) pass through with the usual forwarded headers; subprotocol, compression and origin
  decisions are the backend's. The proxy does not parse WebSocket frames.
- A mount without `"websocket": true` strips `Upgrade` as a hop-by-hop field (the backend sees
  a plain `GET`), and answers an extended CONNECT with `501`.
- Upgraded upstream connections are never returned to the pool.

| Setting | Value | Meaning |
|---|---|---|
| `websocket` | `false` | Tunnel WebSocket upgrades on this mount |
| `timeouts.idle` | absent: 300 s for tunnels | The tunnel closes when no byte moves in either direction for this long. Setting it explicitly also sets the tunnel's limit; `0` or `null` turns it off |
| Handshake timeout | 30 s (not configurable in the file) | Connecting upstream and reading its answer; `504` on timeout, `502` on a failure |
| Half-close timeout | 30 s (not configurable in the file) | After one direction ends, how long the other may continue |

Long-lived quiet sockets (notifications, dashboards) need `"idle": 0` or a value above the
interval at which the app or client pings. Since `idle` also bounds ordinary proxied
requests between body reads, consider a separate mount for the WebSocket path. On server
shutdown a spliced tunnel is closed at the transport level; the proxy sends no Close frame
of its own, so clients see the connection drop (1006) unless the backend closes first. The
rest of the proxy (`upstreams`, `stripPrefix`, `hosts`, health checks) is in
[Dynamic websites](dynamic-sites.md#proxy-mount-reference); in a custom server the same
component is `ReverseProxy` with a `ProxyMount` whose `websocket` is `true`, and its
`ProxyTunnelConfiguration` exposes the handshake, idle and half-close timeouts and
`allowedUpgradeProtocols` for non-WebSocket upgrades.

## Testing

Follow [AGENTS.md](../../AGENTS.md) on the owner's Mac: bind tests to `127.0.0.1` port 0 and
run servers through `scripts/guarded.sh`.

- **websocat** (`brew install websocat`): `websocat ws://127.0.0.1:8080/ws` sends each line as
  a text message and prints what comes back; `websocat -b` for binary.
- **curl** on macOS 15 cannot talk WebSocket, but it shows the handshake:

  ```bash
  curl -sv --http1.1 -H "Upgrade: websocket" -H "Connection: Upgrade" \
       -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
       --max-time 2 http://127.0.0.1:8080/ws
  # < HTTP/1.1 101 Switching Protocols
  # < sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
  ```

- **A browser console:** `const ws = new WebSocket("ws://127.0.0.1:8080/ws");
  ws.onmessage = e => console.log(e.data); ws.onopen = () => ws.send("hi")`. Browsers send
  `Origin`, so this also exercises your `origin` check. Over HTTPS, browsers that support
  RFC 8441 use HTTP/2 extended CONNECT.
- **Swift, end to end:** `URLSessionWebSocketTask` against a server on port 0, as
  `Tests/WebSocketsTests/URLSessionWebSocketTests.swift` does (echo, ping, both close
  directions, 1001 on shutdown). It speaks HTTP/1.1 only and limits incoming messages by
  `maximumMessageSize`, which the tests raise.
- **Swift, in memory:** run a session with no sockets at all and play the client with masked
  frames, as `WebSocketSessionTests` does:

  ```swift
  import HTTPCore
  import HTTPTestSupport
  import Testing
  import WebSockets

  @Test(.timeLimit(.minutes(1))) func echoes() async throws {
      let (client, server) = InMemoryTransport.makePair()
      try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
              await WebSocket.run(over: server) { socket in
                  for await message in socket.messages { try await socket.send(message) }
              }
          }
          var frame = ByteBuffer()
          WSFrameWriter.appendFrame(opcode: .text, payload: ByteBuffer(bytes: Array("hi".utf8)),
                                    maskKey: 0x3712_A5C9, into: &frame)      // clients must mask
          try await client.send(frame, endOfStream: false)
          // read the reply with WSFrameParser(configuration: .init(expectsMaskedFrames: false)),
          // then send a Close and wait for the session to end
          …
          try await group.waitForAll()
      }
  }
  ```

  `WebSocketHandshake.validate(_:)` and `PerMessageDeflate.negotiate(offers:configuration:)`
  are pure functions you can test without any transport.
- **HTTP/2 and HTTP/3:** no stock command-line client speaks RFC 8441 or RFC 9220 on this
  machine; the repository's tests (`H2WebSocketTests`, `H3WebSocketTests`,
  `H3QUICWebSocketTests`) drive extended CONNECT with in-repo clients.

### Autobahn

No Autobahn|Testsuite results are recorded in [benchmarks/](../benchmarks/README.md); the
protocol rules are covered by the unit tests in `Tests/WebSocketsTests` (frame parser at every
split offset, UTF-8 at every code point boundary, every close code, fragmentation,
compression, decompression bombs). To run it yourself you need Docker or `wstest`, a server
with an echo `WebSocketUpgrade`, and `scripts/fuzzingclient.json` pointed at it
(`scripts/run-autobahn-client.sh` runs `wstest -m fuzzingclient` with that file; the URL in
it is `ws://127.0.0.1:8080` with no path, so give your echo component `path: nil` or edit the
URL). Do not start Docker unattended (see [AGENTS.md](../../AGENTS.md)).

## Standards

| RFC | Covers | Here |
|---|---|---|
| [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455) | The WebSocket Protocol: handshake, framing, masking, close codes | `WebSocketHandshake`, `WSFrameParser`, `WSConnection`, `WebSocket` |
| [RFC 7692](https://www.rfc-editor.org/rfc/rfc7692) | Compression Extensions for WebSocket (permessage-deflate) | `PerMessageDeflate` |
| [RFC 8441](https://www.rfc-editor.org/rfc/rfc8441) | Bootstrapping WebSockets with HTTP/2 (extended CONNECT) | `HTTP2` + `WebSocketUpgrade` |
| [RFC 9220](https://www.rfc-editor.org/rfc/rfc9220) | Bootstrapping WebSockets with HTTP/3 | `HTTP3` + `WebSocketUpgrade` |
| [IANA WebSocket Close Code registry](https://www.iana.org/assignments/websocket/websocket.xhtml#close-code-number) | 1012–1014 and 3000–4999 | `WebSocketCloseCode` |
