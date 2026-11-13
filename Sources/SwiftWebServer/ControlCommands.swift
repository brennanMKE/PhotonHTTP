import ConfigFile
import Foundation
import HTTPCore
import NetworkTransport
import Synchronization

/// The status file of this server process (#0143): written once the listeners are bound,
/// after every reload and restart (#0144) and at a clean exit. Only when the settings came from a config file and
/// `statusFile` is not off. A write that fails prints one warning and the server carries on.
final class StatusRecorder: Sendable {
    struct State {
        var status: ServerStatus
        var path: String?
        /// The running settings, for the keys a reload changed.
        var running: ServerSettings
        var warned = false
    }

    let state: Mutex<State>

    init(config: String?, sha256: String?, arguments: [String], settings: ServerSettings) {
        let absolute = config.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let status = ServerStatus(pid: getpid(), started: Date(), config: absolute, configSHA256: sha256,
                                  arguments: arguments, settings: settings.settingDigests)
        state = Mutex(State(status: status, path: absolute.flatMap { settings.statusFilePath(configPath: $0) },
                            running: settings))
    }

    func running(listening: [String]) {
        update { $0.status.listening = listening }
    }

    func reloaded(trigger: ConfigReloader.Trigger, next: ServerSettings, sha256: String?) {
        update { state in
            let changed = ServerSettings.changes(from: state.running.settingDigests, to: next.settingDigests).changed
            state.running = next
            state.status.settings = next.settingDigests
            state.status.configSHA256 = sha256
            state.status.restartRequired = []
            let summary = changed.isEmpty ? "no key changed" : "changed: \(changed.joined(separator: ", "))"
            state.status.lastReload = .init(time: Date(), trigger: trigger.name, result: .reloaded,
                                            message: "reloaded the configuration (\(summary))", changed: changed)
            // `statusFile` itself reloads: the old file goes, the new one is written.
            let path = state.status.config.flatMap { next.statusFilePath(configPath: $0) }
            if path != state.path, let old = state.path { try? FileManager.default.removeItem(atPath: old) }
            if state.path != nil { state.path = path }
        }
    }

    func rejected(trigger: ConfigReloader.Trigger, next: ServerSettings, restartRequired: [String], message: String) {
        update { state in
            let changed = ServerSettings.changes(from: state.running.settingDigests, to: next.settingDigests).changed
            state.status.restartRequired = restartRequired
            state.status.lastReload = .init(time: Date(), trigger: trigger.name, result: .rejected, message: message,
                                            changed: changed, restartRequired: restartRequired)
        }
    }

    func failed(trigger: ConfigReloader.Trigger, message: String) {
        update { state in
            state.status.lastReload = .init(time: Date(), trigger: trigger.name, result: .failed, message: message,
                                            restartRequired: state.status.restartRequired)
        }
    }

    /// A graceful restart applied `next` (#0144): the listeners, settings and digests are
    /// the new ones and nothing waits for a restart.
    func restarted(next: ServerSettings, sha256: String?, listening: [String]) {
        update { state in
            let changed = ServerSettings.changes(from: state.running.settingDigests, to: next.settingDigests).changed
            state.running = next
            state.status.settings = next.settingDigests
            state.status.configSHA256 = sha256
            state.status.listening = listening
            state.status.restartRequired = []
            let now = Date()
            state.status.restarted = now
            let summary = changed.isEmpty ? "no key changed" : "changed: \(changed.joined(separator: ", "))"
            state.status.lastReload = .init(time: now, trigger: "restart", result: .restarted,
                                            message: "restarted (\(summary)); listening \(listening.joined(separator: ", "))",
                                            changed: changed)
            let path = state.status.config.flatMap { next.statusFilePath(configPath: $0) }
            if path != state.path, let old = state.path { try? FileManager.default.removeItem(atPath: old) }
            if state.path != nil { state.path = path }
        }
    }

    /// A graceful restart failed (#0144); the running configuration stays.
    func restartFailed(message: String) {
        update { state in
            state.status.lastReload = .init(time: Date(), trigger: "restart", result: .failed, message: message,
                                            restartRequired: state.status.restartRequired)
        }
    }

