# HTTP/1.1

How the `HTTP1` target serves HTTP/1.1: when a connection uses it, what happens to the bytes
on a connection, which limits and timeouts apply, which status codes malformed requests get,
and how to configure it from Swift or `http-config.json`. For the server as a whole, start with
the [overview](overview.md).

## Where it sits

```
listener ─▶ transport ─▶ protocol registry ─▶ HTTP1.run ─▶ handler chain ─▶ response
 (BSD / NW TCP / TLS)     (ALPN or sniff)      (one per connection)  (middleware…, handler)
```

A listener accepts a connection and wraps it in a `ByteStreamTransport` (BSD sockets + kqueue
or Network.framework TCP for cleartext, Network.framework for TLS). The `Server`'s protocol
registry picks a protocol for it once. If that is HTTP/1.1, `HTTP1.run` owns the connection
until it closes: it parses each request head, calls the handler chain (the same chain HTTP/2
and HTTP/3 call), and writes the response. Middleware never sees HTTP/1.1 framing; it sees an
`HTTPRequest` and returns an `HTTPResponse`.

The target holds these pieces, each tested alone over in-memory transports:

| Type | File | Role |
|---|---|---|
| `HTTP1` | [HTTP1.swift](../../Sources/HTTP1/HTTP1.swift) | The `ConnectionProtocol` you register, and the per-connection loop |
| `HTTP1Configuration` | [HTTP1.swift](../../Sources/HTTP1/HTTP1.swift) | Buffer sizes, body limits, parser and chunked limits, timeouts |
| `HTTP1Parser`, `HTTP1ParserLimits`, `HTTP1ParseError` | [HTTP1Parser.swift](../../Sources/HTTP1/HTTP1Parser.swift), [HTTP1RequestHead.swift](../../Sources/HTTP1/HTTP1RequestHead.swift) | Incremental request-head parser and its limits and errors |
| `HTTP1Connection` | [HTTP1Connection.swift](../../Sources/HTTP1/HTTP1Connection.swift) | The connection state machine: keep-alive, body and error decisions. A value type with no I/O |
| `ChunkedDecoder`, `HTTP1ChunkedEncoder` | [ChunkedDecoder.swift](../../Sources/HTTP1/ChunkedDecoder.swift), [HTTP1Serializer.swift](../../Sources/HTTP1/HTTP1Serializer.swift) | Chunked transfer coding in and out |
| `HTTP1RequestBodyReader` | [HTTP1RequestBodyReader.swift](../../Sources/HTTP1/HTTP1RequestBodyReader.swift) | Reads request bodies on demand while the handler runs |
| `HTTP1Serializer`, `HTTP1ResponseBodyWriter` | [HTTP1Serializer.swift](../../Sources/HTTP1/HTTP1Serializer.swift), [HTTP1ResponseBodyWriter.swift](../../Sources/HTTP1/HTTP1ResponseBodyWriter.swift) | Response heads and framing; `.stream` bodies under backpressure |
| `HTTP1Timeouts` | [HTTP1Timeouts.swift](../../Sources/HTTP1/HTTP1Timeouts.swift) | Header, idle, body, send and linger limits |

`HTTP1` depends only on `HTTPCore`. `HTTPServer` depends on it, so every server includes it.

## When a connection speaks HTTP/1.1

The registry picks a protocol once per connection
([ProtocolRegistry.swift](../../Sources/HTTPServer/ProtocolRegistry.swift)):

| Connection | Registered protocols | Result |
|---|---|---|
| Cleartext | `[HTTP1()]` or `[TLSNegotiated(HTTP2(), fallback: HTTP1())]` | HTTP/1.1, with nothing read ahead |
| Cleartext | `[HTTP2(), HTTP1()]` (h2c on) | The first bytes are sniffed: the HTTP/2 preface goes to HTTP/2, anything that starts like a request line (optional empty lines, then a method token and a space) to HTTP/1.1. The sniffed bytes are replayed to the chosen protocol |
| TLS, ALPN `http/1.1` | any | HTTP/1.1 |
| TLS, ALPN `h2` | `TLSNegotiated(HTTP2(), fallback: HTTP1())` or `[HTTP2(), HTTP1()]` | HTTP/2 |
| TLS, no ALPN, or a token no protocol lists | any | The protocol that lists `http/1.1`, the TLS default |

