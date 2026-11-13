import Foundation
import HTTPCore
import Synchronization
import Testing
@testable import ConfigFile

/// `ConfigReloader` (#0142): the watcher reloads on an edit or a rename within its interval,
/// waits for a file being written to settle, follows the files the new plan names, and runs
/// signal-requested reloads one at a time with its own. Files live in a temporary directory;
/// intervals are tens of milliseconds.
@Suite struct ConfigReloaderTests {
    /// What each reload saw: its trigger and the config file's text at the time.
    final class Log: Sendable {
        let entries = Mutex<[(trigger: ConfigReloader.Trigger, text: String)]>([])
        func append(_ trigger: ConfigReloader.Trigger, _ text: String) { entries.withLock { $0.append((trigger, text)) } }
        var all: [(trigger: ConfigReloader.Trigger, text: String)] { entries.withLock { $0 } }
        var count: Int { entries.withLock { $0.count } }
    }

    final class Directory: Sendable {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "sws-watch-\(UInt64.random(in: 0...UInt64.max))")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func path(_ name: String) -> String { url.appending(path: name).path }
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: url.appending(path: name))
        }
        func read(_ name: String) -> String {
            (try? String(contentsOfFile: path(name), encoding: .utf8)) ?? ""
        }
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// Runs `reloader` as the server would while `body` runs, then cancels it.
    func running(_ reloader: ConfigReloader, draining: ShutdownSignal = ShutdownSignal(),
                 _ body: () async throws -> Void) async throws {
        let handle = ServerHandle(localAddresses: [], draining: draining, requestShutdown: {})
        try await withThrowingTaskGroup { group in
            group.addTask { try await reloader.run(server: handle) }
            try await body()
            group.cancelAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anEditReloadsWithinTheInterval() async throws {
        let directory = try Directory()
        try directory.write("http-config.json", "{}")
        let config = directory.path("http-config.json")
        let log = Log()
        let reloader = ConfigReloader(plan: .init(paths: [config], interval: .milliseconds(20))) { trigger in
            log.append(trigger, directory.read("http-config.json"))
            return nil
        }
        try await running(reloader) {
            try await Task.sleep(for: .milliseconds(100))
            #expect(log.count == 0, "nothing changed yet")
            try directory.write("http-config.json", #"{"port": 1}"#)
            try await eventually { log.count == 1 }
            #expect(log.all.first?.trigger == .watch(changed: [config]))
            #expect(log.all.first?.text == #"{"port": 1}"#)
            // No second reload for the same change.
            try await Task.sleep(for: .milliseconds(150))
            #expect(log.count == 1)
        }
    }

    /// Editors and certificate tools write a new file and rename it over the old one.
    @Test(.timeLimit(.minutes(1)))
    func aReplacementByRenameIsSeenThroughTheInode() async throws {
        let directory = try Directory()
        try directory.write("id.p12", "first")
        let identity = directory.path("id.p12")
        let log = Log()
        let reloader = ConfigReloader(plan: .init(paths: [identity], interval: .milliseconds(20))) { trigger in
            log.append(trigger, directory.read("id.p12"))
            return nil
        }
        let before = try #require(FileFingerprint.of(identity))
        try await running(reloader) {
            // Same size; the rename is what changes.
            try directory.write("id.p12.new", "secon")
            #expect(rename(directory.path("id.p12.new"), identity) == 0)
            try await eventually { log.count == 1 }
            #expect(log.all.first?.text == "secon")
        }
        #expect(FileFingerprint.of(identity)?.inode != before.inode)
    }

    /// A file still being written is not read: the reload waits until it stops changing.
    @Test(.timeLimit(.minutes(1)))
    func aFileBeingWrittenIsReadOnceItSettles() async throws {
        let directory = try Directory()
        try directory.write("http-config.json", "{}")
        let log = Log()
        let reloader = ConfigReloader(plan: .init(paths: [directory.path("http-config.json")], interval: .milliseconds(20)),
                                      settle: .milliseconds(400)) { trigger in
            log.append(trigger, directory.read("http-config.json"))
            return nil
        }
        try await running(reloader) {
            try directory.write("http-config.json", #"{"port":"#)
            try await Task.sleep(for: .milliseconds(60))
            try directory.write("http-config.json", #"{"port": 2}"#)
            try await eventually { log.count == 1 }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(log.all.map(\.text) == [#"{"port": 2}"#])
    }

    /// A signal reloads at once; the files the returned plan adds are watched from then on,
    /// and a missing file appearing counts as a change.
    @Test(.timeLimit(.minutes(1)))
    func aSignalReloadsAndTheNewPlanIsWatched() async throws {
        let directory = try Directory()
        try directory.write("http-config.json", "{}")
        let config = directory.path("http-config.json")
        let users = directory.path("users.htpasswd")
        let log = Log()
        let reloader = ConfigReloader(plan: .init(paths: [config], interval: .milliseconds(20))) { trigger in
            log.append(trigger, directory.read("http-config.json"))
            return .init(paths: [config, users], interval: .milliseconds(20))
        }
        try await running(reloader) {
            reloader.requestReload()
            try await eventually { log.count == 1 }
            #expect(log.all.first?.trigger == .signal)
            #expect(reloader.currentPlan.paths == [config, users])
            try directory.write("users.htpasswd", "alice:x\n")
            try await eventually { log.count == 2 }
            #expect(log.all.last?.trigger == .watch(changed: [users]))
        }
    }

    /// #0144: a restart runs on the reloader's task, after the reload asked for before it and
    /// never beside one; its plan is watched from then on.
    @Test(.timeLimit(.minutes(1)))
    func aRestartRunsInTurnWithReloads() async throws {
        let directory = try Directory()
        try directory.write("http-config.json", "{}")
        let config = directory.path("http-config.json")
        let other = directory.path("other.txt")
        let order = Mutex<[String]>([])
        let busy = Mutex(false)
        let reloader = ConfigReloader(plan: .init(paths: [config], watch: false, interval: .milliseconds(20))) { _ in
            let overlapping = busy.withLock { $0 }
            order.withLock { $0.append(overlapping ? "overlap" : "reload") }
            return nil
        } restart: {
            busy.withLock { $0 = true }
            try? await Task.sleep(for: .milliseconds(50))
            busy.withLock { $0 = false }
            order.withLock { $0.append("restart") }
            return .init(paths: [config, other], watch: false, interval: .milliseconds(20))
        }
        try await running(reloader) {
            reloader.requestReload()
            reloader.requestRestart()
            reloader.requestReload()
            try await eventually { order.withLock { $0.count } == 3 }
            #expect(order.withLock { $0 } == ["reload", "restart", "reload"])
            #expect(reloader.currentPlan.paths == [config, other])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func withWatchOffOnlyASignalReloads() async throws {
        let directory = try Directory()
        try directory.write("http-config.json", "{}")
        let log = Log()
        let reloader = ConfigReloader(plan: .init(paths: [directory.path("http-config.json")], watch: false,
                                                  interval: .milliseconds(20))) { trigger in
            log.append(trigger, "")
            return nil
        }
        try await running(reloader) {
            try directory.write("http-config.json", #"{"port": 3}"#)
            try await Task.sleep(for: .milliseconds(200))
            #expect(log.count == 0)
            reloader.requestReload()
            try await eventually { log.count == 1 }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func nothingReloadsOnceTheServerDrains() async throws {
        let directory = try Directory()
        try directory.write("http-config.json", "{}")
        let log = Log()
        let draining = ShutdownSignal()
        let reloader = ConfigReloader(plan: .init(paths: [directory.path("http-config.json")], interval: .milliseconds(20))) { trigger in
            log.append(trigger, "")
            return nil
        }
        try await running(reloader, draining: draining) {
            draining.trigger()
            reloader.requestReload()
            try directory.write("http-config.json", #"{"port": 4}"#)
            try await Task.sleep(for: .milliseconds(200))
            #expect(log.count == 0)
        }
    }

    @Test func reloadKeyParses() throws {
        #expect(try ConfigFile.parse(Data("{}".utf8)).settings.reload == .init(watch: true, interval: .seconds(2)))
        #expect(try ConfigFile.parse(Data(#"{"reload": false}"#.utf8)).settings.reload.watch == false)
        let file = try ConfigFile.parse(Data(#"{"reload": {"watch": true, "interval": 0.25, "x": 1}}"#.utf8))
        #expect(file.settings.reload == .init(watch: true, interval: .milliseconds(250)))
        #expect(file.warnings.count == 1)
        #expect(throws: ConfigFileError.self) { try ConfigFile.parse(Data(#"{"reload": {"interval": 0}}"#.utf8)) }
        #expect(throws: ConfigFileError.self) { try ConfigFile.parse(Data(#"{"reload": "yes"}"#.utf8)) }
    }

    /// The files a reload reads: identity, Basic credential files, error pages per root.
    @Test func reloadInputsNameTheFilesAReloadReads() throws {
        var settings = ServerSettings()
        settings.baseDirectory = "/srv"
        #expect(settings.reloadInputs.isEmpty)
        settings.tls = .init(identity: "id.p12", password: .literal("x"))
        var area = ServerSettings.AuthSettings()
        area.basicFile = "users.htpasswd"
        settings.auth = [area]
        settings.errorPages = .files([404: "errors/404.html"])
        settings.hosts = [.init(names: ["a.test"], root: "sites/a")]
        #expect(settings.reloadInputs == ["/srv/id.p12", "/srv/users.htpasswd", "/srv/Public/errors/404.html",
                                          "/srv/sites/a/errors/404.html"])
        let plan = settings.watchPlan(configPath: "/srv/http-config.json")
        #expect(plan.paths.first == "/srv/http-config.json")
        #expect(plan.paths.count == 5)
    }
}
