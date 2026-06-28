import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the screen/tmux window-title escape stripper used on mirrored `%output`.
/// A remote shell inside tmux (TERM=screen*/tmux*) sets its title with
/// `ESC k <title> ST`; cmux's xterm-style mirror surface would print the title text
/// otherwise (the `echoej` bug). The filter must drop the sequence, survive chunk
/// splits, and leave everything else byte-identical.
@Suite struct RemoteTmuxScreenTitleFilterTests {
    private func run(_ chunks: [String]) -> String {
        var f = RemoteTmuxScreenTitleFilter()
        var out = Data()
        for c in chunks { out.append(f.filter(Data(c.utf8))) }
        return String(decoding: out, as: UTF8.self)
    }
    private func run(_ s: String) -> String { run([s]) }

    private let ESC = "\u{1b}"

    @Test func stripsStTerminatedTitleBetweenText() {
        // The exact echoej repro: command output `ej` preceded by `ESC k echo ESC \`.
        let input = "\(ESC)kecho\(ESC)\\ej"
        #expect(run(input) == "ej")
    }

    @Test func belDoesNotTerminateTitleMatchingTmux() {
        // tmux/screen end `ESC k` only on ST (`ESC \`), never BEL. A BEL is swallowed
        // as title text and the title runs until ST — matching the remote's rendering.
        #expect(run("a\(ESC)kfoo\u{07}bar\(ESC)\\Z") == "aZ")  // ST ends it; BEL was consumed
        #expect(run("a\(ESC)kfoo\u{07}bar") == "a")            // no ST: rest consumed (like tmux)
    }

    @Test func stripsMultipleTitlesAndKeepsSurroundingText() {
        // Prompt sets title to `~`, command sets it to `echo`, output is `ej`.
        let input = "\(ESC)k~\(ESC)\\prompt \(ESC)kecho\(ESC)\\ej\r\n"
        #expect(run(input) == "prompt ej\r\n")
    }

    @Test func survivesChunkSplitsAtEveryBoundary() {
        let full = "X\(ESC)kabc\(ESC)\\Y"
        let bytes = Array(full.utf8)
        // Split the stream after each byte and confirm the result is always "XY".
        for cut in 1..<bytes.count {
            var f = RemoteTmuxScreenTitleFilter()
            var out = Data()
            out.append(f.filter(Data(bytes[0..<cut])))
            out.append(f.filter(Data(bytes[cut...])))
            #expect(String(decoding: out, as: UTF8.self) == "XY", "split at \(cut)")
        }
    }

    @Test func preservesCsiAndOtherEscapes() {
        // Color SGR and cursor moves must pass through untouched.
        let input = "\(ESC)[32mgreen\(ESC)[0m\(ESC)[2J\(ESC)[H"
        #expect(run(input) == input)
    }

    @Test func preservesEscFollowedByNonK() {
        // `ESC \` (ST) on its own, and an OSC title, are not `ESC k` and pass through.
        #expect(run("\(ESC)\\done") == "\(ESC)\\done")
        #expect(run("\(ESC)]0;title\u{07}x") == "\(ESC)]0;title\u{07}x")
    }

    @Test func plainTextUnchanged() {
        #expect(run("echo \"ej\"\r\nej\r\n") == "echo \"ej\"\r\nej\r\n")
    }

    @Test func titleImmediatelyFollowedByMoreTitle() {
        #expect(run("\(ESC)ka\(ESC)\\\(ESC)kb\(ESC)\\Z") == "Z")
    }
}
