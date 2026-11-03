import Foundation

/// Usage for a selected Claude token account that signed in through its own config directory.
///
/// Runs the existing Claude CLI PTY probe with `CLAUDE_CONFIG_DIR` set to the account folder. Only Claude Code reads,
/// refreshes, or stores that folder's credential. CodexBar never loads Claude OAuth credentials, the default
/// `Claude Code-credentials` Keychain item, `~/.claude/.credentials.json`, or browser cookies for this account, and a
/// failure never falls back to another source.
struct ClaudeAccountConfigDirectoryFetchStrategy: ProviderFetchStrategy {
    let id: String = "claude.cli"
    let kind: ProviderFetchKind = .cli
    let configDirectory: String
    private let cli: ClaudeCLIFetchStrategy

    init(configDirectory: String, browserDetection: BrowserDetection) {
        self.configDirectory = configDirectory
        self.cli = ClaudeCLIFetchStrategy(
            useWebExtras: false,
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: browserDetection,
            hasWebFallback: false)
    }

    /// The account folder when the selected account was routed here and its probe environment points at that folder.
    static func selectedAccountDirectory(context: ProviderFetchContext) -> String? {
        guard context.selectedTokenAccountID != nil,
              context.settings?.claude?.usageDataSource == .cli,
              let directory = context.settings?.claude?.accountConfigDirectory,
              context.env[ClaudeConfigPaths.configDirectoryEnvironmentKey] == directory
        else { return nil }
        return directory
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        // Missing folders and signed-out accounts surface as sign-in errors from `fetch`, not as "no source".
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard context.env[ClaudeConfigPaths.configDirectoryEnvironmentKey] == self.configDirectory else {
            throw ClaudeAccountConfigDirectoryError.invalidPath
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: self.configDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ClaudeAccountConfigDirectoryError.missingDirectory
        }
        // Claude records the signed-in account in the folder's plain-text config. Positive signed-out evidence skips
        // an interactive probe that could only stop at Claude's login screen.
        if ClaudeAccountProfile.configOwnershipEvidence(environment: context.env) == .signedOut {
            throw ClaudeAccountConfigDirectoryError.signInRequired
        }
        do {
            return try await self.cli.fetch(context)
        } catch {
            throw Self.accountFacingError(error)
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func accountFacingError(_ error: Error) -> Error {
        if case ClaudeStatusProbeError.authenticationFailed = error {
            return ClaudeAccountConfigDirectoryError.signInRequired
        }
        return error
    }
}
