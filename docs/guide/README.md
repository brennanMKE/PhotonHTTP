# PhotonHTTP guide

How PhotonHTTP is put together, how to pick the parts you need, how to run it on a Mac
for static and dynamic websites, and how each protocol (HTTP/1.1, HTTP/3, WebSockets, TLS) works.

| Guide | Read it for |
|---|---|
| [Overview and architecture](overview.md) | Core vs optional components, HTTP/1.1, HTTP/2 and HTTP/3, the transports, the handler chain and its order |
| [Choosing components](choosing-components.md) | Every target and product, what it depends on and when to include it; building your own server as a Swift package |
| [Running on a Mac](running-on-a-mac.md) | Release builds, the complete `http-config.json` reference, TLS certificates, public binding, the firewall prompt, ports 80/443, LaunchAgents, logs, shutdown |
| [HTTP/1.1](http1.md) | The request lifecycle on a connection, keep-alive and pipelining, bodies and chunked coding, every limit and timeout, error codes and smuggling defences |
| [HTTP/3](http3.md) | QUIC from Network.framework, Alt-Svc discovery, streams and QPACK, limits and abuse defences, known limitations, testing with curl |
| [WebSockets](websockets.md) | In-process endpoints, the message API, handshake over HTTP/1.1, HTTP/2 and HTTP/3, permessage-deflate, limits and close codes, proxying |
| [TLS](tls.md) | Identities in memory (no keychain), ALPN and protocol selection, versions and options, getting certificates, testing safely, troubleshooting |
| [Static websites](static-sites.md) | StaticFiles, error pages, compression, caching and conditional requests, Range, virtual hosts, authentication |
| [Dynamic websites](dynamic-sites.md) | In-process Swift with Router and WebSockets; reverse proxy to local apps (Go example, Laya decision server); Apache `mod_proxy` mapping; production checklist |
| [Performance notes](performance.md) | What the benchmarks say, with links to the records |

Quick start, from the repository root:

```bash
swift build -c release -j 2 --product photon
.build/release/photon --config Root/http-config.json   # serves Root/Public
curl http://127.0.0.1:8080/
```

Other references: [ROADMAP.md](../ROADMAP.md) (the design, authoritative),
[MIDDLEWARE.md](../MIDDLEWARE.md) (the middleware builder in depth),
[SERVER-COMPARISON.md](../SERVER-COMPARISON.md) and [benchmarks/](../benchmarks/README.md).