    func stopped() {
        update { $0.status.state = .stopped }
    }

    /// Applies `change` and writes the file, under the lock so writes keep their order. Low
    /// rate (startup, reloads, exit) and off the request path.
    private func update(_ change: (inout State) -> Void) {
        state.withLock { state in
            let reload = state.status.lastReload
            change(&state)
            if state.status.lastReload != reload { state.status.reloads += 1 }
            state.status.updated = Date()
            guard let path = state.path else { return }
            do {
                try state.status.write(to: path)
            } catch {
                if !state.warned {
                    printError("\(ServerMain.name): warning: cannot write the status file \(path): \(error)")
                    state.warned = true
                }
            }
        }
    }
}

/// `SwiftWebServer check | reload | status | restart` (#0143). They talk to a running server
/// through signals and its status file only: there is no control socket, so nothing new is
/// reachable over the network.
enum ControlCommand: String {
    case check
    case reload
    case status
    /// Graceful restart in process (#0144). Named by `check` and `reload` when a restart is
    /// needed.
    case restart

    static let usage = """
        usage: SwiftWebServer check   [--config FILE] [--root DIR] [--host HOST] [--port PORT]
               SwiftWebServer reload  [--config FILE] [--root DIR] [--host HOST] [--port PORT] [--timeout SECONDS]
               SwiftWebServer status  [--config FILE] [--json]
               SwiftWebServer restart [--config FILE] [--root DIR] [--host HOST] [--port PORT] [--timeout SECONDS]

          check    validate the config (it is loaded and built as a reload would, the TLS identity
                   in memory only) and, when a server runs with it, say which keys would change
                   and whether a reload applies them or a restart is needed
          reload   check, then send SIGHUP to the running server and print the outcome it
                   records in its status file
          status   print the running server's status file
          restart  check, then send SIGUSR2: the running server reads the whole config, binds
                   new listeners beside the old ones (same ports, no gap), starts accepting on
                   them, then drains the old ones for up to drainTimeout. Applies the keys a
                   reload rejects. Prints the outcome; on failure the old listeners keep serving

        The running server is found through its status file: "statusFile" in the config
        (default run/status.json next to it). Without --root/--host/--port, check and reload use
        the overrides the running server was started with.

        Exit status: 0 success; 1 invalid config, no running server, reload or restart failed or
        timed out; 2 usage error; 3 a restart is required (the reload was or would be rejected).
        A new binary needs a new process: `launchctl kickstart -k gui/<uid>/LABEL`.
        """

    /// Exit status when a restart is required.
    static let restartRequiredStatus: Int32 = 3

    /// The command that applies restart-only keys (#0144).
    static let restartCommand = "SwiftWebServer restart"

    /// `port, tls.port changed and need a restart: run `SwiftWebServer restart``
    static func restartMessage(_ keys: [String]) -> String {
        let verb = keys.count == 1 ? "needs" : "need"
        return "\(keys.joined(separator: ", ")) changed and \(verb) a restart; run `\(restartCommand)` to apply them"
    }

    func run(_ arguments: [String], environment: [String: String]) async -> Int32 {
        var arguments = arguments
        var json = false
        var timeout = 10.0
        do {
            if self == .status, let index = arguments.firstIndex(of: "--json") {
                json = true
                arguments.remove(at: index)
            }
            if self == .reload || self == .restart, let index = arguments.firstIndex(where: { $0 == "--timeout" || $0.hasPrefix("--timeout=") }) {
                let argument = arguments.remove(at: index)
                let text: String
                if let equals = argument.firstIndex(of: "=") {
                    text = String(argument[argument.index(after: equals)...])
                } else {
                    guard index < arguments.count else { throw ServerMain.UsageError(description: "missing value for --timeout") }
                    text = arguments.remove(at: index)
                }
                guard let seconds = Double(text), seconds > 0, seconds <= 3600 else {
                    throw ServerMain.UsageError(description: "invalid timeout '\(text)'")
                }
                timeout = seconds
            }
            let options = try ServerMain.parse(arguments)
            if options.help {
                print(Self.usage)
                return 0
            }
            switch self {
            case .check: return check(options, environment: environment).exitStatus
            case .reload: return await reload(options, environment: environment, timeout: .milliseconds(Int64(timeout * 1000)))
            case .status: return status(options, environment: environment, json: json)
            case .restart: return await restart(options, environment: environment, timeout: .milliseconds(Int64(timeout * 1000)))
            }
        } catch {
            printError("\(ServerMain.name) \(rawValue): \(error)\n\n\(Self.usage)")
            return 2
        }
    }

