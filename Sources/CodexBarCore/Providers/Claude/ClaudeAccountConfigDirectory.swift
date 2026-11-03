import Foundation

/// The Claude Code profile folder (`CLAUDE_CONFIG_DIR`) owned by one Claude token account.
///
/// Claude Code scopes its credential storage to the literal `CLAUDE_CONFIG_DIR` string; on macOS the Keychain service
/// name embeds a hash of it. A different spelling of the same folder (a symlink, a trailing slash, `~`) therefore
/// selects a different credential. CodexBar stores one normalized absolute path and passes that exact string to both
/// the browser sign-in (`claude auth login`) and the usage probe. Only Claude Code reads or refreshes the credential;
/// CodexBar never writes one.
public enum ClaudeAccountConfigDirectory {
    public static let accountsDirectoryName = "claude-accounts"
    /// Claude Code's long-lived token override; it would replace the folder's own login.
    public static let claudeCodeOAuthTokenEnvironmentKey = "CLAUDE_CODE_OAUTH_TOKEN"

    /// `~/.config/codexbar/claude-accounts/<account UUID>`, created on demand by the browser sign-in.
    public static func defaultURL(accountID: UUID, homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("codexbar", isDirectory: true)
            .appendingPathComponent(self.accountsDirectoryName, isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    /// The canonical spelling stored on the account: absolute, `~` expanded, `.`/`..` and trailing slashes removed,
    /// and symbolic links of existing components resolved. Empty or relative input returns nil.
    /// Normalizing an already normalized path returns it unchanged.
    public static func normalizedPath(
        _ raw: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        guard let path = self.standardizedAbsolutePath(raw, homeDirectory: homeDirectory) else { return nil }
        let resolved = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
        return resolved.isEmpty ? nil : resolved
    }

    /// The normalized folder a token account may sign in to and probe, or nil when it is missing, relative, or one
    /// of the default Claude Code locations (`~` or `~/.claude`), which belong to the user's own Claude login.
    public static func accountProfilePath(
        _ raw: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        guard let spelled = self.standardizedAbsolutePath(raw, homeDirectory: homeDirectory),
              let path = self.normalizedPath(spelled, homeDirectory: homeDirectory),
              !self.isDefaultClaudeLocation(spelled, homeDirectory: homeDirectory),
              !self.isDefaultClaudeLocation(path, homeDirectory: homeDirectory)
        else { return nil }
        return path
    }

    /// Compares against the home folder's spellings only, so checking a path never inspects `~/.claude` itself.
    public static func isDefaultClaudeLocation(_ path: String, homeDirectory: URL) -> Bool {
        let spelledHome = URL(fileURLWithPath: homeDirectory.path, isDirectory: true).standardizedFileURL.path
        let resolvedHome = URL(fileURLWithPath: spelledHome, isDirectory: true).resolvingSymlinksInPath().path
        return path == "/" || [spelledHome, resolvedHome].contains { home in
            path == home || path == home + "/.claude"
        }
    }

    /// `~` expanded and `.`/`..` and trailing slashes removed, without touching the filesystem.
    private static func standardizedAbsolutePath(_ raw: String?, homeDirectory: URL) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let expanded: String = if trimmed == "~" {
            homeDirectory.path
        } else if trimmed.hasPrefix("~/") {
            homeDirectory.path + "/" + trimmed.dropFirst(2)
        } else {
            trimmed
        }
        // Claude resolves a relative CLAUDE_CONFIG_DIR against its working directory; refuse that ambiguity.
        guard expanded.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        return path.isEmpty ? nil : path
    }

    /// Environment for a Claude child process bound to this account folder. Ambient overrides that would make Claude
    /// read another credential (a secure-storage folder, an OAuth token, or API keys) are removed.
    public static func scopedEnvironment(base: [String: String], configDirectory: String) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey)
        environment.removeValue(forKey: self.claudeCodeOAuthTokenEnvironmentKey)
        environment.removeValue(forKey: ClaudeOAuthCredentialsStore.environmentTokenKey)
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] = configDirectory
        return environment
    }

    /// Returns the folder the browser sign-in should use, creating it when missing. Without a configured folder the
    /// account gets `defaultURL(accountID:homeDirectory:)` with owner-only (0700) permissions.
    public static func prepare(
        existing: String?,
        accountID: UUID,
        homeDirectory: URL,
        fileManager: FileManager = .default) throws -> String
    {
        let configured = existing?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let target: String
        if configured {
            guard let path = self.normalizedPath(existing, homeDirectory: homeDirectory) else {
                throw ClaudeAccountConfigDirectoryError.invalidPath
            }
            target = path
        } else {
            target = self.defaultURL(accountID: accountID, homeDirectory: homeDirectory).path
        }
        guard !self.isDefaultClaudeLocation(target, homeDirectory: homeDirectory),
              configured ? self.accountProfilePath(existing, homeDirectory: homeDirectory) != nil : true
        else {
            throw ClaudeAccountConfigDirectoryError.defaultClaudeLocation
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ClaudeAccountConfigDirectoryError.notADirectory }
        } else {
            try fileManager.createDirectory(
                atPath: target,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        }
        if !configured {
            // The generated folder holds only this account's Claude state.
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: target)
        }
        guard let normalized = self.accountProfilePath(target, homeDirectory: homeDirectory) else {
            throw ClaudeAccountConfigDirectoryError.invalidPath
        }
        return normalized
    }
}

public enum ClaudeAccountConfigDirectoryError: LocalizedError, Equatable, Sendable {
    case invalidPath
    case notADirectory
    case defaultClaudeLocation
    case accountNotFound
    case missingDirectory
    case signInRequired

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            "The Claude config directory must be an absolute folder path."
        case .notADirectory:
            "The Claude config directory points to a file, not a folder."
        case .defaultClaudeLocation:
            "Choose a separate folder for this account; the default Claude Code folder belongs to your own login."
        case .accountNotFound:
            "This Claude account was removed."
        case .missingDirectory:
            "This Claude account's folder is missing. Use Sign in with Browser… in Settings → Providers → Claude."
        case .signInRequired:
            "This Claude account is signed out. Use Sign in with Browser… in Settings → Providers → Claude."
        }
    }
}
