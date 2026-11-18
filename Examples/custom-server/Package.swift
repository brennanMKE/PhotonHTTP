// swift-tools-version: 6.2
// A custom server built from PhotonHTTP's library products: static files, a Router API,
// a WebSocket echo, compression and an access log, over HTTP/1.1 (HTTP/2 once a TLS
// listener negotiates it). See docs/guide/choosing-components.md. In your own package,
// replace the path dependency with
// .package(url: "https://github.com/brennanMKE/PhotonHTTP.git", branch: "main").
import PackageDescription

let package = Package(
    name: "MySite",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "PhotonHTTP", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "MySite",
            dependencies: [
                .product(name: "HTTPCore", package: "PhotonHTTP"),
                .product(name: "HTTP1", package: "PhotonHTTP"),
                .product(name: "HTTP2", package: "PhotonHTTP"),
                .product(name: "HTTPServer", package: "PhotonHTTP"),
                .product(name: "NetworkTransport", package: "PhotonHTTP"),
                .product(name: "StaticFiles", package: "PhotonHTTP"),
                .product(name: "Router", package: "PhotonHTTP"),
                .product(name: "WebSockets", package: "PhotonHTTP"),
                .product(name: "Compression", package: "PhotonHTTP"),
                .product(name: "AccessLog", package: "PhotonHTTP"),
            ]),
    ]
)
