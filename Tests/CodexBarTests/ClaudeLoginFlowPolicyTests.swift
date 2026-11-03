import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct ClaudeLoginFlowTests {
    @Test
    func `successful Claude login controller flow preserves selected source and enables provider`() async throws {
        let registry = ProviderRegistry.shared
        let claudeMetadata = try #require(registry.metadata[.claude])

        for source in ClaudeUsageDataSource.allCases {
            let settings = testSettingsStore(
                suiteName: "ClaudeLoginFlowTests-controller-\(source.rawValue)")
            settings.statusChecksEnabled = false
            settings.refreshFrequency = .manual
            settings.providerDetectionCompleted = true
            settings.claudeUsageDataSource = source
            settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: false)

            let fetcher = UsageFetcher()
            let store = UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)

            await withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
                let didLogin = await controller.runClaudeLoginFlow { _, environment, onPhaseChange in
                    // The menu's ambient sign-in never scopes Claude to an account folder.
                    #expect(environment == nil)
                    onPhaseChange(.requesting)
                    await Task.yield()
                    onPhaseChange(.waitingBrowser)
                    await Task.yield()
                    return ClaudeLoginRunner.Result(
                        outcome: .success,
                        output: "Successfully logged in",
                        authLink: nil)
                }

                #expect(didLogin)
                #expect(controller.loginPhase == .idle)
            }

            #expect(settings.claudeUsageDataSource == source)
            #expect(settings.isProviderEnabledCached(provider: .claude, metadataByProvider: registry.metadata))
        }
    }

    @Test
    func `account browser sign-in runs claude auth login inside the account config directory`() async throws {
        let directory = "/fixtures/claude-accounts/work"
        let settings = testSettingsStore(suiteName: "ClaudeLoginFlowTests-account-config-directory")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.providerDetectionCompleted = true
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let captured = LoginEnvironmentRecorder()

        await withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
            let didLogin = await controller.runClaudeLoginFlow(configDirectory: directory) { _, environment, _ in
                captured.record(environment)
                return ClaudeLoginRunner.Result(outcome: .success, output: "Successfully logged in", authLink: nil)
            }
            #expect(didLogin)
        }

        #expect(captured.environments.count == 1)
        let environment = try #require(captured.environments.compactMap(\.self).first)
        #expect(environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] == directory)
        #expect(environment[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] == nil)
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test
    func `account sign-in folder is created once and stored with its normalized path`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeLoginFlowTests-home-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = testSettingsStore(suiteName: "ClaudeLoginFlowTests-prepare-directory")
        settings.addTokenAccount(provider: .claude, label: "Work", token: "")
        let account = try #require(settings.selectedTokenAccount(for: .claude))

        let directory = try settings.prepareClaudeAccountConfigDirectory(accountID: account.id, homeDirectory: home)
        let again = try settings.prepareClaudeAccountConfigDirectory(accountID: account.id, homeDirectory: home)

        let expected = home.appendingPathComponent(".config/codexbar/claude-accounts/\(account.id.uuidString)").path
        #expect(directory == expected)
        #expect(again == expected)
        #expect(settings.selectedTokenAccount(for: .claude)?.claudeConfigDirectory == expected)
        let permissions = try FileManager.default.attributesOfItem(atPath: expected)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        #expect(throws: ClaudeAccountConfigDirectoryError.accountNotFound) {
            try settings.prepareClaudeAccountConfigDirectory(accountID: UUID(), homeDirectory: home)
        }
    }
}

private final class LoginEnvironmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]?] = []

    var environments: [[String: String]?] {
        self.lock.withLock { self.recorded }
    }

    func record(_ environment: [String: String]?) {
        self.lock.withLock { self.recorded.append(environment) }
    }
}
