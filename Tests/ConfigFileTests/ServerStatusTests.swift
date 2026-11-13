import Foundation
import Testing
@testable import ConfigFile

/// #0143: the status file round-trips, is written atomically with mode 0600 and holds digests
/// rather than values; digest comparison finds the same restart-only keys as
/// `restartOnlyChanges(comparedTo:)`.
@Suite struct ServerStatusTests {
    @Test func writesAtomicallyAndReadsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sws-status-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "run/status.json").path
        var settings = ServerSettings()
        settings.tls = .init(identity: "id.p12", password: .literal("hunter2-secret"))
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var status = ServerStatus(pid: 42, started: started, config: "/srv/http-config.json",
                                  configSHA256: ServerStatus.sha256(Data("{}".utf8)), arguments: ["--port", "0"],
                                  listening: ["127.0.0.1:8080"], settings: settings.settingDigests)
        status.lastReload = .init(time: started, trigger: "watch", result: .rejected, message: "port changed",
                                  changed: ["port"], restartRequired: ["port"])
        status.restartRequired = ["port"]
        try status.write(to: path)
        #expect(ServerStatus.read(from: path) == status)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!text.contains("hunter2"))
        // Only the file itself is left in the directory (the temporary was renamed).
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "run").path) == ["status.json"])
        #expect(status.configSHA256 == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        #expect(ServerStatus.read(from: directory.appending(path: "missing.json").path) == nil)
    }

    @Test func digestChangesMatchRestartOnlyChanges() {
        let old = ServerSettings()
        var next = old
        next.root = "Other"
        next.mimeTypes = ["a": "x/a", "b": "x/b"]
        var changes = ServerSettings.changes(from: old.settingDigests, to: next.settingDigests)
        #expect(changes.changed == ["root", "mimeTypes"])
        #expect(changes.restartRequired.isEmpty)
        #expect(next.restartOnlyChanges(comparedTo: old).isEmpty)

        next.port = 9
        next.maxConnections = 3
        changes = ServerSettings.changes(from: old.settingDigests, to: next.settingDigests)
        #expect(changes.restartRequired == next.restartOnlyChanges(comparedTo: old))
        #expect(changes.restartRequired == ["port", "maxConnections"])

        var tls = old
        tls.tls = .init(identity: "a.p12", password: .literal("x"))
        changes = ServerSettings.changes(from: old.settingDigests, to: tls.settingDigests)
        #expect(changes.changed == ["tls"])
        #expect(changes.restartRequired == ["tls"])
        var renewed = tls
        renewed.tls?.identity = "b.p12"
        changes = ServerSettings.changes(from: tls.settingDigests, to: renewed.settingDigests)
        #expect(changes.changed == ["tls.identity"])
        #expect(changes.restartRequired.isEmpty)
        renewed.tls?.port = 9443
        #expect(ServerSettings.changes(from: tls.settingDigests, to: renewed.settingDigests).restartRequired == ["tls.port"])
    }

    @Test func statusFileKeyParses() throws {
        #expect(try ConfigFile.parse(Data("{}".utf8)).settings.statusFile == "run/status.json")
        #expect(try ConfigFile.parse(Data(#"{"statusFile": "state/s.json"}"#.utf8)).settings.statusFile == "state/s.json")
        #expect(try ConfigFile.parse(Data(#"{"statusFile": false}"#.utf8)).settings.statusFile == nil)
        #expect(try ConfigFile.parse(Data(#"{"statusFile": null}"#.utf8)).settings.statusFile == nil)
        #expect(throws: ConfigFileError.self) { try ConfigFile.parse(Data(#"{"statusFile": true}"#.utf8)) }
        var settings = ServerSettings()
        settings.baseDirectory = "/elsewhere"   // `--root` moves it; the status file stays by the config
        #expect(settings.statusFilePath(configPath: "/srv/http-config.json") == "/srv/run/status.json")
        settings.statusFile = nil
        #expect(settings.statusFilePath(configPath: "/srv/http-config.json") == nil)
    }
}
