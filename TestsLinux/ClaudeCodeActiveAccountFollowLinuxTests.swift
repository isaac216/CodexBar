import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCodeActiveAccountFollowLinuxTests {
    @Test
    func `a Claude Code switch selects the token account signed in to the same account`() {
        let decision = ClaudeCodeActiveAccountFollow.decide(
            claudeCodeAccountUuid: " UUID-Work ",
            lastHandledAccountUuid: "uuid-personal",
            tokenAccountUuids: { ["uuid-personal", nil, "uuid-work"] },
            activeIndex: 0)
        #expect(decision == .init(indexToSelect: 2, handledAccountUuid: "uuid-work"))
    }

    @Test
    func `an unchanged Claude Code account keeps a manual pick without reading account folders`() {
        var evaluated = false
        let decision = ClaudeCodeActiveAccountFollow.decide(
            claudeCodeAccountUuid: "uuid-work",
            lastHandledAccountUuid: "UUID-WORK",
            tokenAccountUuids: {
                evaluated = true
                return ["uuid-personal", "uuid-work"]
            },
            activeIndex: 0)
        #expect(decision == .unchanged)
        #expect(!evaluated)
    }

    @Test
    func `an already selected match is settled without a new selection`() {
        let decision = ClaudeCodeActiveAccountFollow.decide(
            claudeCodeAccountUuid: "uuid-work",
            lastHandledAccountUuid: nil,
            tokenAccountUuids: { ["uuid-work", "uuid-personal", "uuid-work"] },
            activeIndex: 2)
        #expect(decision == .init(indexToSelect: nil, handledAccountUuid: "uuid-work"))
    }

    @Test
    func `signed out or unmatched Claude Code accounts stay unsettled`() {
        for current in [nil, "", "  "] as [String?] {
            #expect(ClaudeCodeActiveAccountFollow.decide(
                claudeCodeAccountUuid: current,
                lastHandledAccountUuid: "uuid-work",
                tokenAccountUuids: { ["uuid-work"] },
                activeIndex: 0) == .unchanged)
        }
        #expect(ClaudeCodeActiveAccountFollow.decide(
            claudeCodeAccountUuid: "uuid-other",
            lastHandledAccountUuid: "uuid-work",
            tokenAccountUuids: { ["uuid-work", nil] },
            activeIndex: 0) == .unchanged)
    }

    @Test
    func `account uuids come from the default profile and each account folder`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeActiveAccountFollowLinuxTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let folder = home.appendingPathComponent("claude-work", isDirectory: true)
        let empty = home.appendingPathComponent("claude-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Self.writeConfig(accountUuid: "uuid-ambient", to: home.appendingPathComponent(".claude.json"))
        try Self.writeConfig(accountUuid: "uuid-folder", to: folder.appendingPathComponent(".claude.json"))

        #expect(ClaudeCodeActiveAccountFollow.claudeCodeAccountUuid(environment: environment) == "uuid-ambient")
        #expect(ClaudeCodeActiveAccountFollow.tokenAccountUuid(
            configDirectory: folder.path, environment: environment) == "uuid-folder")
        #expect(ClaudeCodeActiveAccountFollow.tokenAccountUuid(
            configDirectory: empty.path, environment: environment) == nil)
        #expect(ClaudeCodeActiveAccountFollow.tokenAccountUuid(
            configDirectory: nil, environment: environment) == nil)

        // Claude Code prefers the folder's `.config.json` over its `.claude.json` fallback.
        try Self.writeConfig(accountUuid: "uuid-profile", to: folder.appendingPathComponent(".config.json"))
        #expect(ClaudeCodeActiveAccountFollow.tokenAccountUuid(
            configDirectory: folder.path, environment: environment) == "uuid-profile")

        // The default Claude Code locations belong to Claude Code's own login and never count as an account folder.
        let defaultRoot = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try Self.writeConfig(accountUuid: "uuid-ambient", to: defaultRoot.appendingPathComponent(".claude.json"))
        #expect(ClaudeCodeActiveAccountFollow.tokenAccountUuid(
            configDirectory: defaultRoot.path, environment: environment) == nil)
        #expect(ClaudeCodeActiveAccountFollow.tokenAccountUuid(
            configDirectory: home.path, environment: environment) == nil)
    }

    private static func writeConfig(accountUuid: String, to url: URL) throws {
        let json: [String: Any] = ["oauthAccount": ["accountUuid": accountUuid, "emailAddress": "user@example.com"]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }
}
