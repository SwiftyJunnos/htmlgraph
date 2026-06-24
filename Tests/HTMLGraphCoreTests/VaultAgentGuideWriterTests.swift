import XCTest
@testable import HTMLGraphCore

final class VaultAgentGuideWriterTests: XCTestCase {
    func testWritesBothFilesWhenMissing() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let outcome = try await VaultAgentGuideWriter().writeIfMissing(vaultURL: vaultURL)

        XCTAssertEqual(outcome, .init(wroteAgents: true, wroteClaude: true))
        XCTAssertTrue(outcome.createdAny)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL).path))
    }

    func testFilesLandAtVaultRootWithExpectedNames() {
        let vaultURL = URL(fileURLWithPath: "/tmp/SomeVault", isDirectory: true)

        let agents = VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL)
        let claude = VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL)

        XCTAssertEqual(agents.lastPathComponent, "AGENTS.md")
        XCTAssertEqual(claude.lastPathComponent, "CLAUDE.md")
        XCTAssertEqual(agents.deletingLastPathComponent().standardizedFileURL, vaultURL.standardizedFileURL)
        XCTAssertEqual(claude.deletingLastPathComponent().standardizedFileURL, vaultURL.standardizedFileURL)
    }

    func testCreateOnlyDoesNotOverwriteExistingFiles() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let writer = VaultAgentGuideWriter()

        let custom = "# my own notes for the agent\n"
        try custom.write(to: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL), atomically: true, encoding: .utf8)
        try custom.write(to: VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL), atomically: true, encoding: .utf8)

        let outcome = try await writer.writeIfMissing(vaultURL: vaultURL)

        XCTAssertEqual(outcome, .init(wroteAgents: false, wroteClaude: false))
        XCTAssertFalse(outcome.createdAny)
        XCTAssertEqual(try String(contentsOf: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL), encoding: .utf8), custom)
        XCTAssertEqual(try String(contentsOf: VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL), encoding: .utf8), custom)
    }

    func testCreateOnlyFillsMissingFileWithoutTouchingTheOther() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let writer = VaultAgentGuideWriter()

        // The user already has a hand-written CLAUDE.md but no AGENTS.md.
        let custom = "# hand written claude file\n"
        try custom.write(to: VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL), atomically: true, encoding: .utf8)

        let outcome = try await writer.writeIfMissing(vaultURL: vaultURL)

        XCTAssertEqual(outcome, .init(wroteAgents: true, wroteClaude: false))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL).path))
        XCTAssertEqual(try String(contentsOf: VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL), encoding: .utf8), custom)
    }

    func testRegenerateOverwritesExistingFiles() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let writer = VaultAgentGuideWriter()

        let stale = "stale content\n"
        try stale.write(to: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL), atomically: true, encoding: .utf8)
        try stale.write(to: VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL), atomically: true, encoding: .utf8)

        let outcome = try await writer.regenerate(vaultURL: vaultURL)

        XCTAssertEqual(outcome, .init(wroteAgents: true, wroteClaude: true))
        let agents = try String(contentsOf: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL), encoding: .utf8)
        let claude = try String(contentsOf: VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL), encoding: .utf8)
        XCTAssertNotEqual(agents, stale)
        XCTAssertNotEqual(claude, stale)
        XCTAssertTrue(agents.contains("HTMLGraph vault"))
    }

    func testRegenerationIsDeterministic() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let writer = VaultAgentGuideWriter()

        try await writer.regenerate(vaultURL: vaultURL)
        let first = try String(contentsOf: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL), encoding: .utf8)
        try await writer.regenerate(vaultURL: vaultURL)
        let second = try String(contentsOf: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL), encoding: .utf8)

        XCTAssertEqual(first, second, "regeneration must be byte-stable")
    }

    func testClaudePointerImportsAgentsGuide() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try await VaultAgentGuideWriter().writeIfMissing(vaultURL: vaultURL)
        let claude = try String(contentsOf: VaultAgentGuideWriter.claudeFileURL(forVault: vaultURL), encoding: .utf8)

        XCTAssertTrue(claude.contains("@AGENTS.md"), "CLAUDE.md must import AGENTS.md: \(claude)")
    }

    func testAgentsGuideCoversKeyConventions() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try await VaultAgentGuideWriter().writeIfMissing(vaultURL: vaultURL)
        let agents = try String(contentsOf: VaultAgentGuideWriter.agentsFileURL(forVault: vaultURL), encoding: .utf8)

        for token in ["HTMLGraph vault", ".htmlgraph", "graph.json", "Inbox", "Safe mode", "AGENTS.md"] {
            XCTAssertTrue(agents.contains(token), "agent guide should mention “\(token)”")
        }
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
