import Foundation
import HTTPTestSupport
import Testing

/// `photon serve [DIR]`: a directory served as a static site, `index.html` for `/` and every
/// subdirectory, with any `http-config.json` ignored. Binds 127.0.0.1 port 0; every child is
/// killed on every path.
@Suite struct PhotonServeCommandTests {
    func curl(_ arguments: [String]) async throws -> String {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                                ["-sS", "--max-time", "10"] + arguments,
                                                timeout: .seconds(30), mergeStandardError: true)
        return output.stdout
    }

    func makeSite() throws -> URL {
        let site = FileManager.default.temporaryDirectory
            .appending(path: "photon-serve-\(UInt64.random(in: 0...UInt64.max))")
        try FileManager.default.createDirectory(at: site.appending(path: "docs"), withIntermediateDirectories: true)
        try Data("home\n".utf8).write(to: site.appending(path: "index.html"))
        try Data("docs\n".utf8).write(to: site.appending(path: "docs/index.html"))
        try Data("body{}\n".utf8).write(to: site.appending(path: "site.css"))
        return site
    }

    @Test(.timeLimit(.minutes(1)))
    func servesADirectoryWithIndexFilesAndIgnoresConfig() async throws {
        let site = try makeSite()
        defer { try? FileManager.default.removeItem(at: site) }
        // A broken config where the server would look for one: `serve` must not read it.
        try Data("{ not json".utf8).write(to: site.appending(path: "http-config.json"))

        let server = try ParityTests.launch(["serve", site.path, "--port", "0"], environment: ["ROOT_PATH": site.path])
        defer { server.kill() }
        let base = "http://127.0.0.1:\(try await server.listeningPort())"

        #expect(try await curl(["\(base)/"]) == "home\n")
        #expect(try await curl(["\(base)/docs/"]) == "docs\n")
        #expect(try await curl(["-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", "\(base)/docs"])
                    .hasPrefix("301"))
        #expect(try await curl(["-o", "/dev/null", "-w", "%{content_type}", "\(base)/site.css"]).hasPrefix("text/css"))
        #expect(try await curl(["-o", "/dev/null", "-w", "%{http_code}", "\(base)/missing"]) == "404")

        server.signal(SIGTERM)
        #expect(try await server.waitForExit(timeout: .seconds(10)) == 0, "\(server.stderr)")
        #expect(server.stderr.contains("serving \(site.path)"), "\(server.stderr)")
    }

    @Test(.timeLimit(.minutes(1)))
    func usageErrors() async throws {
        for arguments in [["serve", "a", "b"], ["serve", "--config", "x.json"], ["serve", "--bogus"], ["serve", "-x"]] {
            let child = try ParityTests.launch(arguments)
            defer { child.kill() }
            #expect(try await child.waitForExit(timeout: .seconds(5)) == 2, "\(arguments)")
            #expect(child.stderr.contains("usage: photon serve"), "\(arguments): \(child.stderr)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func missingDirectoryExitsOne() async throws {
        let child = try ParityTests.launch(["serve", "/nonexistent-photon-dir", "--port", "0"])
        defer { child.kill() }
        #expect(try await child.waitForExit(timeout: .seconds(5)) == 1, "\(child.stderr)")
    }

    @Test(.timeLimit(.minutes(1)))
    func helpPrintsServeUsage() async throws {
        let child = try ParityTests.launch(["serve", "--help"])
        defer { child.kill() }
        #expect(try await child.waitForExit(timeout: .seconds(5)) == 0)
        #expect(child.stdout.contains("usage: photon serve"), "\(child.stdout)")
    }
}
