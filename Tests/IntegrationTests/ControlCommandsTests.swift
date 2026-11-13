import Foundation
import HTTPTestSupport
import Testing

/// #0143 through the shipped binary: a reload with restart-only changes is rejected whole, the
/// status file records it, and `check`, `reload` and `status` report it (exit 3 and
/// `SwiftWebServer restart` when a restart is needed). The server binds 127.0.0.1 port 0 and
/// everything lives under `$TMPDIR`; the server is SIGKILLed on every path.
@Suite struct ControlCommandsTests {
    func command(_ arguments: [String]) async throws -> ChildProcess.Output {
        try await ChildProcess.run(try ParityTests.binary(), arguments, timeout: .seconds(30))
    }

    func curl(_ url: String) async throws -> String {
        try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"), ["-sS", "--max-time", "10", url],
                                   timeout: .seconds(20), mergeStandardError: true).stdout
    }

    /// The status file as JSON.
    func status(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met in 10 s")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func restartOnlyChangesAreRejectedAndTheCommandsSaySo() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "sws-control-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: temp) }
        for (folder, text) in [("Public", "public\n"), ("Other", "other\n")] {
            try FileManager.default.createDirectory(at: temp.appending(path: folder), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: temp.appending(path: "\(folder)/a.txt"))
        }
        let config = temp.appending(path: "http-config.json")
        // The watcher is off, so only the signal (and `reload`) reloads.
        func write(_ extra: String) throws {
            try Data(#"{"port": 0, "reload": false, \#(extra)}"#.utf8).write(to: config)
        }
        try write(#""root": "Public""#)
        let statusFile = temp.appending(path: "run/status.json")
        let server = try ParityTests.launch(["--config", config.path, "--port", "0"])
        defer { server.kill() }
        let base = "http://127.0.0.1:\(try await server.listeningPort())"
        try await waitFor { (status(statusFile)?["listening"] as? [String])?.isEmpty == false }

        let initial = try #require(status(statusFile))
        #expect(initial["state"] as? String == "running")
        #expect(initial["pid"] as? Int == Int(server.pid))
        #expect(initial["config"] as? String == config.standardizedFileURL.path)
        #expect((initial["configSHA256"] as? String)?.count == 64)
        let attributes = try FileManager.default.attributesOfItem(atPath: statusFile.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        var output = try await command(["status", "--config", config.path])
        #expect(output.status == 0, "\(output.stderr)")
        #expect(output.stdout.contains("state: running, pid \(server.pid)"), "\(output.stdout)")

        output = try await command(["check", "--config", config.path])
        #expect(output.status == 0, "\(output.stdout)\(output.stderr)")
        #expect(output.stdout.contains("valid") && output.stdout.contains("no setting changes"), "\(output.stdout)")

        // A hot-reloadable change: `reload` signals and reports what the server recorded.
        try write(#""root": "Other""#)
        output = try await command(["check", "--config", config.path])
        #expect(output.status == 0)
        #expect(output.stdout.contains("can hot-reload: root changed"), "\(output.stdout)")
        output = try await command(["reload", "--config", config.path])
        #expect(output.status == 0, "\(output.stdout)\(output.stderr)")
        #expect(output.stdout.contains("reloaded: reloaded the configuration (changed: root)"), "\(output.stdout)")
        #expect(try await curl("\(base)/a.txt") == "other\n")

        // A restart-only change with a hot one: `check` and `reload` refuse with exit 3.
        try write(#""root": "Public", "maxConnections": 7"#)
        output = try await command(["check", "--config", config.path])
        #expect(output.status == 3)
        #expect(output.stdout.contains("needs a restart: maxConnections changed and needs a restart; run `SwiftWebServer restart`"),
                "\(output.stdout)")
        #expect(output.stdout.contains("also changed (would reload): root"), "\(output.stdout)")
        let reloadsBefore = status(statusFile)?["reloads"] as? Int
        output = try await command(["reload", "--config", config.path])
        #expect(output.status == 3)
        #expect(output.stderr.contains("run `SwiftWebServer restart`"), "\(output.stderr)")
        #expect(status(statusFile)?["reloads"] as? Int == reloadsBefore, "reload must not signal")

        // SIGHUP anyway: the server rejects the whole file, root included.
        server.signal(SIGHUP)
        try await waitFor { (status(statusFile)?["restartRequired"] as? [String]) == ["maxConnections"] }
        let rejected = try #require(status(statusFile)?["lastReload"] as? [String: Any])
        #expect(rejected["result"] as? String == "rejected")
        #expect(rejected["trigger"] as? String == "signal")
        #expect(rejected["changed"] as? [String] == ["maxConnections", "root"])
        #expect(server.stderr.contains("reload rejected, keeping the running configuration: maxConnections changed"),
                "\(server.stderr)")
        #expect(try await curl("\(base)/a.txt") == "other\n")
        output = try await command(["status", "--config", config.path])
        #expect(output.stdout.contains("restart required: maxConnections changed"), "\(output.stdout)")

        // An invalid file: `check` says so and exits 1; `reload` does not signal.
        try Data(#"{"port": 0, "reload": false, "root": "Missing"}"#.utf8).write(to: config)
        output = try await command(["check", "--config", config.path])
        #expect(output.status == 1)
        #expect(output.stdout.contains("invalid") && output.stdout.contains("Missing"), "\(output.stdout)")

        // `restart` (#0144) checks first: an invalid file is not signalled.
        output = try await command(["restart", "--config", config.path])
        #expect(output.status == 1)
        #expect(output.stderr.contains("not restarting: the config is not valid"), "\(output.stderr)")

        server.signal(SIGTERM)
        #expect(try await server.waitForExit(timeout: .seconds(10)) == 0, "\(server.stderr)")
        #expect(status(statusFile)?["state"] as? String == "stopped")
        output = try await command(["status", "--config", config.path])
        #expect(output.status == 1)
        #expect(output.stdout.contains("state: stopped"), "\(output.stdout)")
        output = try await command(["reload", "--config", config.path])
        #expect(output.status == 1)
    }
}
