import CommonCrypto
public import Foundation

/// The running server's status file (#0143): written by the server at startup, after every
/// reload and restart (#0144) and at exit, read by `SwiftWebServer check`, `reload` and `status`. There is no
/// control socket: the CLI signals the pid and reads this file.
///
/// Written atomically (a temporary file renamed into place) with mode 0600. It holds no
/// settings values, only digests of them (``ServerSettings/settingDigests``), so a CLI can
/// tell which keys a config file would change.
public struct ServerStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case running
        case stopped
    }

    /// The outcome of a reload, or of a graceful restart (trigger `restart`, #0144).
    public enum Result: String, Codable, Sendable {
        /// The new configuration runs.
        case reloaded
        /// It did not load, validate or build; the running configuration stays.
        case failed
        /// It changes keys that need a restart; the running configuration stays, whole.
        case rejected
        /// A graceful restart applied the whole configuration (#0144). A restart that fails
        /// records ``failed``.
        case restarted
    }

    public struct Reload: Codable, Sendable, Equatable {
        public var time: Date
        /// `signal` or `watch`, or `restart` for a graceful restart (#0144).
        public var trigger: String
        public var result: Result
        /// One line: what happened, or why not.
        public var message: String
        /// Keys whose values changed (reloaded) or would have (rejected).
        public var changed: [String]
        /// The restart-only keys that caused a rejection.
        public var restartRequired: [String]

        public init(time: Date, trigger: String, result: Result, message: String,
                    changed: [String] = [], restartRequired: [String] = []) {
            self.time = time
            self.trigger = trigger
            self.result = result
            self.message = message
            self.changed = changed
            self.restartRequired = restartRequired
        }
    }

    public var state: State
    public var pid: Int32
    public var started: Date
    /// The config file, absolute; `nil` with built-in defaults.
    public var config: String?
    /// SHA-256 (hex) of the config file's bytes as last loaded successfully.
    public var configSHA256: String?
    /// The server's command-line arguments (the overrides a `check` must apply too).
    public var arguments: [String]
    /// `HOST:PORT` per listener, in listener order.
    public var listening: [String]
    /// ``ServerSettings/settingDigests`` of the running configuration.
    public var settings: [String: String]
    /// Reloads and restarts attempted so far.
    public var reloads: Int
    public var lastReload: Reload?
    /// Restart-only keys changed in the config file but not applied: the last reload was
    /// rejected for them. Empty once a reload succeeds.
    public var restartRequired: [String]
    /// When this file was written.
    public var updated: Date
    /// When the last graceful restart (#0144) applied a configuration; `nil` before one.
    public var restarted: Date?

    public init(state: State = .running, pid: Int32, started: Date, config: String?, configSHA256: String?,
                arguments: [String], listening: [String] = [], settings: [String: String], reloads: Int = 0,
                lastReload: Reload? = nil, restartRequired: [String] = [], updated: Date? = nil) {
        self.state = state
        self.pid = pid
        self.started = started
        self.config = config
        self.configSHA256 = configSHA256
        self.arguments = arguments
        self.listening = listening
        self.settings = settings
        self.reloads = reloads
        self.lastReload = lastReload
        self.restartRequired = restartRequired
        self.updated = updated ?? started
    }

    /// Writes the file at `path` atomically with mode 0600, creating its directory.
    public func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(self)
        data.append(0x0A)
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Reads the file at `path`; `nil` when it does not exist or does not decode.
    public static func read(from path: String) -> ServerStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ServerStatus.self, from: data)
    }

    /// True when the file says running and process `pid` exists.
    public var isRunning: Bool {
        guard state == .running, pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension ServerSettings {
    /// Every key in a canonical order, restart-only keys (``restartOnlyKeys``) among them, with
    /// a text form of its value that is the same in every process (dictionaries sorted), so
    /// two processes can compare settings by digest (#0143). Paths are resolved.
    public var comparisonValues: [(key: String, value: String)] {
        var values: [(key: String, value: String)] = [
            ("host", host),
            ("port", "\(port)"),
            ("transport", transport.rawValue),
            ("tls", tls == nil ? "off" : "on"),
        ]
        if let tls {
            values.append(("tls.port", "\(tls.port)"))
            values.append(("tls.identity", "\(resolvedIdentityPath ?? "") \(tls.password)"))
        }
        values += [
            ("http3", String(describing: http3)),
            ("http2", String(describing: http2)),
            ("maxConnections", "\(maxConnections)"),
            ("drainTimeout", String(describing: drainTimeout)),
            ("timeouts", String(describing: timeouts)),
            ("maxBodySize", "\(maxBodySize)"),
            ("root", resolvedRoot),
            ("index", "\(index)"),
            ("mimeTypes", "\(mimeTypes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })"),
            ("defaultMimeType", defaultMimeType),
            ("blockList", "\(blockList)"),
            ("blockDotfiles", "\(blockDotfiles)"),
            ("caching", String(describing: maxAge)),
            ("compression", String(describing: compression)),
            ("errorPages", errorPagesDescription),
            ("hosts", "\(baseDirectory) \(hosts)"),
            ("auth", "\(baseDirectory) \(auth)"),
            ("proxy", "\(proxy)"),
            ("accessLog", "\(resolvedAccessLogPath ?? "") \(String(describing: accessLog))"),
            ("reload", "\(reload)"),
            ("statusFile", statusFile ?? "off"),
        ]
        return values
    }

    var errorPagesDescription: String {
        switch errorPages {
        case .off: "off"
        case .generated: "generated"
        case .files(let pages): "files \(pages.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })"
        }
    }

    /// The keys of ``comparisonValues``, in order (`tls.port` and `tls.identity` only with TLS).
    public static let comparisonKeys = [
        "host", "port", "transport", "tls", "tls.port", "tls.identity", "http3", "http2", "maxConnections",
        "drainTimeout", "timeouts", "maxBodySize", "root", "index", "mimeTypes", "defaultMimeType", "blockList",
        "blockDotfiles", "caching", "compression", "errorPages", "hosts", "auth", "proxy", "accessLog", "reload",
        "statusFile",
    ]

    /// The keys ``restartOnlyChanges(comparedTo:)`` can report, in its order.
    public static let restartOnlyKeys = ["host", "port", "transport", "tls", "tls.port", "http3", "http2",
                                         "maxConnections", "drainTimeout", "timeouts", "maxBodySize"]

    /// Key to a digest of its value (16 hex digits of SHA-256): what the status file records,
    /// so it holds no values (passwords, tokens) itself.
    public var settingDigests: [String: String] {
        var digests: [String: String] = [:]
        for (key, value) in comparisonValues {
            digests[key] = String(ServerStatus.sha256(Data("\(key)=\(value)".utf8)).prefix(16))
        }
        return digests
    }

    /// The keys whose digests differ between `old` and `new`, in canonical order, and the
    /// restart-only ones among them (`tls` alone when TLS is added or removed). The same
    /// keys as ``restartOnlyChanges(comparedTo:)`` for settings in one process.
    public static func changes(from old: [String: String], to new: [String: String])
        -> (changed: [String], restartRequired: [String]) {
        var keys = comparisonKeys.filter { old[$0] != new[$0] }
        // Anything unknown to this build (a status file from another version).
        for key in Set(old.keys).union(new.keys).sorted() where !comparisonKeys.contains(key) && old[key] != new[key] {
            keys.append(key)
        }
        var restart = keys.filter(restartOnlyKeys.contains)
        if restart.contains("tls") {
            restart.removeAll { $0 == "tls.port" }
            keys.removeAll { $0 == "tls.port" || $0 == "tls.identity" }
        }
        return (keys, restart)
    }

    /// ``statusFile`` resolved against the directory of `configPath` (not ``baseDirectory``,
    /// which `--root` moves), or `nil` when off.
    public func statusFilePath(configPath: String) -> String? {
        let directory = URL(fileURLWithPath: configPath).deletingLastPathComponent().path
        return statusFile.map { Self.resolve($0, against: directory) }
    }

    /// The status file a server running with the config file at `path` writes: its
    /// `statusFile`, or the default `run/status.json` next to it when the file does not load.
    public static func statusFilePath(forConfig path: String) -> String? {
        let settings = (try? ConfigFile.load(path: path))?.settings ?? ServerSettings()
        return settings.statusFilePath(configPath: path)
    }
}
