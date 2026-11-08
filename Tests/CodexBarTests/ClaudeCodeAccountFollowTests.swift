import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeCodeAccountFollowTests {
    @Test
    func `the selected Claude account follows Claude Code and keeps a manual pick until the next switch`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeAccountFollowTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = ["personal", "work", "spare"].map { root.appendingPathComponent($0, isDirectory: true) }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Self.writeConfig(accountUuid: "uuid-personal", to: folders[0].appendingPathComponent(".claude.json"))
        try Self.writeConfig(accountUuid: "uuid-work", to: folders[1].appendingPathComponent(".claude.json"))
        let claudeCodeConfig = root.appendingPathComponent(".claude.json")

        let settings = testSettingsStore(
            suiteName: "ClaudeCodeAccountFollowTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        enableTestProviders([.claude], settings: settings)
        for (label, folder) in zip(["Personal", "Work", "Spare"], folders) {
            settings.addTokenAccount(provider: .claude, label: label, token: "", claudeConfigDirectory: folder.path)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["HOME": root.path],
            widgetSnapshotURL: root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})
        func selected() -> String? {
            settings.selectedTokenAccount(for: .claude)?.label
        }
        #expect(selected() == "Spare")

        try Self.writeConfig(accountUuid: "uuid-work", to: claudeCodeConfig)
        store.prepareRefreshState()
        #expect(selected() == "Work")

        // A manual pick stays while Claude Code keeps its account.
        settings.setActiveTokenAccountIndex(0, for: .claude)
        store.prepareRefreshState(for: .claude)
        #expect(selected() == "Personal")

        // An account no folder is signed in to keeps the pick, and is matched once its folder signs in.
        try Self.writeConfig(accountUuid: "uuid-other", to: claudeCodeConfig)
        store.prepareRefreshState()
        #expect(selected() == "Personal")
        try Self.writeConfig(accountUuid: "uuid-other", to: folders[2].appendingPathComponent(".claude.json"))
        store.prepareRefreshState()
        #expect(selected() == "Spare")

        // Signing Claude Code out keeps the selection.
        try FileManager.default.removeItem(at: claudeCodeConfig)
        store.prepareRefreshState()
        #expect(selected() == "Spare")

        // Only refreshes that include Claude move the selection.
        try Self.writeConfig(accountUuid: "uuid-personal", to: claudeCodeConfig)
        store.prepareRefreshState(for: .codex)
        #expect(selected() == "Spare")
        store.prepareRefreshState(for: .claude)
        #expect(selected() == "Personal")
    }

    private static func writeConfig(accountUuid: String, to url: URL) throws {
        let json: [String: Any] = ["oauthAccount": ["accountUuid": accountUuid, "emailAddress": "user@example.com"]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }
}
