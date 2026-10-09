import Foundation

/// Runs argv on a machine. The one seam for This Mac, remote machines and iOS.
public protocol Exec: Sendable {
    func run(_ argv: [String]) async throws -> Channel
}

/// A running command: stdout lines, a stdin writer, and its end.
public struct Channel: Sendable {
    /// Stdout, one element per line. Ends when the command closes stdout.
    public let lines: AsyncStream<String>
    /// Writes one line to stdin.
    public let write: @Sendable (String) -> Void
    public let closeInput: @Sendable () -> Void
    public let terminate: @Sendable () -> Void
    /// Waits for the command to end and gives back its exit status and stderr.
    public let exit: @Sendable () async -> (status: Int32, stderr: String)
}

#if os(macOS)
    import Synchronization

    /// Runs commands on This Mac with the user's login-shell environment.
    /// ponytail: This Mac only, so no SSH prefix and no base64 envelope; remote machines add them.
    public struct ProcessExec: Exec {
        let environment: [String: String]

        /// Reads the login-shell environment once; keep one instance for the app's life.
        public init() async {
            // A write to a child that already exited must fail, not kill the app.
            signal(SIGPIPE, SIG_IGN)
            environment = await Self.loginEnvironment()
        }

        public func run(_ argv: [String]) async throws -> Channel {
            try Self.spawn(argv, environment)
        }

        /// A GUI app does not get the shell's environment, so ask the login shell once.
        static func loginEnvironment() async -> [String: String] {
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR_") }
            let home = env["HOME"] ?? NSHomeDirectory()
            let marker = "hl-env-\(UUID().uuidString)"
            var found: [String: String] = [:]
            if let channel = try? spawn(
                [env["SHELL"] ?? "/bin/zsh", "-lic", "echo \(marker); /usr/bin/env; echo \(marker)"],
                env,
            ) {
                // Closed stdin reads like /dev/null.
                channel.closeInput()
                found = await (try? withTimeout(.seconds(3), onTimeout: channel.terminate) {
                    var vars: [String: String] = [:]
                    var seen = false
                    // Stop at the second marker: a process the shell started may keep stdout open.
                    for await line in channel.lines {
                        if line.hasSuffix(marker) { // an rc file may print without a final newline
                            if seen {
                                break
                            }
                            seen = true
                        } else if seen, let equals = line.firstIndex(of: "=") {
                            vars[String(line[..<equals])] = String(line[line.index(after: equals)...])
                        }
                    }
                    return vars
                }) ?? [:]
            }
            for key in ["PATH", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME", "XDG_STATE_HOME"] {
                if let value = found[key] {
                    env[key] = value
                }
            }
            if found["PATH"] == nil {
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            }
            return env
        }

        /// Children alive now, so they can be killed by pid when the app quits.
        private static let children: Mutex<Set<pid_t>> = {
            atexit { ProcessExec.children.withLock { $0.forEach { kill($0, SIGKILL) } } }
            return Mutex([])
        }()

        /// A pipe's output until EOF. Not `FileHandle.bytes`: with several pipes open at once it
        /// stalls (seen on macOS 27 with a second bridge run while the events stream is open).
        private static func chunks(_ handle: FileHandle) -> AsyncStream<Data> {
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            return stream
        }

        private static func split(_ handle: FileHandle, into lines: AsyncStream<String>.Continuation) {
            let output = chunks(handle)
            Task {
                var buffer = Data()
                for await data in output {
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        lines.yield(String(decoding: buffer[..<newline], as: UTF8.self))
                        buffer.removeSubrange(...newline)
                    }
                }
                if !buffer.isEmpty {
                    lines.yield(String(decoding: buffer, as: UTF8.self))
                }
                lines.finish()
            }
        }

        private static func spawn(_ argv: [String], _ environment: [String: String]) throws -> Channel {
            let process = Process()
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = argv
            process.environment = environment
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            let (ended, endedContinuation) = AsyncStream<Int32>.makeStream()
            debugLog("spawn \(argv)")
            process.terminationHandler = {
                debugLog("end \($0.terminationStatus) \(argv)")
                let pid = $0.processIdentifier
                children.withLock { _ = $0.remove(pid) }
                endedContinuation.yield($0.terminationStatus)
                endedContinuation.finish()
            }
            // Under the lock, so a child that ends at once cannot be removed before it is added.
            let pid = try children.withLock {
                try process.run()
                $0.insert(process.processIdentifier)
                return process.processIdentifier
            }

            let (lines, linesContinuation) = AsyncStream<String>.makeStream()
            // Ending the stream too, so a reader never waits on a child that ignores the signal.
            let terminate: @Sendable () -> Void = {
                children.withLock {
                    if $0.contains(pid) {
                        kill(pid, SIGKILL)
                    }
                }
                linesContinuation.finish()
            }
            linesContinuation.onTermination = { _ in terminate() }
            split(stdout.fileHandleForReading, into: linesContinuation)
            let errorOutput = chunks(stderr.fileHandleForReading)
            let errors = Task {
                var data = Data()
                for await chunk in errorOutput {
                    // Only the tail: long-lived streams may log for hours.
                    data = (data + chunk).suffix(8192)
                }
                return String(decoding: data, as: UTF8.self)
            }
            let status = Task { await ended.first { _ in true } ?? -1 }
            let input = stdin.fileHandleForWriting
            return Channel(
                lines: lines,
                // ponytail: blocks the caller while the pipe is full; phase 4 moves terminal writes off the main actor.
                write: { try? input.write(contentsOf: Data(($0 + "\n").utf8)) },
                closeInput: { try? input.close() },
                terminate: terminate,
                exit: { await (status.value, errors.value) },
            )
        }
    }
#endif

/// Temporary CI debugging, never merged.
func debugLog(_ msg: String) {
    let line = Data("\(Date().timeIntervalSince1970) \(msg)\n".utf8)
    if let handle = FileHandle(forWritingAtPath: "/tmp/hl-exec.log") {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: "/tmp/hl-exec.log", contents: line)
    }
}