`TLSNegotiated(HTTP2(), fallback: HTTP1())` is one protocol that offers `h2` and `http/1.1` by
ALPN and runs HTTP/2 only when TLS negotiated `h2`; every other connection runs the fallback.
With a single protocol registered, cleartext connections are neither sniffed nor wrapped in a
replay transport, so the cleartext path costs what `HTTP1` alone costs. The shipped executable
registers exactly this unless `"http2": {"cleartext": true}`; with `"http2": false` it
registers `[HTTP1]` ([ServerProtocols.swift](../../Sources/SwiftWebServer/ServerProtocols.swift)).
[Choosing components](choosing-components.md#https-http2-and-http3-in-swift) shows the Swift
side.

When sniffing is on, a client that does not send enough bytes to decide within
`ServerConfiguration.sniffTimeout` (10 s by default) is closed. Sniffing reads at most 64 bytes.

## A connection's lifecycle

One connection is one call to `HTTP1.run`. It owns the receive buffer, the parser, the
serializer, the output buffer and the state machine as locals: no actor, no task per request,
no lock. Two sibling tasks supervise it for its lifetime: a timer and a waiter on the server's
shutdown signal.

```
          ┌──────── needMoreBytes ───────┐
          ▼                              │
  idle ──bytes──▶ readingHead ──head──▶ handling ──response──▶ writing ──sent──▶ idle
    │                 │                    │                      │
    │            parse error          handler throws          close / tunnel
    ▼                 ▼                    ▼                      ▼
  closing ◀───────────┴────────────────────┘            closing / tunnelled
```

### Parsing the head

The parser scans bytes once, wherever the head is split across receives, and allocates nothing
once its field index has grown. It follows RFC 9112 strictly:

- Empty lines (CRLF) before the request line are skipped.
- Every line ends in CRLF. A bare LF or a CR without LF is an error.
- Method: 1 to 24 token characters, case-sensitive (`get` is an extension method, not `GET`).
  Extension methods such as `PROPFIND` are passed to the handler.
- Request target: bytes 0x21–0x7E, in one of the four forms of RFC 9112 §3.2. Origin form
  (`/path?query`) is the usual one. Absolute form (`http://host/path`) is accepted, without
  userinfo (`@`). Authority form (`host:port`) is accepted only for `CONNECT`, which requires
  it. Asterisk form (`*`) is accepted only for `OPTIONS`.
- Version: `HTTP/1.1` or `HTTP/1.0`.
- Field names are tokens. Whitespace before the `:` and obsolete line folding (a line starting
  with SP or HTAB) are errors. Values may contain visible characters, obs-text, SP and HTAB;
  leading and trailing whitespace is trimmed.
- After the head: HTTP/1.1 needs exactly one `Host`, and HTTP/1.0 at most one. Then the body
  framing is decided (see [Request smuggling defences](#request-smuggling-defences)).

The request the handler gets borrows the connection's receive buffer: no copy of the path,
query or fields. It is valid only while `handle` runs; `request.snapshot()` copies it.

### Keep-alive and pipelining

| Request | Connection after the response |
|---|---|
| HTTP/1.1 | Stays open unless the request's `Connection` lists `close` |
| HTTP/1.0 | Stays open only if `Connection` lists `keep-alive` |

Every response says `connection: keep-alive` or `connection: close`. The serializer writes that
field itself from the state machine's decision; a `Connection` field set by the handler is not
written as is (except on `1xx` and `.tunnel` responses, so `101` keeps the handler's
`connection: upgrade`). A handler that wants the connection closed after its response (after
an auth failure, under overload, to rebalance clients) sets `connection: close`: when that
field lists `close` (any case, any position in the list), the response says `connection: close`
and the connection closes after it, as RFC 9112 §9.6 describes; pipelined requests already read
are not answered. Any other `Connection` value is ignored: a handler cannot keep open a
connection the client or the server decided to close. HTTP/2 and HTTP/3 drop the field, which
is connection-specific there, and change nothing else.

There is no limit on the number of requests per connection; the idle timeout and
`maxConnections` bound what idle clients can hold.

Pipelining is supported. Per batch the loop does one `receive`, parses every complete head the
buffer holds, calls the handler for each in order, serializes the responses into one output
buffer, and sends it with one `send`. The output is sent early once it holds 64 KiB
(`flushThreshold`), so a long pipeline of large responses does not grow it without bound.
Before a request that has a body, earlier responses are sent first. After each batch consumed
bytes are discarded, so the receive buffer does not grow across requests.

### Request bodies

The handler reads the body through `request.body`, an `AsyncSequence` of `ByteBuffer` chunks.
Bytes are received only when the handler asks for them, so a handler that reads slowly applies
TCP backpressure to the client, and memory stays at about one receive (16 KiB by default)
whatever the body size.

```swift
for try await chunk in request.body { /* … */ }        // streamed
let whole = try await request.body.collect(upTo: 1 << 20)   // or collected, with a cap
let length = request.body.knownLength                   // Content-Length, nil for chunked
let trailers = request.body.trailers                    // chunked trailers, after the last chunk
```

| Framing | How it is read |
|---|---|
| No `Content-Length`, no `Transfer-Encoding` | No body |
| `Content-Length: N` | Exactly N bytes; reads never go past the body into the next request. Above `maxBodySize`: `413` and close before the handler runs |
| `Transfer-Encoding: chunked` | Decoded chunk by chunk. Chunk extensions are checked and ignored. Trailers are checked and exposed as `request.body.trailers`. Over `maxBodySize` decoded bytes: the read throws, the response is `413` and the connection closes |

A body is readable only while the handler runs; a body kept after it returns throws
`HTTPRequestBodyError.expired`. If the handler lets a body error propagate, the connection
answers for it: `413` for too large (including `collect(upTo:)`'s own cap), `400` for a
malformed or truncated body. Either way the connection closes. A handler that catches the
error and returns its own response gets that response sent with `connection: close`.

When the handler returns without reading the whole body, the rest is read and discarded so
the next request starts at the right byte, up to 64 KiB (`maxDrainSize`). A longer rest, or a
body that failed, makes the response say `connection: close` instead.

### `Expect: 100-continue`

`HTTP/1.1 100 Continue` is sent when the handler first reads a body that has not arrived yet. A
handler that rejects the request without reading (a `401`, say) sends no `100`; since the
client was never asked to send the body, the response says `close`. If body bytes already
arrived with the head, no `100` is sent. An expectation other than `100-continue` gets
`417 Expectation Failed` and close. HTTP/1.0 requests cannot receive `100`, so their
`100-continue` is ignored.

### Responses and framing

The serializer writes the status line, the handler's fields in order (names in lowercase), a
`date` field unless the response has one, the framing, and `connection`. It owns framing: a
handler's `transfer-encoding` and `connection` fields are not written, nor is its
`content-length` where the serializer writes its own.

| Response body | Framing |
|---|---|
| `.empty` | `content-length: 0` |
| `.bytes(b)` | `content-length` and the bytes, in the same send as the head |
| `.file(region)` | `content-length`; the head is sent, then the file with `sendFile` (`sendfile(2)` on the BSD transport) in slices of at most 1 MiB |
| `.stream(length: n, writer:)` | `content-length: n`; each `write` is one send. Writing more or fewer than `n` bytes aborts the connection |
| `.stream(length: nil, writer:)` | `transfer-encoding: chunked`, one chunk per `write`, then the last chunk. To an HTTP/1.0 request: no framing field and `connection: close`, and the body ends when the connection closes |
| `.tunnel` | No framing field and no `connection` field; see [Upgrades and tunnels](#upgrades-and-tunnels) |

Each `.stream` write returns only once the transport accepted the bytes, so a writer faster
than the client slows down instead of buffering. A writer that throws after the head was sent
aborts the connection (the client sees a truncated body, not a second response).

### HEAD, 204 and 304

| Response | What is sent |
|---|---|
| To `HEAD` | The headers a `GET` would get, with the `content-length` of the content when it is known (`.bytes`, `.file`, `.stream` with a length), and no body. A `.stream` writer or file is never run |
| `304 Not Modified` | Same as `HEAD`: headers only |
| `204 No Content` | No `content-length`, no body |
| `1xx` | The handler's fields only: no `date`, framing or `connection` |

For an `.empty` or chunked body to `HEAD` or `304`, the handler's own `content-length` passes
through, so it can state the length a `GET` would have had.

### When the connection closes

| Cause | What the client gets |
|---|---|
| Request asked for `close`, or HTTP/1.0 without `keep-alive` | The response with `connection: close`, then close |
| Handler's response lists `close` in its `Connection` field | That response with `connection: close`, then close; pipelined requests already read are not answered |
| Malformed head | The error status (below) with an empty body and `connection: close` |
| Handler throws, or returns a field that fails validation (see [Request smuggling defences](#request-smuggling-defences)) | `500` with `connection: close`. Responses already serialized for earlier pipelined requests go out first |
| Client closes between requests or mid-head | Nothing; quiet close |
| Receive or send fails | Nothing; the connection ends |
| Server draining | See [Running on a Mac](running-on-a-mac.md#shutdown-restart-and-reload). A connection between requests (idle, or mid-head) closes at once. A request in flight finishes and its response says `close`; pipelined requests not yet started get no response |

**Lingering close.** When the connection closes with request bytes possibly unread (an error
response, an unread body, dropped pipelined requests, a `408`), the server half-closes its
output and reads and discards input for up to `timeouts.linger` (2 s) or 1 MiB
(`maxLingerSize`). Without this, the client's unread bytes would make the kernel reset the
connection, and the client could lose the error response.

Error responses for malformed heads, `413` for a `Content-Length` over the limit, `417`, the
timeout `408`, and the `500` (or `413`/`400` for a failed body) for a handler that throws are
written by `HTTP1` itself, without calling the handler chain. They still go through the chain's
`ProtocolResponseObserver`s (#0139), which the server finds at startup like connection
observers:

- `ErrorPages` gives every one of them its page, by its usual rules (no page for `HEAD`; the
  page of a `GET` when the head could not be parsed).
- `AccessLog` logs every one with the status and body bytes sent. When the request line is
  unknown (an unparsable head, a header timeout) the line has `-` in its place, as Apache logs
  a bad request: `192.0.2.7 - - [13/Nov/2026:10:00:00 +0000] "-" 400 -`. A handler that throws
  is logged once, by the runner, with the status actually sent.

A response replaced with `500` because a field would split it (#0136) is the exception: the
access log keeps the line it wrote when the handler returned (with the handler's status), and
the replacement is reported in the `os` log.

## Limits and timeouts

| Limit | Default | Swift | `http-config.json` | When exceeded |
|---|---|---|---|---|
| Request line | 8 KiB (excluding CRLF) | `HTTP1ParserLimits.maxRequestLineLength` | – | `414` + close |
| Head size (request line through final CRLF) | 16 KiB | `HTTP1ParserLimits.maxHeadBytes` | – | `431` + close |
| Header fields per head | 100 | `HTTP1ParserLimits.maxHeaderCount` | – | `431` + close |
| Method length | 24 bytes | fixed (`HTTPMethod.Token.maximumLength`) | – | `501` + close |
| Request body | 10 MiB | `HTTP1Configuration.maxBodySize` | `maxBodySize` (alias `maxRequestSize`) | `413` + close |
| Unread body drained before the next request | 64 KiB | `HTTP1Configuration.maxDrainSize` | – | Response says `close` |
| Chunk size | 1 TiB | `ChunkedDecoderLimits.maxChunkSize` | – | `400` + close (`maxBodySize` applies first in practice) |
| Chunk extensions per chunk | 1 KiB | `ChunkedDecoderLimits.maxExtensionLength` | – | `400` + close |
| Trailer section | 8 KiB, 32 fields | `ChunkedDecoderLimits.maxTrailerBytes`, `.maxTrailerFields` | – | `400` + close |
| Bytes per receive | 16 KiB | `HTTP1Configuration.receiveSize` | – | – |
| Output sent early during a pipelined batch | 64 KiB | `HTTP1Configuration.flushThreshold` | – | – |
| Bytes discarded while lingering | 1 MiB | `HTTP1Configuration.maxLingerSize` | – | Close |
| Header timeout: a head must complete this long after its first byte | 10 s | `HTTP1Timeouts.header` | `timeouts.header` | `408` + close |
| Idle timeout: no byte of the next head (also before the first request) | 5 s | `HTTP1Timeouts.idle` | `timeouts.idle` (legacy `keepAliveTimeout`) | Silent close |
| Body timeout: wait for request body bytes, restarted on progress | 30 s | `HTTP1Timeouts.body` | `timeouts.body` | `408` + close |
| Send timeout: one send waiting for the client to accept bytes, restarted per send | 30 s | `HTTP1Timeouts.send` | `timeouts.send` | Connection reset (abort) |
| Linger after an error response | 2 s | `HTTP1Timeouts.linger` | `timeouts.linger` | Close |
| Connections at once (all protocols) | 1024 | `ServerConfiguration.maxConnections` | `maxConnections` | New connections wait in the listen backlog |

Notes:

- The header timeout is not renewed by progress, so a client that trickles a head one byte at
  a time (slowloris) is closed when it passes. Handler time is never limited.
- `nil` in Swift, and `0` or `null` in the config file, turns a timeout off.
  `HTTP1Timeouts.disabled` turns them all off.
- Large `.bytes` and `.file` bodies are sent in slices of 1 MiB, each under its own send
  timeout, so the send limit catches a stalled client, not a slow download.
- The idle timeout also closes idle HTTP/2 connections in the executable (with `GOAWAY`).
- The parser, drain, chunked and buffer limits are not in `http-config.json`; set them in Swift.

## Errors

A malformed head gets one of these statuses, with an empty body and `connection: close`
([HTTP1RequestHead.swift](../../Sources/HTTP1/HTTP1RequestHead.swift), `HTTP1ParseError`):

| Status | Cause |
|---|---|
| `400 Bad Request` | Invalid method token; invalid request target (bad byte, wrong form for the method, userinfo in absolute form, `CONNECT` without `host:port`); malformed version; bare LF or CR; invalid field name; whitespace before `:`; obsolete line folding; invalid byte in a field value (NUL, DEL, other controls); no `Host` on HTTP/1.1; more than one `Host`; both `Transfer-Encoding` and `Content-Length`; `Transfer-Encoding` whose last coding is not `chunked`, that repeats `chunked`, or on HTTP/1.0; invalid `Content-Length`; `Content-Length` values that differ |
| `414 URI Too Long` | Request line over `maxRequestLineLength` |
| `431 Request Header Fields Too Large` | Head over `maxHeadBytes`, or more than `maxHeaderCount` fields |
| `501 Not Implemented` | Method longer than 24 bytes; a transfer coding other than `chunked` before the final `chunked` (`gzip, chunked`) |
| `505 HTTP Version Not Supported` | A well-formed `HTTP/d.d` other than 1.0 and 1.1 |

After a valid head:

| Status | Cause |
|---|---|
| `413 Content Too Large` | `Content-Length` over `maxBodySize` (before the handler runs); a chunked body that grows past it; a handler's `collect(upTo:)` cap exceeded |
| `400 Bad Request` | A malformed chunked body (bad chunk size, missing CRLF, invalid extension or trailer), or a body cut short by the client |
| `408 Request Timeout` | Header or body timeout |
| `417 Expectation Failed` | `Expect` with anything other than `100-continue` |
| `500 Internal Server Error` | The handler threw, or returned a `.tunnel` body with a `1xx` status other than `101` |

### Request smuggling defences

Request smuggling relies on two parsers disagreeing about where a body ends. The parser takes
the strict reading of RFC 9112 everywhere:

- **`Transfer-Encoding` with `Content-Length`** is rejected with `400`, not resolved in favour
  of one of them.
- **`Transfer-Encoding` must end in `chunked`**, exactly once. `chunked, chunked`, `gzip` alone
  and `chunked, gzip` are `400`; `gzip, chunked` is `501` (an unsupported coding). HTTP/1.0
  requests may not use `Transfer-Encoding` at all.
- **`Content-Length`** must be decimal digits. Several fields or list elements are accepted
  only if every value is the same (`5, 5`); different values are `400`.
- **Line endings** must be CRLF; a bare LF or CR anywhere in the head, or in a chunk-size or
  trailer line, is an error.
- **Obsolete line folding** and **whitespace before `:`** are rejected, so a field cannot hide
  inside another or be read under a different name.
- **`Host`**: exactly one on HTTP/1.1, at most one on HTTP/1.0.
- **Every error closes the connection** (with a lingering close), so bytes after a bad
  request are never parsed as the next request.
- **Body reads never cross the boundary**: a `Content-Length` body receives at most the bytes
  still owed; bytes received past the end of a chunked body go back to the receive buffer for
  the next head.

The test-support `ReferenceHTTP1Parser` implements the same rules independently, and
`HTTP1DifferentialTests` checks that both parsers agree over a corpus of valid and invalid
requests split at every byte offset
([Tests/HTTP1Tests](../../Tests/HTTP1Tests)).

On the response side, every handler response is checked before it is written, in release
builds too (`HTTPFieldValidation`, #0136): each field name must be a token, and no field value
or custom reason phrase may hold CR, LF, NUL, another control byte or DEL (a tab is fine). A
response that fails is never written as is: it is replaced with a bare `500` with
`connection: close`, like a handler that throws, and an error is logged (`os` log, subsystem
`SwiftWebServer`, category `HTTP`). So a handler that copies decoded request bytes into a
`location` cannot split the response, but it gets a `500`; validate or encode such values to
answer properly. HTTP/2 and HTTP/3 run the same check and answer the stream with a bare `500`.
Code that serializes responses itself uses `HTTP1Serializer.writeValidated`, which throws
instead of writing; chunked trailers that fail the check are dropped.

## Upgrades and tunnels

A handler takes over the connection by returning a `.tunnel` body. `HTTP1` sends the head,
then hands the byte stream to the closure, replaying any bytes the client sent after the
request. No HTTP/1.1 limit or timeout applies to a tunnel, and a server drain does not
interrupt it: the closure gets the shutdown signal in its `TunnelContext` and should end itself
when it fires; a tunnel still running at the drain deadline is cancelled.

```swift
HTTPResponse(status: .switchingProtocols, headers: upgradeHeaders, body: .tunnel { transport, context in
    // read and write `transport` until done; watch `context.shutdown`
})
```

- **WebSockets**: `WebSocketUpgrade` answers an RFC 6455 handshake on HTTP/1.1 with
  `101 Switching Protocols` and runs the session over the tunnel. See
  [WebSockets](websockets.md) and [Dynamic websites](dynamic-sites.md#websockets).
- **Proxied upgrades**: `ReverseProxy` mounts with `"websocket": true` tunnel the upgraded
  connection to the upstream. See [the proxy reference](dynamic-sites.md#proxy-mount-reference).
- **`CONNECT`**: the parser accepts `CONNECT host:port` and passes it to the handler chain, and
  a `2xx` response with a `.tunnel` body is sent without framing. No shipped component answers
  `CONNECT`: there is no forward proxy.
- **h2c Upgrade** (`Upgrade: h2c`) is not supported. Cleartext HTTP/2 is available only with
  prior knowledge (`"http2": {"cleartext": true}`), which is chosen by sniffing before HTTP/1.1
  runs.

## Using HTTP1 in your own server

Register `HTTP1` (or `TLSNegotiated(HTTP2(), fallback: HTTP1())` when you also serve HTTPS
with HTTP/2) with a `Server`. Pass an `HTTP1Configuration` to change limits:

```swift
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport
import Router

let http1 = HTTP1(configuration: HTTP1Configuration(
    parserLimits: HTTP1ParserLimits(maxRequestLineLength: 4 * 1024, maxHeaderCount: 64,
                                    maxHeadBytes: 8 * 1024),
    maxBodySize: 50 * 1024 * 1024,
    timeouts: HTTP1Timeouts(header: .seconds(5), idle: .seconds(15))))   // others keep defaults

let router = try Router {
    POST("/upload") { request, _ in
        var received = 0
        for try await chunk in request.body { received += chunk.readableBytes }   // read on demand
        return HTTPResponse(status: .ok, body: .bytes(ByteBuffer(bytes: Array("\(received)\n".utf8))))
    }
    GET("/count") { _, _ in
        // No length: chunked on HTTP/1.1, close-delimited on HTTP/1.0.
        HTTPResponse(status: .ok, body: .stream(length: nil, writer: { writer in
            for i in 1...3 { try await writer.write(ByteBuffer(bytes: Array("\(i)\n".utf8))) }
        }))
    }
}
let listener = try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: 8080))
let server = Server(configuration: ServerConfiguration(maxConnections: 512),
                    listeners: [listener], protocols: [http1]) {
    router
}
try await server.run()
```

This type-checks against this checkout. A complete package with signal handling, static files
and WebSockets is
[Examples/custom-server](../../Examples/custom-server/Sources/MySite/MySite.swift), walked
through in [Choosing components](choosing-components.md#a-custom-server-package).

If you load `http-config.json` with `ConfigFile`, `settings.http1Configuration` gives the
`HTTP1Configuration` the executable uses (`maxBodySize` and `timeouts` from the file, every
other field at its default), so you can start from it and change the rest:

```swift
var configuration = settings.http1Configuration
configuration.parserLimits.maxHeadBytes = 32 * 1024
let http1 = HTTP1(configuration: configuration)
```

## Configuring the executable

HTTP/1.1 is always on. Its keys in `http-config.json`, with their defaults:

```json
{
  "maxBodySize": 10485760,
  "timeouts": {
    "header": 10,
    "idle": 5,
    "body": 30,
    "send": 30,
    "linger": 2
  },
  "maxConnections": 1024
}
```

- Durations are seconds; fractions are allowed; `0` or `null` turns a limit off; a missing key
  keeps its default. Unknown keys under `timeouts` print a warning and are ignored.
- `maxBodySize` also sets HTTP/2's body limit unless `http2.maxRequestBodySize` is set.
- These keys need a restart: `SIGHUP` reloads the handler chain but reports changes to
  `timeouts`, `maxBodySize`, `maxConnections` and `http2` as ignored.
- The full reference, including legacy aliases, is in
  [Running on a Mac](running-on-a-mac.md#listening-and-limits).

For long uploads over slow links raise `timeouts.body`; for long-polling or server-sent events
raise or turn off `timeouts.send` only if clients stall reading, since the send timeout
restarts with every send. Handler time itself is never limited.

## Performance

All numbers are from the owner's Apple M4 Pro over loopback, on a shared machine; each record
gives its load average and method.

| What | Result | Record |
|---|---|---|
| Head parse, 10-header browser request | About 130 ns, 0 allocations; minimal request about 27 ns | [M1.3-parser](../benchmarks/M1.3-parser.md), [M-final-micro](../benchmarks/M-final-micro.md) |
| Serialize a `200` with 5 headers | About 75 ns, 0 allocations; a chunk header about 23 ns | [M-final-micro](../benchmarks/M-final-micro.md) |
| Connection loop per request (parse, handler call, serialize, send bookkeeping) | About 250 ns keep-alive, 177 ns with 16 pipelined requests per receive, 0 allocations; the timeout supervision added no measurable cost | [M3.3-timeouts](../benchmarks/M3.3-timeouts.md), [M3.1-h1conn](../benchmarks/M3.1-h1conn.md) |
| Request bodies | Echoing a 1 KiB `POST` body costs a few percent against a `GET`; a 4 MiB body keeps memory at one receive | [M3.2-bodies](../benchmarks/M3.2-bodies.md) |
| Static files over keep-alive | About 93k req/s at 16 connections, 97k at 64 | [compare-servers-final](../benchmarks/compare-servers-final.md) |
| New connections | About 22k/s on the BSD listener | [M3-accept](../benchmarks/M3-accept.md) |

The [performance notes](performance.md) summarize the rest. What matters for HTTP/1.1:

- Keep-alive is where the server is fast; closing after every response is dominated by TCP
  setup. Leave the idle timeout long enough for your clients to reuse connections.
- Keep the default `TLSNegotiated` registration (`http2.cleartext` off) so cleartext
  connections are not sniffed.
- Prefer `.file` for files (`sendfile(2)` on the BSD transport) and `.bytes` for small
  in-memory bodies (sent with the head in one send); `.stream` costs one send per write.

## Standards

- [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110): HTTP Semantics (methods, status codes,
  `Expect`, `HEAD`, `204`/`304` rules, `Content-Length`)
- [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112): HTTP/1.1 (message syntax, request-target
  forms, body framing and chunked coding, persistence, pipelining, lingering close)
- [RFC 7301](https://www.rfc-editor.org/rfc/rfc7301): TLS ALPN (`http/1.1`, `h2`)
- [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455): The WebSocket Protocol (the HTTP/1.1
  upgrade)
