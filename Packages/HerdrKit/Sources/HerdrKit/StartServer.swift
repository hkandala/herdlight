import Foundation

#if os(macOS)
    public extension HerdrClient {
        /// Starts this session's server as a one-shot launchd job, so launchd, not the app, is its parent
        /// and responsible process (design D47), and waits until it answers. No KeepAlive: once
        /// `herdr session stop` ends it, launchd keeps the job loaded but never runs it again.
        /// ponytail: This Mac only; remote machines start herdr over SSH.
        nonisolated func startServer() async throws {
            // The name goes into a launchd label and file paths.
            guard Session.isValidName(session) else { throw HerdrError.failed("“\(session)” is not a session name") }
            // Already up (started elsewhere since): booting out its job would stop it.
            if await (try? ping()) != nil {
                return
            }
            let label = "dev.hkandala.herdlight.herdr.\(session)"
            let domain = "gui/\(getuid())"
            let plist = FileManager.default.temporaryDirectory.appending(path: "\(label).plist")
            let logs = URL.libraryDirectory.appending(path: "Logs/Herdlight")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appending(path: "\(session).log").path
            // Interactive: launchd's default throttles the CPU and I/O of the server and every agent in it.
            let job: [String: Any] = ["Label": label, "ProgramArguments": [herdr, "--session", session, "server"],
                                      "RunAtLoad": true, "ProcessType": "Interactive", "StandardErrorPath": log]
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
            defer { try? FileManager.default.removeItem(at: plist) }
            // The job of a server that stopped since is still loaded, and a label loads only once.
            _ = try? await Self.output(exec, ["launchctl", "bootout", "\(domain)/\(label)"])
            let channel = try await exec.run(["launchctl", "bootstrap", domain, plist.path])
            channel.closeInput()
            let (status, stderr) = await channel.exit()
            guard status == 0 else {
                throw HerdrError.failed("launchctl bootstrap exited \(status): \(stderr)")
            }
            for _ in 0 ..< 50 {
                if await (try? ping()) != nil {
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw HerdrError.failed("herdr --session \(session) server did not start; see \(log)")
        }
    }
#endif