    // MARK: check

    /// What `check` found.
    struct CheckResult {
        var exitStatus: Int32
        /// The running server's status, when one runs with this config.
        var running: ServerStatus?
        var statusPath: String?
    }

    func check(_ options: ServerMain.Options, environment: [String: String]) -> CheckResult {
        let name = "\(ServerMain.name) \(rawValue)"
        guard let path = ServerMain.configPath(options, environment: environment) else {
            printError("\(name): no config file (use --config FILE, or run where http-config.json is)")
            return CheckResult(exitStatus: 1)
        }
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        // The running server, through the status file the file names (or the default place
        // when the file does not even parse).
        let statusPath = ServerSettings.statusFilePath(forConfig: path)
        let status = statusPath.flatMap(ServerStatus.read(from:))
        let running = status.flatMap { $0.isRunning && $0.config == absolute ? $0 : nil }
        // Without overrides on this command line, use the running server's.
        var effective = options
        if let running, options.root == nil, options.host == nil, options.port == nil,
           let started = try? ServerMain.parse(running.arguments) {
            effective.root = started.root
            effective.host = started.host
            effective.port = started.port
        }

        let settings: ServerSettings
        let sha256: String?
        do {
            (settings, sha256) = try ServerMain.loadSettings(effective, environment: environment)
            try settings.validate()
            _ = try settings.makeHandler(environment: environment)
            _ = try ServerMain.loadIdentity(settings, environment: environment)
            do {
                try settings.serverConfiguration.validate()
            } catch {
                throw ConfigFileError("\(error)")
            }
            _ = try ServerProtocols.make(settings)
        } catch {
            print("\(absolute): invalid: \(error)")
            return CheckResult(exitStatus: 1, running: running, statusPath: statusPath)
        }
        print("\(absolute): valid")
        guard let running else {
            print("no running server for this config (status file \(statusPath ?? "off"))")
            return CheckResult(exitStatus: 0, statusPath: statusPath)
        }
        print("running: pid \(running.pid), listening \(running.listening.joined(separator: ", "))")
        let (changed, restart) = ServerSettings.changes(from: running.settings, to: settings.settingDigests)
        if sha256 == running.configSHA256 {
            print("the file is the one the server loaded (sha256 \(sha256?.prefix(12) ?? "?"))")
        }
        if !restart.isEmpty {
            print("needs a restart: \(Self.restartMessage(restart))")
            let hot = changed.filter { !restart.contains($0) }
            if !hot.isEmpty { print("also changed (would reload): \(hot.joined(separator: ", "))") }
            return CheckResult(exitStatus: Self.restartRequiredStatus, running: running, statusPath: statusPath)
        }
        if changed.isEmpty {
            print("no setting changes; a reload rereads the files the config names (TLS identity, credential files, error pages)")
        } else {
            print("can hot-reload: \(changed.joined(separator: ", ")) changed")
        }
        return CheckResult(exitStatus: 0, running: running, statusPath: statusPath)
    }

    // MARK: reload

