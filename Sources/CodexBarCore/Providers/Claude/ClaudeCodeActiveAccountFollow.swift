import Foundation

/// Keeps the selected Claude token account on the account Claude Code itself is signed in to, so the menu bar follows
/// `/login` and Switch Account without a manual pick in Settings.
///
/// Identities are the `oauthAccount.accountUuid` values Claude Code writes to its plain-text config: the default
/// profile's for Claude Code's own login, and each account folder's (`CLAUDE_CONFIG_DIR`) for the token accounts.
/// No credential is read. Only a change of Claude Code's own account moves the selection, so a manual pick in Settings
/// stays until Claude Code switches accounts again.
public enum ClaudeCodeActiveAccountFollow {
    public struct Decision: Equatable, Sendable {
        public static let unchanged = Self(indexToSelect: nil, handledAccountUuid: nil)

        /// The token account index to select, or nil to keep the current selection.
        public let indexToSelect: Int?
        /// Claude Code's account this decision settled. Nil leaves the remembered account as it was.
        public let handledAccountUuid: String?

        public init(indexToSelect: Int?, handledAccountUuid: String?) {
            self.indexToSelect = indexToSelect
            self.handledAccountUuid = handledAccountUuid
        }
    }

    /// - Parameters:
    ///   - claudeCodeAccountUuid: The account Claude Code's own login uses; nil when it is signed out or unreadable.
    ///   - lastHandledAccountUuid: The Claude Code account a previous decision settled.
    ///   - tokenAccountUuids: Per token account, the account its own folder is signed in to. Evaluated only when
    ///     Claude Code's account differs from `lastHandledAccountUuid`.
    ///   - activeIndex: The currently selected token account.
    /// An account Claude Code uses that no token account folder is signed in to stays unsettled, so it is matched
    /// once its folder signs in.
    public static func decide(
        claudeCodeAccountUuid: String?,
        lastHandledAccountUuid: String?,
        tokenAccountUuids: () -> [String?],
        activeIndex: Int) -> Decision
    {
        guard let current = self.normalized(claudeCodeAccountUuid),
              current != self.normalized(lastHandledAccountUuid)
        else { return .unchanged }
        let accountUuids = tokenAccountUuids()
        let matches = accountUuids.indices.filter { self.normalized(accountUuids[$0]) == current }
        guard let first = matches.first else { return .unchanged }
        if matches.contains(activeIndex) {
            return Decision(indexToSelect: nil, handledAccountUuid: current)
        }
        return Decision(indexToSelect: first, handledAccountUuid: current)
    }

    /// The account Claude Code's own login uses, as seen from `environment`.
    public static func claudeCodeAccountUuid(environment: [String: String]) -> String? {
        ClaudeAccountProfile.accountUuid(environment: environment)
    }

    /// The account a token account's own folder is signed in to. Accounts without a usable folder (pasted
    /// credentials, a missing path, or one of Claude Code's default locations) return nil and never match.
    public static func tokenAccountUuid(configDirectory: String?, environment: [String: String]) -> String? {
        let home = ClaudeConfigPaths.homeDirectory(environment: environment)
        guard let path = ClaudeAccountConfigDirectory.accountProfilePath(configDirectory, homeDirectory: home) else {
            return nil
        }
        return ClaudeAccountProfile.accountUuid(
            environment: ClaudeAccountConfigDirectory.scopedEnvironment(base: environment, configDirectory: path))
    }

    private static func normalized(_ uuid: String?) -> String? {
        guard let trimmed = uuid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
