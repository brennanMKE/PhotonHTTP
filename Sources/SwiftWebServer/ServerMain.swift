import ConfigFile
import Dispatch
import Foundation
import HTTP1
#if HTTP3
import HTTP3
#endif
import HTTPCore
import HTTPServer
import NetworkTransport

/// The shipped server (#0086): `Server` + HTTP/1.1 + `ErrorPages` + `StaticFiles`
/// (with conditional requests), configured by `http-config.json` and the command line.
///
/// Protocols (#0119): HTTP/2 is on by default for TLS (ALPN `h2`, `http/1.1`); cleartext h2c
/// only with `"http2": {"cleartext": true}`. See ``ServerProtocols``.
///
/// Listeners (#0089): cleartext HTTP/1.1 always; HTTPS when the config has `tls`; HTTP/3 over
/// QUIC when it also has `http3` (by default on the TLS port number, UDP). All run under one
/// `Server`: one connection limit, one drain, and SIGTERM sends HTTP/3 GOAWAY too.
///
/// Exit status: 0 after a clean shutdown (SIGINT or SIGTERM drains open connections), 1 on a
/// configuration or startup error such as a bad config value or a port in use (#0004), with
/// a message on stderr, 2 on a usage error.
@main
enum ServerMain {
    static let name = "SwiftWebServer"

    static let usage = """
        usage: SwiftWebServer [--config FILE] [--root DIR] [--host HOST] [--port PORT]

          --config FILE   JSON config (see README "Configuration"); every key is optional.
                          Default: $ROOT_PATH/http-config.json when ROOT_PATH is set, else
                          ./http-config.json if it exists, else built-in defaults.
          --root DIR      directory to serve (overrides "root"; relative to the working
                          directory)
          --host HOST     numeric address to bind (overrides "host"; default 127.0.0.1)
          --port PORT     port to bind (overrides "port"; default 8080; 0 picks a free one)

        Relative paths in the config file resolve against the file's directory. HTTPS,
        HTTP/2 and HTTP/3 are configured with the "tls", "http2" and "http3" keys. Prints "listening HOST:PORT"
        on stdout once bound (then "listening HOST:PORT (https)" and "(h3)" lines for the
        other listeners). SIGINT/SIGTERM shut down gracefully. SIGHUP reopens the access log and
        reloads the configuration and the TLS identity file. The server also watches the
        config file and the files it names and reloads when they change ("reload": {"watch":
        true, "interval": 2}). A reload that changes listener, protocol or limit keys is
        rejected whole; they need a restart. SIGUSR2 restarts gracefully in the same process:
        new listeners on the same ports start accepting, then the old ones drain. The server
        writes its status to run/status.json next to the config ("statusFile").

               SwiftWebServer check | reload | status | restart [--config FILE] ...

        check a config, reload or restart the running server, show its status (see
        `SwiftWebServer check --help`).
        """

    static func main() async {
        exit(await run(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment))
    }

    /// Command-line overrides.
    struct Options {
        var config: String?
        var root: String?
        var host: String?
        var port: UInt16?
        var help = false
    }

    struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    static func parse(_ arguments: [String]) throws(UsageError) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            var argument = arguments[index]
            index += 1
            var value: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                value = String(argument[argument.index(after: equals)...])
                argument = String(argument[..<equals])
            }
            if argument == "--help" || argument == "-h" {
                options.help = true
                continue
            }
            guard ["--config", "--root", "--host", "--port"].contains(argument) else {
                throw UsageError(description: "unknown argument '\(argument)'")
            }
            if value == nil {
                guard index < arguments.count else { throw UsageError(description: "missing value for \(argument)") }
                value = arguments[index]
                index += 1
            }
            let text = value!
            switch argument {
            case "--config": options.config = text
            case "--root": options.root = text
            case "--host": options.host = text
            default:
                guard let port = UInt16(text) else { throw UsageError(description: "invalid port '\(text)'") }
                options.port = port
            }
        }
        return options
    }

    /// The config file the options name: `--config`, else `$ROOT_PATH/http-config.json` or
    /// `./http-config.json` when it exists, else `nil` (built-in defaults).
    static func configPath(_ options: Options, environment: [String: String]) -> String? {
        if let path = options.config { return path }
        let candidate = ServerSettings.resolve("http-config.json", against: defaultBase(environment))
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// Legacy compatibility: ROOT_PATH is the directory holding http-config.json.
    static func defaultBase(_ environment: [String: String]) -> String {
        environment["ROOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.currentDirectoryPath
    }

    /// The settings: config file, then command-line overrides. Warnings go to stderr.
    static func settings(_ options: Options, environment: [String: String]) throws(ConfigFileError) -> ServerSettings {
        try loadSettings(options, environment: environment).settings
    }

    /// The settings and the SHA-256 of the config file they were read from (#0143).
    static func loadSettings(_ options: Options, environment: [String: String])
        throws(ConfigFileError) -> (settings: ServerSettings, sha256: String?) {
        let fileManager = FileManager.default
        var defaults = ServerSettings()
        if options.config == nil { defaults.baseDirectory = defaultBase(environment) }
        var settings = defaults
        var sha256: String?
        if let path = configPath(options, environment: environment) {
            let file = try ConfigFile.load(path: path, defaults: defaults)
            for warning in file.warnings { printError("\(name): warning: \(warning)") }
            settings = file.settings
            sha256 = file.contentSHA256
        }
        if let root = options.root {
            settings.root = root
            settings.baseDirectory = fileManager.currentDirectoryPath
        }
        if let host = options.host { settings.host = host }
        if let port = options.port { settings.port = port }
        return (settings, sha256)
    }

    static func run(_ arguments: [String], environment: [String: String]) async -> Int32 {
        // #0143: `check`, `reload`, `status` (and `restart`, #0144) talk to a running server.
        if let first = arguments.first, let command = ControlCommand(rawValue: first) {
            return await command.run(Array(arguments.dropFirst()), environment: environment)
        }
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            printError("\(name): \(error)\n\n\(usage)")
            return 2
        }
        if options.help {
            print(usage)
            return 0
        }
        do {
            let loaded = try loadSettings(options, environment: environment)
            let settings = loaded.settings
            try settings.validate()
            // #0140: the HTTPS and HTTP/3 listeners take the identity from this store on every
            // handshake, so SIGHUP can swap in a renewed certificate without a restart.
            let identityStore = try loadIdentity(settings, environment: environment).map(TLSIdentityStore.init)
            // #0144: what a graceful restart replaces.
            let running = RunningState(settings: settings, identity: identityStore)
            let configPath = configPath(options, environment: environment)
            // #0143: the status file the control commands read; only with a config file.
            let status = StatusRecorder(config: configPath, sha256: loaded.sha256, arguments: arguments,
                                        settings: settings)
            let configuration = settings.serverConfiguration
            do {
                try configuration.validate()
            } catch {
                throw ConfigFileError("\(error)")
            }
            let protocols = try ServerProtocols.make(settings)
            let listeners = try makeListeners(settings, identity: identityStore)
            if settings.hosts.isEmpty {
                printError("\(name): serving \(settings.resolvedRoot)")
            } else {
                for host in settings.hosts {   // #0092
                    let names = host.isDefault ? host.names + ["(default)"] : host.names
                    printError("\(name): serving \(names.joined(separator: ", ")) from \(ServerSettings.resolve(host.root, against: settings.baseDirectory))")
                }
            }
            let launch = Launch(options: options, environment: environment, arguments: arguments,
                                configPath: configPath, status: status, running: running)
            #if HTTP3
            if let http3 = settings.http3 {
                // #0103: HTTPS responses advertise HTTP/3. Registered only with HTTP/3, so the
                // chain has no Alt-Svc step otherwise; rendered once the UDP port is bound.
                // Inside the reloadable chain (#0144), so a restart that moves the UDP port
                // swaps in a new advertisement.
                let altSvc = AltSvcSlot(AltSvc(maxAge: http3.altSvcMaxAge))
                let inner = try settings.makeHandler(environment: environment)
                let first = altSvc.current
                let handler = ReloadableHandler(MiddlewareBuilder.build {
                    first
                    inner
                })
                return await launch.serve(settings, listeners: listeners, protocols: protocols, handler: handler,
                                          advertisesHTTP3: true) { next, restart throws(ConfigFileError) in
                    let inner = try next.makeHandler(environment: environment)
                    let advertisement = restart ? AltSvc(maxAge: next.http3?.altSvcMaxAge ?? 0) : altSvc.current
                    if restart { altSvc.prepare(advertisement) }
                    return MiddlewareBuilder.build {
                        advertisement
                        inner
                    }
                } bound: { addresses, names, restart in
                    if restart { altSvc.commit() }
                    if let index = names.firstIndex(of: "h3") { altSvc.current.advertise(port: addresses[index].port) }
                }
            }
            #endif
            let handler = ReloadableHandler(try settings.makeHandler(environment: environment))
            return await launch.serve(settings, listeners: listeners, protocols: protocols, handler: handler,
                                      advertisesHTTP3: false) { next, _ throws(ConfigFileError) in
                try next.makeHandler(environment: environment)
            }
        } catch {
            printError("\(name): \(error)")
            return 1
        }
    }

    /// `SIGHUP` (#0127) or a changed file (#0142): reads the configuration again (same file
    /// and command-line overrides) and swaps in a chain built from it for new requests. The
    /// access log files are reopened by their paths either way, for log rotation.
    ///
    /// A configuration that changes listener, protocol or connection-limit keys is rejected
    /// whole (#0143): nothing of it applies, the running configuration stays, and stderr and
    /// the status file name the keys and say to run `SwiftWebServer restart`. A configuration
    /// that does not load, validate or build is reported and the running one stays.
    ///
    /// The TLS identity file is reread too (#0140), even when `tls` is unchanged, since a
    /// renewal usually replaces the file at the same path: see ``reloadIdentity(_:settings:environment:)``.
    /// Returns the settings now running, or `nil` when the running configuration stays.
    static func reload<H: HTTPHandler>(
        _ handler: ReloadableHandler<H>, identity: TLSIdentityStore?, startup: ServerSettings, options: Options,
        environment: [String: String], trigger: ConfigReloader.Trigger, status: StatusRecorder,
        build: (ServerSettings) throws(ConfigFileError) -> H
    ) -> ServerSettings? {
        switch trigger {
        case .signal:
            printError("\(name): signal \(SIGHUP), reloading the configuration")
        case .watch(let changed):
            printError("\(name): \(changed.joined(separator: ", ")) changed, reloading the configuration")
        }
        do {
            let (next, sha256) = try loadSettings(options, environment: environment)
            try next.validate()
            // Restart-only keys were never applied, so the startup values are the running ones.
            let restart = next.restartOnlyChanges(comparedTo: startup)
            if !restart.isEmpty {
                handler.reopenAccessLogs()
                let message = ControlCommand.restartMessage(restart)
                printError("\(name): reload rejected, keeping the running configuration: \(message)")
                status.rejected(trigger: trigger, next: next, restartRequired: restart, message: message)
                return nil
            }
            let chain = try build(next)
            // The old chains' remaining lines go to the reopened file too.
            handler.reopenAccessLogs()
            handler.replace(with: chain)
            if let identity { reloadIdentity(identity, settings: next, environment: environment) }
            printError("\(name): reloaded the configuration")
            status.reloaded(trigger: trigger, next: next, sha256: sha256)
            return next
        } catch {
            handler.reopenAccessLogs()
            printError("\(name): reload failed, keeping the running configuration: \(error)")
            status.failed(trigger: trigger, message: "\(error)")
            return nil
        }
    }

    /// Imports the `tls` identity in memory only (`kSecImportToMemoryOnly`: no keychain
    /// access, AGENTS.md), or returns `nil` without `tls`.
    static func loadIdentity(_ settings: ServerSettings, environment: [String: String]) throws(ConfigFileError) -> TLSIdentity? {
        guard settings.tls != nil, let path = settings.resolvedIdentityPath,
              let password = try settings.tlsPassword(environment: environment) else { return nil }
        do {
            return try TLSIdentity(pkcs12Path: path, password: password)
        } catch {
            throw ConfigFileError(key: "tls.identity", "cannot load TLS identity \(path): \(error)")
        }
    }

    /// SIGHUP (#0140): rereads the identity file named by `settings` and, when its certificate
    /// differs, makes the running HTTPS and HTTP/3 listeners present it to new handshakes.
    /// Established connections keep the certificate they negotiated. If the file cannot be
    /// loaded, the current identity stays and a warning says why. Every outcome is printed.
    static func reloadIdentity(_ store: TLSIdentityStore, settings: ServerSettings, environment: [String: String]) {
        guard settings.tls != nil else { return }   // removing `tls` is reported as restart-only
        let path = settings.resolvedIdentityPath ?? "?"
        let identity: TLSIdentity
        do {
            guard let loaded = try loadIdentity(settings, environment: environment) else { return }
            identity = loaded
        } catch {
            printError("\(name): warning: reload: \(error.description); keeping the current TLS certificate")
            return
        }
        if identity.certificateDER == store.identity.certificateDER {
            printError("\(name): reload: TLS identity \(path) unchanged")
        } else {
            store.replace(with: identity)
            printError("\(name): reload: TLS identity \(path) reloaded; new HTTPS and HTTP/3 handshakes use the new certificate")
        }
    }

    /// Cleartext first, then TLS, then QUIC: the server binds them in this order, so the QUIC
    /// listener can take the TLS listener's port number when that was 0. The TLS listener
    /// offers the protocol registry's ALPN tokens (#0088). Both secure listeners present the
    /// identity in `identity` (#0140).
    static func makeListeners(_ settings: ServerSettings, identity: TLSIdentityStore?) throws -> [ServerListener] {
        // POSIX sockets by default, Network.framework on request (#0113).
        let tcp = TCPConfiguration(allowLocalEndpointReuse: false)
        let host = settings.host
        // #0144: each listener names its address, so a graceful restart keeps it served.
        func at(_ port: UInt16) -> TransportAddress { TransportAddress(host: host, port: port) }
        var listeners: [ServerListener] = []
        switch settings.transport {
        case .bsd:
            listeners.append(.byteStream(try BSDSocketListener(configuration: .init(host: host, port: settings.port, tcp: tcp)), name: "http")
                .restartable(address: at(settings.port), identity: "http"))
        case .nw:
            listeners.append(.byteStream(try TCPListener(configuration: .init(host: host, port: settings.port, tcp: tcp)), name: "http")
                .restartable(address: at(settings.port), identity: "http nw"))
        }
        guard let tls = settings.tls, let identity else { return listeners }
        listeners.append(ServerListener.byteStream(name: "https") { bind in
            try TCPListener(configuration: .init(host: host, port: tls.port, tcp: tcp),
                            tls: TLSConfiguration(identityStore: identity, alpn: bind.alpnTokens))
        }.restartable(address: at(tls.port), identity: "https"))

        if let http3 = settings.http3 {
            #if HTTP3
            let tlsIndex = listeners.count - 1
            // After GOAWAY and the last response, wait for the client to close (curl does at
            // once) for up to the drain timeout instead of the default 1 s: CONNECTION_CLOSE
            // discards response bytes Network.framework still buffers for a slow reader.
            var configuration = H3Configuration()
            configuration.timeouts.closeLinger = max(.seconds(1), settings.drainTimeout ?? .seconds(30))
            configuration.qpackMaxTableCapacity = http3.qpackMaxTableCapacity
            configuration.qpackBlockedStreams = http3.qpackBlockedStreams
            listeners.append(ServerListener.multiplexed(name: "h3", protocol: HTTP3(configuration: configuration)) { bind in
                let port = http3.port ?? bind.boundAddresses[tlsIndex].port
                return try QUICListener(configuration: .init(host: host, port: port, quic: QUICConfiguration(alpn: bind.alpnTokens)),
                                        identityStore: identity)
            }.restartable(address: at(http3.port ?? tls.port), identity: "h3"))
            #else
            _ = http3
            throw ConfigFileError(key: "http3", "\"http3\": this build has no HTTP/3 (package trait HTTP3 is off)")
            #endif
        }
        return listeners
    }

    /// The configured ports, for error messages: `8080`, or `8080, https 8443, h3 8443`.
    static func ports(_ settings: ServerSettings) -> String {
        var text = "\(settings.port)"
        if let tls = settings.tls {
            text += ", https \(tls.port)"
            if let http3 = settings.http3 { text += ", h3 \(http3.port.map(String.init) ?? "\(tls.port)")" }
        }
        return text
    }

    /// A transport error with its POSIX meaning (`failed(code: 48)` reads "address already in use").
    static func describe(_ error: any Error) -> String {
        if let restart = error as? ServerRestartError {
            var text = "listener \(restart.listener)"
            if let address = restart.address { text += " on \(address)" }
            text += ": \(describe(restart.underlying))"
            if let closed = restart.closedRunningListener {
                return text + "; the running listener \(closed) had to close first and no longer serves"
            }
            return text
        }
        if case TransportError.failed(let code) = error, code > 0 {
            return "\(String(cString: strerror(code))) (errno \(code))"
        }
        return "\(error)"
    }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