    func reload(_ options: ServerMain.Options, environment: [String: String], timeout: Duration) async -> Int32 {
        let name = "\(ServerMain.name) reload"
        let result = check(options, environment: environment)
        guard result.exitStatus == 0 else {
            if result.exitStatus == Self.restartRequiredStatus {
                printError("\(name): not reloading: the server would reject this config; run `\(Self.restartCommand)`")
            }
            return result.exitStatus
        }
        guard let running = result.running, let statusPath = result.statusPath else {
            printError("\(name): no running server to reload")
            return 1
        }
        guard kill(running.pid, SIGHUP) == 0 else {
            printError("\(name): cannot signal pid \(running.pid): \(String(cString: strerror(errno)))")
            return 1
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let status = ServerStatus.read(from: statusPath), status.reloads > running.reloads,
               let last = status.lastReload {
                switch last.result {
                case .reloaded:
                    print("reloaded: \(last.message)")
                    return 0
                case .failed:
                    print("reload failed, the running configuration stays: \(last.message)")
                    return 1
                case .rejected:
                    print("reload rejected, the running configuration stays: \(last.message)")
                    return Self.restartRequiredStatus
                case .restarted:
                    // A restart landed first (#0144): it applied the whole file.
                    print("restarted meanwhile: \(last.message)")
                    return 0
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        printError("\(name): no result in the status file \(statusPath) after \(timeout)")
        return 1
    }

    // MARK: status

    func status(_ options: ServerMain.Options, environment: [String: String], json: Bool) -> Int32 {
        let name = "\(ServerMain.name) status"
        guard let path = ServerMain.configPath(options, environment: environment) else {
            printError("\(name): no config file (use --config FILE, or run where http-config.json is)")
            return 1
        }
        guard let statusPath = ServerSettings.statusFilePath(forConfig: path) else {
            printError("\(name): \"statusFile\" is off in \(path)")
            return 1
        }
        guard let data = FileManager.default.contents(atPath: statusPath), let status = ServerStatus.read(from: statusPath) else {
            printError("\(name): no status file at \(statusPath)")
            return 1
        }
        if json {
            FileHandle.standardOutput.write(data)
            return status.isRunning ? 0 : 1
        }
        let time = Date.ISO8601FormatStyle()
        let state = status.isRunning ? "running" : (status.state == .running ? "not running (stale status file)" : "stopped")
        print("state: \(state), pid \(status.pid), started \(status.started.formatted(time))")
        if !status.listening.isEmpty { print("listening: \(status.listening.joined(separator: ", "))") }
        print("config: \(status.config ?? "(none)") sha256 \(status.configSHA256 ?? "?")")
        if let last = status.lastReload {
            print("last reload: \(last.time.formatted(time)) (\(last.trigger)) \(last.result.rawValue): \(last.message)")
        } else {
            print("last reload: none")
        }
        print("reloads: \(status.reloads)")
        if let restarted = status.restarted { print("last restart: \(restarted.formatted(time))") }
        if !status.restartRequired.isEmpty {
            print("restart required: \(Self.restartMessage(status.restartRequired))")
        }
        return status.isRunning ? 0 : 1
    }

    // MARK: restart

    /// `check`, then SIGUSR2 to the running server, then wait for the restart's outcome in the
    /// status file (#0144). A config that needs a restart is what this is for, so `check`'s
    /// exit 3 is no reason to stop; an invalid one is, and nothing is signalled.
    func restart(_ options: ServerMain.Options, environment: [String: String], timeout: Duration) async -> Int32 {
        let name = "\(ServerMain.name) restart"
        let result = check(options, environment: environment)
        guard result.exitStatus == 0 || result.exitStatus == Self.restartRequiredStatus else {
            printError("\(name): not restarting: the config is not valid; the running server is unchanged")
            return result.exitStatus
        }
        guard let running = result.running, let statusPath = result.statusPath else {
            printError("\(name): no running server to restart")
            return 1
        }
        guard kill(running.pid, SIGUSR2) == 0 else {
            printError("\(name): cannot signal pid \(running.pid): \(String(cString: strerror(errno)))")
            return 1
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var seen = running.reloads
        while clock.now < deadline {
            if let status = ServerStatus.read(from: statusPath), status.reloads > seen {
                seen = status.reloads
                if let last = status.lastReload, last.trigger == "restart" {
                    if last.result == .restarted {
                        print("restarted: \(last.message)")
                        return 0
                    }
                    print("restart failed, the running server keeps serving: \(last.message)")
                    return 1
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        printError("\(name): no result in the status file \(statusPath) after \(timeout)")
        return 1
    }
}
