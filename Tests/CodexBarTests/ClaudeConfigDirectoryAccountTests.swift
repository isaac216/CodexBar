import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// App-side routing for a Claude token account that signs in through its own config directory. Core routing, the
/// probe environment, and the no-default-credential guarantees are covered by `ClaudeConfigDirectoryCoreRoutingTests`.
@Suite(.serialized)
@MainActor
struct ClaudeConfigDirectoryAccountTests {
    @Test(arguments: [
        ClaudeUsageDataSource.auto,
        ClaudeUsageDataSource.api,
        ClaudeUsageDataSource.web,
        ClaudeUsageDataSource.cli,
        ClaudeUsageDataSource.oauth,
    ])
    func `credential-less config directory account routes to the Claude CLI in the app`(
        globalSource: ClaudeUsageDataSource) async throws
    {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("account-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fixture.accountDirectory.path)
        let settings = testSettingsStore(suiteName: "ClaudeConfigDirectoryAccountTests-\(globalSource.rawValue)")
        settings.claudeUsageDataSource = globalSource
        settings.claudeWebExtrasEnabled = true

        settings.addTokenAccount(provider: .claude, label: "Work", token: "  ", claudeConfigDirectory: link + "/")
        let account = try #require(settings.selectedTokenAccount(for: .claude))
        let env = ProviderRegistry.makeEnvironment(
            base: fixture.ambientEnvironment,
            provider: .claude,
            settings: settings,
            tokenOverride: nil)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
        let sourceMode = ProviderRegistry.resolvedSourceMode(provider: .claude, settings: settings, account: account)
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: snapshot,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: account.id)
        let strategies = await ProviderDescriptorRegistry.descriptor(for: .claude)
            .fetchPlan.pipeline.resolveStrategies(context)

        // The stored spelling is the normalized folder, the same string sign-in and probe pass to Claude.
        #expect(account.token.isEmpty)
        #expect(account.claudeConfigDirectory == fixture.accountDirectory.path)
        #expect(env[ClaudeConfigPaths.configDirectoryEnvironmentKey] == fixture.accountDirectory.path)
        #expect(env[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] == nil)
        #expect(sourceMode == .cli)
        #expect(snapshot.claude?.usageDataSource == .cli)
        #expect(snapshot.claude?.cookieSource == .off)
        #expect(snapshot.claude?.webExtrasEnabled == false)
        #expect(snapshot.claude?.accountConfigDirectory == fixture.accountDirectory.path)
        #expect(strategies.map(\.id) == ["claude.cli"])
    }

    @Test
    func `only Claude token accounts may start without a pasted credential`() {
        let settings = testSettingsStore(suiteName: "ClaudeConfigDirectoryAccountTests-empty-token")

        settings.addTokenAccount(provider: .zai, label: "z.ai", token: "   ")
        settings.addTokenAccount(provider: .claude, label: "Claude", token: "")

        #expect(settings.tokenAccounts(for: .zai).isEmpty)
        #expect(settings.tokenAccounts(for: .claude).map(\.label) == ["Claude"])
        // Without a folder the account has no credential authority and fails closed.
        #expect(ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
            .claude?.accountConfigDirectory == nil)
    }

    @Test
    func `stacked layout refreshes every config directory account`() throws {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let settings = testSettingsStore(suiteName: "ClaudeConfigDirectoryAccountTests-stacked")
        settings.multiAccountMenuLayout = .stacked
        settings.accountWidgetsEnabled = false
        settings.addTokenAccount(
            provider: .claude,
            label: "Personal",
            token: "",
            claudeConfigDirectory: fixture.accountDirectory.path)
        settings.addTokenAccount(provider: .claude, label: "Work", token: "", claudeConfigDirectory: second.path)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        #expect(store.shouldFetchAllTokenAccounts(provider: .claude, accounts: store.tokenAccounts(for: .claude)))
        settings.multiAccountMenuLayout = .segmented
        #expect(!store.shouldFetchAllTokenAccounts(provider: .claude, accounts: store.tokenAccounts(for: .claude)))
    }
}
