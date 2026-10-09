import Foundation
@testable import HerdrKit
import Testing

@Test func `reads frames and skips other lines`() {
    let line = #"{"type":"terminal.frame","seq":3,"encoding":"ansi","width":80,"height":24,"full":true,"#
        + #""bytes":"G1sySmhp"}"#
    #expect(TerminalStream.event(line) == .frame(.init(seq: 3, width: 80, height: 24, full: true,
                                                       bytes: Data("\u{1B}[2Jhi".utf8))))
    #expect(TerminalStream.event(#"{"type":"terminal.frame","width":80,"height":24,"bytes":"%%"}"#) == nil)
    #expect(TerminalStream.event(#"{"type":"terminal.graphics"}"#) == nil)
    #expect(TerminalStream.event("herdr: warning") == nil)
}

@Test(arguments: [
    ("terminal attach failed: terminal term_1 already has an attached client; retry with --takeover", .held),
    ("terminal attach taken over", .takenOver),
    ("terminal session control failed: terminal target term_1 not found", .gone),
    ("terminal term_1 exited", .gone),
    ("detached", .detached),
    ("live update in progress; reconnect after handoff completes", .liveUpdate),
    ("server shutting down", .failed("server shutting down")),
] as [(String, TerminalStream.Closed)])
func `sorts closed reasons`(reason: String, closed: TerminalStream.Closed) {
    let line = #"{"type":"terminal.closed","reason":"\#(reason)"}"#
    #expect(TerminalStream.event(line) == .closed(closed))
}

@Test func `encodes commands as one sorted line`() {
    #expect(TerminalStream.line(["type": "terminal.input", "text": "ls\r"])
        == #"{"text":"ls\r","type":"terminal.input"}"#)
    #expect(TerminalStream.line(["type": "terminal.resize", "cols": 120, "rows": 40])
        == #"{"cols":120,"rows":40,"type":"terminal.resize"}"#)
}

@Test func `a run that ends without a closed line fails with stderr`() async {
    let (lines, end) = AsyncStream<String>.makeStream()
    let stream = TerminalStream(Channel(lines: lines, write: { _ in }, closeInput: {}, terminate: {},
                                        exit: { (1, "herdr: failed to connect\n") }))
    end.finish()
    #expect(await stream.events.first { _ in true } == .closed(.failed("herdr: failed to connect")))
}
