import Foundation
import HTTPCore
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing

/// #0144 through the shipped binary: `SwiftWebServer restart` (SIGUSR2) applies a
/// restart-only key in the same process while clients send requests in a loop over cleartext
/// and TLS, on new and keep-alive connections. Everything binds 127.0.0.1 (port 0, which a
/// restart keeps) and lives under `$TMPDIR`; the TLS identity is the gitignored test identity,
/// imported in memory only. The server is SIGKILLed on every path.
@Suite struct RestartProcessTests {
    func command(_ arguments: [String]) async throws -> ChildProcess.Output {
        try await ChildProcess.run(try ParityTests.binary(), arguments, timeout: .seconds(30))
    }

    func status(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    struct Fixture {
        let temp: URL
        let config: URL
        var statusFile: URL { temp.appending(path: "run/status.json") }

        init(bigFile: Int = 0) throws {
            temp = FileManager.default.temporaryDirectory.appending(path: "sws-restart-\(UInt64.random(in: 0...UInt64.max))")
            try FileManager.default.createDirectory(at: temp.appending(path: "Public"), withIntermediateDirectories: true)
            try Data("hi\n".utf8).write(to: temp.appending(path: "Public/a.txt"))
            if bigFile > 0 { try Data(repeating: 0x61, count: bigFile).write(to: temp.appending(path: "Public/big.bin")) }
            config = temp.appending(path: "http-config.json")
        }

        func write(_ json: String) throws {
            try Data(json.utf8).write(to: config)
        }

        func remove() { try? FileManager.default.removeItem(at: temp) }
    }

    /// Reads a response to `GET /big.bin` slowly: the first bytes, then (after `resume`)
    /// the rest. Returns the body bytes received and whether the response was whole.
    final class SlowDownload: Sendable {
        let resume = ShutdownSignal()

        func run(port: UInt16) async throws -> Int {
            let transport = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
            var out = ByteBuffer()
            out.append(contentsOf: Array("GET /big.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8))
            try await transport.send(out, endOfStream: false)
            var buffer = ByteBuffer(capacity: 65536)
            var total = 0
            var started = false
            while true {
                buffer.clear()
                let count = try await transport.receive(into: &buffer, maxLength: started ? 65536 : 4096)
                if count == 0 { break }
                total += count
                if !started {
                    started = true
                    // Stall mid-response until the restart has happened.
                    await resume.wait()
                }
            }
            await transport.close(.normal)
            return total
        }
    }

    /// The acceptance test: a restart changes `maxBodySize` (restart-only) under load. No
    /// connect is refused, every request gets a whole response, a download in flight
    /// completes, new connections see the new limit, HTTP/3 keeps its port, the pid stays.
    @Test(.timeLimit(.minutes(2)))
    func restartAppliesRestartOnlyKeysWithNoGap() async throws {
        let fixture = try Fixture(bigFile: 8 << 20)
        defer { fixture.remove() }
        let identity = try TestIdentity.load()
        @Sendable func config(maxBodySize: Int) -> String {
            #"""
            {"root": "Public", "reload": false, "drainTimeout": 5, "maxBodySize": \#(maxBodySize),
             "tls": {"identity": "\#(identity.directory)/server.p12", "password": "\#(TestIdentity.password)", "port": 0},
             "http3": true}
            """#
        }
        try fixture.write(config(maxBodySize: 100_000))
        let server = try ParityTests.launch(["--config", fixture.config.path, "--port", "0"])
        defer { server.kill() }
        let ports = try await ListenersProcessTests.ports(server, expecting: 3)
        let https = try #require(ports.https)
        let h3 = try #require(ports.h3)
        let pid = server.pid

        let big = RestartClient.post(1000)
        #expect(try await RestartClient.status(of: big, port: ports.http) != 413)
        #expect(try await RestartClient.status(of: big, port: https, tls: identity.certificateDER) != 413)
        @Sendable func quicHandshake() async throws {
            let connection = try await QUICConnection.connect(
                host: "127.0.0.1", port: h3,
                configuration: .init(peerVerification: .pinnedCertificate(identity.certificateDER), connectTimeout: .seconds(5)))
            await connection.close(applicationError: 0x100)
        }
        try await quicHandshake()

        let cleartext = RestartClient(port: ports.http, path: "/a.txt", expectedStatus: 200)
        let secure = RestartClient(port: https, tlsCertificate: identity.certificateDER, path: "/a.txt", expectedStatus: 200)
        let download = SlowDownload()
        try await withThrowingTaskGroup { group in
            group.addTask { try await download.run(port: ports.http) }
            try await secure.run {
                try await cleartext.run {
                    try await Task.sleep(for: .milliseconds(300))
                    try fixture.write(config(maxBodySize: 500))
                    let output = try await command(["restart", "--config", fixture.config.path])
                    #expect(output.status == 0, "\(output.stdout)\(output.stderr)")
                    #expect(output.stdout.contains("restarted (changed: maxBodySize)"), "\(output.stdout)")
                    // New connections run the new limit at once, on both listeners.
                    #expect(try await RestartClient.status(of: big, port: ports.http) == 413)
                    #expect(try await RestartClient.status(of: big, port: https, tls: identity.certificateDER) == 413)
                    download.resume.trigger()
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            let received = try #require(try await group.next())
            #expect(received > 8 << 20, "the download in flight completes: \(received) bytes")
        }
        cleartext.expectNoFailures()
        secure.expectNoFailures()
        try await quicHandshake()

        let recorded = try #require(status(fixture.statusFile))
        let last = try #require(recorded["lastReload"] as? [String: Any])
        #expect(last["trigger"] as? String == "restart")
        #expect(last["result"] as? String == "restarted")
        #expect(last["changed"] as? [String] == ["maxBodySize"])
        #expect(recorded["restartRequired"] as? [String] == [])
        #expect(recorded["pid"] as? Int == Int(pid))
        #expect((recorded["listening"] as? [String])?.count == 3)
        #expect(server.stderr.contains("restarted; listening 127.0.0.1:\(ports.http), 127.0.0.1:\(https) (https), 127.0.0.1:\(h3) (h3)"),
                "\(server.stderr)")

        // The running config is now the file: nothing to change, and a reload is fine.
        var output = try await command(["check", "--config", fixture.config.path])
        #expect(output.status == 0, "\(output.stdout)")
        #expect(output.stdout.contains("no setting changes"), "\(output.stdout)")
        output = try await command(["status", "--config", fixture.config.path])
        #expect(output.stdout.contains("(restart) restarted"), "\(output.stdout)")
        #expect(output.stdout.contains("last restart: "), "\(output.stdout)")

        server.signal(SIGTERM)
        #expect(try await server.waitForExit(timeout: .seconds(15)) == 0, "\(server.stderr)")
    }

    /// A restart whose new listener cannot bind (its port is taken) reports the failure,
    /// changes nothing, and the old listener keeps serving.
    @Test(.timeLimit(.minutes(1)))
    func aRestartThatCannotBindKeepsTheRunningServer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(#"{"root": "Public", "reload": false, "drainTimeout": 2, "port": 0}"#)
        let server = try ParityTests.launch(["--config", fixture.config.path])
        defer { server.kill() }
        let port = try await server.listeningPort()

        // A port held by someone else (an exclusive bind, as any other program's).
        let holder = try BSDSocketListener(configuration: .init(port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        let taken = try await holder.start()   // closed below, or by its deinit
        try fixture.write(#"{"root": "Public", "reload": false, "drainTimeout": 2, "port": \#(taken), "maxConnections": 9}"#)

        let output = try await command(["restart", "--config", fixture.config.path])
        #expect(output.status == 1, "\(output.stdout)\(output.stderr)")
        #expect(output.stdout.contains("restart failed, the running server keeps serving: listener http on 127.0.0.1:\(taken): Address already in use"),
                "\(output.stdout)")
        #expect(server.stderr.contains("restart failed, the running server keeps serving"), "\(server.stderr)")

        let recorded = try #require(status(fixture.statusFile))
        let last = try #require(recorded["lastReload"] as? [String: Any])
        #expect(last["trigger"] as? String == "restart")
        #expect(last["result"] as? String == "failed")
        #expect(recorded["listening"] as? [String] == ["127.0.0.1:\(port)"])
        #expect(try await RestartClient.status(of: "GET /a.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", port: port) == 200)
        // `check` still sees the restart-only changes as pending.
        let check = try await command(["check", "--config", fixture.config.path])
        #expect(check.status == 3, "\(check.stdout)")

        // Free the port: the same restart now succeeds and the old port closes.
        await holder.close()
        let retry = try await command(["restart", "--config", fixture.config.path])
        #expect(retry.status == 0, "\(retry.stdout)\(retry.stderr)")
        #expect(try await RestartClient.status(of: "GET /a.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", port: taken) == 200)

        server.signal(SIGTERM)
        #expect(try await server.waitForExit(timeout: .seconds(10)) == 0, "\(server.stderr)")
    }
}
