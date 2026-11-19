# Documentation

How PhotonHTTP is put together, how to pick the parts you need, how to run it on a Mac for static and dynamic websites, and how each protocol works.

## Start here

- [Getting started](https://photon-http.sstools.co/docs/getting-started.md): Install the photon command with one line and serve any folder as a static website with photon serve.
- [Overview and architecture](https://photon-http.sstools.co/docs/overview.md): Core and optional components, HTTP/1.1, HTTP/2 and HTTP/3, the transports, the concurrency model and the handler chain.

## Run a site

- [Running on a Mac](https://photon-http.sstools.co/docs/running-on-a-mac.md): The photon command line and control commands, the complete http-config.json reference, certificates, public binding, LaunchAgents, logs, reload, restart and shutdown.
- [Static websites](https://photon-http.sstools.co/docs/static-sites.md): StaticFiles, caching and conditional requests, Range, error pages, compression, virtual hosts and authentication.
- [Dynamic websites](https://photon-http.sstools.co/docs/dynamic-sites.md): In-process Swift with Router and WebSockets; reverse proxy to local apps; Apache mod_proxy mapping; a production checklist.
- [TLS](https://photon-http.sstools.co/docs/tls.md): PKCS#12 identities loaded in memory (never the keychain), ALPN and protocol selection, versions and options, getting certificates, testing safely.

## Protocols

- [HTTP/1.1](https://photon-http.sstools.co/docs/http1.md): The request lifecycle, keep-alive and pipelining, bodies and chunked coding, every limit and timeout, error codes and smuggling defences.
- [HTTP/3](https://photon-http.sstools.co/docs/http3.md): QUIC from Network.framework, Alt-Svc discovery, streams and QPACK, limits and abuse defences, known limitations, testing with curl.
- [WebSockets](https://photon-http.sstools.co/docs/websockets.md): In-process endpoints, the message API, the handshake over HTTP/1.1, HTTP/2 and HTTP/3, permessage-deflate, limits, close codes and proxying.

## Build your own server

- [Choosing components](https://photon-http.sstools.co/docs/choosing-components.md): Every target and library product, what it depends on and when to include it; building your own server as a Swift package.
- [Performance notes](https://photon-http.sstools.co/docs/performance.md): Benchmark results against nginx, lighttpd, h2o, Apache and Caddy, per-request costs, and what they mean for configuration.

## More

Design and project records live in the repository: [ROADMAP](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/ROADMAP.md) (the design, authoritative), [MIDDLEWARE](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/MIDDLEWARE.md), [SERVER-COMPARISON](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/SERVER-COMPARISON.md) and [benchmarks](https://github.com/brennanMKE/PhotonHTTP/blob/main/docs/benchmarks/README.md).
