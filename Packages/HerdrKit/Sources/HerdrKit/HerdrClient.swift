import Foundation

/// The oldest herdr release this kit works with.
public let herdrVersion = "0.9.3"

public enum HerdrError: Error, Equatable, Sendable {
    /// No herdr binary on the machine.
    case notFound
    /// herdr is there but too old or lacks the API bridge.
    case unsupported(String)
    /// herdr did not answer within 10 s.
    case timeout
    /// herdr answered with an error.
    case herdr(code: String, message: String)
    /// The command failed or printed something we cannot read.
    case failed(String)
}

/// Talks to one herdr session through `remote-api-bridge`.
public struct HerdrClient: Sendable {
    public let session: String
    let herdr: String
    let exec: any Exec
    let timeout: Duration

    /// `herdr` is the path from `locate(exec:)`.
    public init(herdr: String, session: String, exec: any Exec) {
        self.init(herdr: herdr, session: session, exec: exec, timeout: .seconds(10))
    }

    init(
        herdr: String,
        session: String,
        exec: any Exec,
        timeout: Duration,
    ) {
        self.herdr = herdr
        self.session = session
        self.exec = exec
        self.timeout = timeout
    }

    /// Finds the herdr binary and checks that it has the API bridge.
    public static func locate(exec: any Exec) async throws -> String {
        let find = #"command -v herdr || for p in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr "#
            + #"/usr/local/bin/herdr; do [ -x "$p" ] && echo "$p" && break; done"#
        guard let path = try await firstLine(exec, ["sh", "-c", find]), !path.isEmpty else {
            throw HerdrError.notFound
        }
        guard try await firstLine(exec, [path, "--session", "default", "remote-api-bridge", "--check"])
            == "herdr-api-bridge-v1"
        else {
            throw HerdrError.unsupported("\(path) has no remote-api-bridge; herdr \(herdrVersion) or newer needed")
        }
        return path
    }

    // MARK: Requests

    /// Sends one request through a new `remote-api-bridge` run and decodes its `result`.
    public func call<Result: Decodable & Sendable>(
        _ method: String,
        _ params: [String: any Sendable] = [:],
    ) async throws -> Result {
        let request: [String: Any] = ["id": "1", "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw HerdrError.failed("\(method): params are not JSON")
        }
        let line = try String(decoding: JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let channel = try await exec.run(bridge)
        channel.write(line)
        let reply = try await withTimeout(timeout, onTimeout: channel.terminate) {
            await channel.lines.first { _ in true }
        }
        channel.closeInput()
        guard let reply else { throw await HerdrError.failed(channel.exit().stderr) }
        let decoded = try decode(Reply<Result>.self, reply)
        if let error = decoded.error {
            throw HerdrError.herdr(code: error.code, message: error.message)
        }
        guard let result = decoded.result else { throw HerdrError.failed("\(method): no result") }
        return result
    }

    /// Checks that the server answers and is new enough.
    public func ping() async throws {
        let pong: Pong = try await call("ping")
        let have = pong.version.split(separator: ".").map { Int($0) ?? 0 }
        let need = herdrVersion.split(separator: ".").map { Int($0) ?? 0 }
        if have.lexicographicallyPrecedes(need) {
            throw HerdrError.unsupported("herdr \(pong.version) is too old; \(herdrVersion) or newer needed")
        }
    }

    /// Every session herdr knows on this machine, running or not.
    public func sessions() async throws -> [Session] {
        let channel = try await exec.run([herdr, "--session", session, "session", "list", "--json"])
        channel.closeInput()
        let output = try await withTimeout(timeout, onTimeout: channel.terminate) {
            await channel.lines.reduce("") { $0 + $1 }
        }
        return try decode(SessionList.self, output).sessions
    }

    /// One `session.snapshot`, with every tab's split tree.
    public func snapshot() async throws -> Snapshot {
        var snapshot = try await (call("session.snapshot") as SnapshotResult).snapshot
        for layout in snapshot.layouts {
            if let tree = SplitNode(layout) {
                snapshot.trees[layout.tabID] = tree
            } else {
                let export: ExportResult = try await call("layout.export", ["tab_id": layout.tabID])
                snapshot.trees[layout.tabID] = export.layout.root
            }
        }
        return snapshot
    }

    private var bridge: [String] {
        [herdr, "--session", session, "remote-api-bridge"]
    }

    private static func firstLine(_ exec: any Exec, _ argv: [String]) async throws -> String? {
        let channel = try await exec.run(argv)
        channel.closeInput()
        return try await withTimeout(.seconds(10), onTimeout: channel.terminate) {
            await channel.lines.first { _ in true }
        }
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    } catch {
        throw HerdrError.failed("unreadable reply from herdr: \(error)")
    }
}

private struct Reply<Result: Decodable>: Decodable {
    let result: Result?
    let error: ReplyError?
}

private struct ReplyError: Decodable {
    let code: String
    let message: String
}

private struct Pong: Decodable {
    let version: String
}

private struct SessionList: Decodable {
    let sessions: [Session]
}

private struct SnapshotResult: Decodable {
    let snapshot: Snapshot
}

private struct ExportResult: Decodable {
    struct Layout: Decodable { let root: SplitNode }
    let layout: Layout
}
