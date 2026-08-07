import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for the check that decides whether cmux may end an SSH ControlMaster.
///
/// A symlinked ControlPath points at a master the user opened, so ending it would
/// drop their authenticated connection when a mirror window closes or the app quits.
@Suite struct RemoteTmuxControlMasterOwnershipTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-control-master-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func ownsASocketItCreatedItself() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("tmux-host-abc123.sock").path
        FileManager.default.createFile(atPath: path, contents: nil)

        #expect(RemoteTmuxSSHTransport.ownsControlMaster(at: path))
    }

    @Test func doesNotOwnASymlinkedControlPath() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("user-owned-master").path
        FileManager.default.createFile(atPath: target, contents: nil)
        let link = dir.appendingPathComponent("tmux-host-abc123.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        #expect(!RemoteTmuxSSHTransport.ownsControlMaster(at: link))
    }

    /// A dangling link is still the user's path to reuse, and `ssh -O exit` on a
    /// missing socket does nothing anyway, so ownership stays false.
    @Test func doesNotOwnADanglingSymlink() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("tmux-host-abc123.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir.appendingPathComponent("gone").path)

        #expect(!RemoteTmuxSSHTransport.ownsControlMaster(at: link))
    }

    /// No socket yet is the ordinary first-connection state: cmux owns that path.
    @Test func ownsAPathThatDoesNotExistYet() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(RemoteTmuxSSHTransport.ownsControlMaster(at: dir.appendingPathComponent("absent.sock").path))
    }
}
