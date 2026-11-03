import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension ProviderSettingsDescriptorTests {
    @Test
    func `Claude account directory binding persists and clears without changing the credential`() throws {
        let settings = testSettingsStore(
            suiteName: "ClaudeDirectoryDescriptor",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        settings.addTokenAccount(provider: .claude, label: "Personal", token: "fixture-token")
        let account = try #require(settings.selectedTokenAccount(for: .claude))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let pane = ProvidersPane(settings: settings, store: store)
        let descriptor = try #require(pane._test_tokenAccountDescriptor(for: .claude))
        let binding = try #require(descriptor.claudeConfigDirectory)
        let directory = binding(account.id)
        #expect(directory.wrappedValue == nil)
        directory.wrappedValue = "/fixtures/claude-personal"
        #expect(settings.selectedTokenAccount(for: .claude)?.claudeConfigDirectory == directory.wrappedValue)
        #expect(settings.selectedTokenAccount(for: .claude)?.token == "fixture-token")
        directory.wrappedValue = nil
        #expect(settings.selectedTokenAccount(for: .claude)?.claudeConfigDirectory == nil)
        #expect(pane._test_tokenAccountDescriptor(for: .zai)?.claudeConfigDirectory == nil)
        // Only Claude offers browser sign-in and credential-less accounts.
        #expect(descriptor.signInWithBrowser != nil)
        #expect(descriptor.allowsAccountWithoutCredential)
        #expect(pane._test_tokenAccountDescriptor(for: .zai)?.signInWithBrowser == nil)
        #expect(pane._test_tokenAccountDescriptor(for: .zai)?.allowsAccountWithoutCredential == false)
        #expect(ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Work",
            token: " ",
            showsTeamModeControls: false,
            teamMode: false,
            teamContext: (organizationID: "", projectID: "")))
        #expect(!ProviderSettingsTokenAccountsRowView.isAddDisabled(
            label: "Work",
            token: " ",
            showsTeamModeControls: false,
            teamMode: false,
            teamContext: (organizationID: "", projectID: ""),
            allowsEmptyToken: true))

        let root = try CostUsageTestEnvironment()
        defer { root.cleanup() }
        #expect(TokenAccountDirectoryPicker.isAvailable(root.root.path))
        #expect(!TokenAccountDirectoryPicker.isAvailable(root.root.appendingPathComponent("missing").path))
    }
}
