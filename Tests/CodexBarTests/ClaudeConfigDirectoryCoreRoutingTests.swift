import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Core-level routing for a Claude token account that has a config directory and no pasted credential. The CLI
/// (`codexbar usage --account …`) and the app share `ProviderEnvironmentResolver`, the provider credential adapter,
/// and the Claude strategy planner exercised here.
@Suite(.serialized)
struct ClaudeConfigDirectoryCoreRoutingTests {
    @Test(arguments: [
        ProviderSourceMode.auto,
        ProviderSourceMode.api,
        ProviderSourceMode.web,
        ProviderSourceMode.cli,
        ProviderSourceMode.oauth,
    ])
    func `config directory account routes to the CLI probe with its own CLAUDE_CONFIG_DIR`(
        globalSource: ProviderSourceMode) async throws
    {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let account = fixture.account()
        let routed = try Self.route(account: account, globalSource: globalSource, fixture: fixture, runtime: .cli)
        let strategies = await ProviderDescriptorRegistry.descriptor(for: .claude)
            .fetchPlan.pipeline.resolveStrategies(routed.context)

        let directory = fixture.accountDirectory.path
        #expect(routed.env[ClaudeConfigPaths.configDirectoryEnvironmentKey] == directory)
        #expect(routed.env[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] == nil)
        #expect(routed.env["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(routed.env[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
        // The PTY probe keeps the account folder, so every Claude-owned path resolves inside it, never `~/.claude`.
        #expect(ClaudeCLISession.launchEnvironment(baseEnv: routed.env)[ClaudeConfigPaths.configDirectoryEnvironmentKey]
            == directory)
        #expect(ClaudeConfigPaths.credentialsURL(environment: routed.env).path
            == fixture.accountDirectory.appendingPathComponent(".credentials.json").path)
        #expect(ClaudeConfigPaths.accountConfigURL(environment: routed.env).path
            == fixture.accountDirectory.appendingPathComponent(".claude.json").path)
        #expect(routed.context.sourceMode == .cli)
        #expect(routed.settings.claude?.usageDataSource == .cli)
        #expect(routed.settings.claude?.cookieSource == .off)
        #expect(routed.settings.claude?.manualCookieHeader?.isEmpty ?? true)
        #expect(strategies.map(\.id) == ["claude.cli"])
        #expect(strategies.map(\.kind) == [.cli])
    }

    @Test
    func `pasted credential keeps its existing route even when a directory is mapped`() throws {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let account = fixture.account(token: "sessionKey=sk-ant-fixture-session")
        let routed = try Self.route(account: account, globalSource: .auto, fixture: fixture, runtime: .cli)

        #expect(routed.context.sourceMode == .web)
        #expect(routed.settings.claude?.usageDataSource == .web)
        #expect(routed.settings.claude?.manualCookieHeader == "sessionKey=sk-ant-fixture-session")
        #expect(routed.env[ClaudeConfigPaths.configDirectoryEnvironmentKey] == nil)
    }

    @Test(arguments: [ProviderRuntime.app, ProviderRuntime.cli])
    func `config directory fetch never touches default Claude credentials or cookie caches`(
        runtime: ProviderRuntime) async throws
    {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        try fixture.writeSignedInAccountConfig()
        let routed = try Self.route(account: fixture.account(), globalSource: .auto, fixture: fixture, runtime: runtime)
        let cacheRecorder = KeychainCacheStore.OperationRecorder()
        let probeCalls = ProbeCallRecorder()
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { binary, _, _ in
            probeCalls.record(binary)
            return ClaudeConfigDirectoryFixture.usageStatusSnapshot()
        }

        let launchObserver: @Sendable ([String: String]) -> Void = { probeCalls.record($0) }

        let outcome = await KeychainCacheStore.withOperationRecorderForTesting(cacheRecorder) {
            await ClaudeStatusProbe.$launchEnvironmentObserverForTesting.withValue(launchObserver) {
                await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                    await ProviderInteractionContext.$current.withValue(.background) {
                        await ProviderDescriptorRegistry.descriptor(for: .claude).fetchOutcome(context: routed.context)
                    }
                }
            }
        }
        let result = try outcome.result.get()

        #expect(outcome.attempts.map(\.strategyID) == ["claude.cli"])
        #expect(result.sourceLabel == "claude")
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(probeCalls.binaries == [fixture.claudeExecutable.path])
        // OAuth and Web both start from CodexBar's Keychain caches; neither may run for this account.
        #expect(cacheRecorder.operations.isEmpty)
        // The probe launches Claude with the account folder and none of the ambient credential overrides.
        let launch = try #require(probeCalls.launchEnvironments.first)
        #expect(probeCalls.launchEnvironments.count == 1)
        #expect(launch[ClaudeConfigPaths.configDirectoryEnvironmentKey] == fixture.accountDirectory.path)
        #expect(launch[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] == nil)
        #expect(launch["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(launch[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
        #expect(launch["HOME"] == fixture.home.path)
    }

    @Test
    func `signed out or missing account folders fail with sign-in guidance and never launch Claude`() async throws {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing", isDirectory: true).path
        let cases: [(ProviderTokenAccount, ClaudeAccountConfigDirectoryError)] = [
            (fixture.account(), .signInRequired),
            (fixture.account(directory: missing), .missingDirectory),
        ]
        for (account, expected) in cases {
            let routed = try Self.route(account: account, globalSource: .auto, fixture: fixture, runtime: .app)
            let probeCalls = ProbeCallRecorder()
            let fetchOverride: ClaudeStatusProbe.FetchOverride = { binary, _, _ in
                probeCalls.record(binary)
                return ClaudeConfigDirectoryFixture.usageStatusSnapshot()
            }

            let outcome = await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                await ProviderDescriptorRegistry.descriptor(for: .claude).fetchOutcome(context: routed.context)
            }

            #expect(outcome.attempts.map(\.strategyID) == ["claude.cli"])
            #expect(probeCalls.binaries.isEmpty)
            guard case let .failure(error) = outcome.result else {
                Issue.record("Expected \(expected), got a successful fetch")
                continue
            }
            #expect(error as? ClaudeAccountConfigDirectoryError == expected)
            #expect(error.localizedDescription.contains("Sign in with Browser"))
        }
    }

    @Test
    func `Claude CLI authentication failures ask for a browser sign-in again`() {
        let mapped = ClaudeAccountConfigDirectoryFetchStrategy.accountFacingError(
            ClaudeStatusProbeError.authenticationFailed("OAuth token has expired. Please run /login"))
        #expect(mapped as? ClaudeAccountConfigDirectoryError == .signInRequired)
        let timeout = ClaudeAccountConfigDirectoryFetchStrategy.accountFacingError(ClaudeStatusProbeError.timedOut)
        #expect(timeout is ClaudeStatusProbeError)
    }

    @Test
    func `routing keeps pasted credentials and rejects unusable folders`() throws {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let directory = fixture.accountDirectory.path
        let home = fixture.home

        #expect(ClaudeCredentialRouting.resolve(account: fixture.account()) == .configDirectory(path: directory))
        #expect(ClaudeCredentialRouting.resolve(account: fixture.account(token: "  \n")) ==
            .configDirectory(path: directory))
        #expect(ClaudeCredentialRouting.resolve(account: fixture.account(token: "Bearer sk-ant-oat-fixture")) ==
            .oauth(accessToken: "sk-ant-oat-fixture"))
        #expect(ClaudeCredentialRouting.resolve(account: fixture.account(token: "sk-ant-admin-fixture")) ==
            .adminAPIKey("sk-ant-admin-fixture"))
        // A malformed pasted credential still fails closed instead of silently switching to the folder.
        #expect(ClaudeCredentialRouting.resolve(account: fixture.account(token: "Cookie:")) == .none)
        #expect(ClaudeCredentialRouting.resolve(account: fixture.account(directory: "relative/claude")) == .none)
        #expect(ClaudeCredentialRouting.resolve(tokenAccountToken: nil, manualCookieHeader: nil) == .none)
        // The default Claude Code folders belong to the user's own login, never to a token account, whichever
        // spelling or symlink names them. A throwaway home keeps the real `~/.claude` out of this check.
        let defaultRoot = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        let linkToDefault = fixture.root.appendingPathComponent("claude-default-link").path
        try FileManager.default.createSymbolicLink(atPath: linkToDefault, withDestinationPath: defaultRoot.path)
        let spellings = [
            "~/.claude", "~/.claude/", "~", "/", defaultRoot.path, linkToDefault, home.path + "/x/../.claude",
        ]
        for spelling in spellings {
            #expect(ClaudeAccountConfigDirectory.accountProfilePath(spelling, homeDirectory: home) == nil)
        }
        #expect(ClaudeAccountConfigDirectory.accountProfilePath("~/claude-work", homeDirectory: home)
            == home.appendingPathComponent("claude-work").path)
    }

    @Test
    func `stored paths are normalized once so sign-in and probe hash the same CLAUDE_CONFIG_DIR`() throws {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let real = fixture.accountDirectory.path
        let link = fixture.root.appendingPathComponent("account-link").path
        try fileManager.createSymbolicLink(atPath: link, withDestinationPath: real)
        let home = fixture.home

        let spellings = [
            real,
            real + "/",
            real + "//",
            fixture.root.path + "/./account",
            fixture.root.path + "/bin/../account/",
            link,
            link + "/",
            "  " + real + "\n",
        ]
        for spelling in spellings {
            #expect(ClaudeAccountConfigDirectory.normalizedPath(spelling, homeDirectory: home) == real)
        }
        #expect(ClaudeAccountConfigDirectory.normalizedPath("~/claude-work", homeDirectory: home)
            == home.appendingPathComponent("claude-work").path)
        #expect(ClaudeAccountConfigDirectory.normalizedPath("~", homeDirectory: home) == home.path)
        #expect(ClaudeAccountConfigDirectory.normalizedPath("relative/claude", homeDirectory: home) == nil)
        #expect(ClaudeAccountConfigDirectory.normalizedPath("   ", homeDirectory: home) == nil)
        #expect(ClaudeAccountConfigDirectory.normalizedPath(nil, homeDirectory: home) == nil)
        // Idempotent: normalizing a stored value never changes it again.
        #expect(ClaudeAccountConfigDirectory.normalizedPath(real, homeDirectory: home)
            .flatMap { ClaudeAccountConfigDirectory.normalizedPath($0, homeDirectory: home) } == real)

        // The probe environment for an account stored with any spelling carries the normalized folder, the same
        // string the sign-in environment receives.
        let signIn = try ClaudeAccountConfigDirectory.scopedEnvironment(
            base: fixture.ambientEnvironment,
            configDirectory: ClaudeAccountConfigDirectory.prepare(
                existing: link + "/",
                accountID: UUID(),
                homeDirectory: home))
        let probe = ProviderEnvironmentResolver.resolve(
            base: fixture.ambientEnvironment,
            provider: .claude,
            config: nil,
            selectedAccount: fixture.account(directory: link + "/"))
        #expect(signIn[ClaudeConfigPaths.configDirectoryEnvironmentKey] == real)
        #expect(probe[ClaudeConfigPaths.configDirectoryEnvironmentKey] == real)
    }

    @Test
    func `sign-in preparation creates a private per-account folder and refuses unusable targets`() throws {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let home = fixture.home
        let accountID = UUID()

        let created = try ClaudeAccountConfigDirectory.prepare(
            existing: nil,
            accountID: accountID,
            homeDirectory: home)
        let expected = home.appendingPathComponent(".config/codexbar/claude-accounts/\(accountID.uuidString)").path
        #expect(created == expected)
        let attributes = try fileManager.attributesOfItem(atPath: created)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        // Signing in again reuses the stored folder.
        #expect(try ClaudeAccountConfigDirectory.prepare(existing: created, accountID: accountID, homeDirectory: home)
            == created)
        #expect(try ClaudeAccountConfigDirectory.prepare(
            existing: "  " + created + "/ ",
            accountID: UUID(),
            homeDirectory: home) == created)

        let file = fixture.root.appendingPathComponent("not-a-folder")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ClaudeAccountConfigDirectoryError.notADirectory) {
            try ClaudeAccountConfigDirectory.prepare(existing: file.path, accountID: accountID, homeDirectory: home)
        }
        #expect(throws: ClaudeAccountConfigDirectoryError.invalidPath) {
            try ClaudeAccountConfigDirectory.prepare(existing: "relative", accountID: accountID, homeDirectory: home)
        }
        #expect(throws: ClaudeAccountConfigDirectoryError.defaultClaudeLocation) {
            try ClaudeAccountConfigDirectory.prepare(existing: "~/.claude", accountID: accountID, homeDirectory: home)
        }
        #expect(!fileManager.fileExists(atPath: home.appendingPathComponent(".claude/.claude.json").path))
    }

    @Test
    func `sign-in environment points claude auth login at the account folder only`() throws {
        let fixture = try ClaudeConfigDirectoryFixture()
        defer { fixture.remove() }
        let script = fixture.root.appendingPathComponent("bin/claude-env")
        try """
        #!/bin/sh
        printf 'dir=%s|secure=%s|token=%s|args=%s\\n' \
          "${CLAUDE_CONFIG_DIR-unset}" "${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}" \
          "${CLAUDE_CODE_OAUTH_TOKEN-unset}" "$*"
        printf 'Successfully logged in\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let environment = ClaudeAccountConfigDirectory.scopedEnvironment(
            base: fixture.ambientEnvironment,
            configDirectory: fixture.accountDirectory.path)

        var options = TTYCommandRunner.Options(rows: 50, cols: 160, timeout: 10)
        options.extraArgs = ["auth", "login", "--claudeai"]
        options.baseEnvironment = environment
        options.stopOnSubstrings = ["Successfully logged in"]
        options.returnOnEmptyProcessExit = true
        let result = try TTYCommandRunner().run(binary: script.path, send: "", options: options)

        #expect(result.text.contains("dir=\(fixture.accountDirectory.path)|secure=unset|token=unset"))
        #expect(result.text.contains("args=auth login --claudeai"))
    }

    // MARK: - Helpers

    struct Routed {
        let env: [String: String]
        let settings: ProviderSettingsSnapshot
        let context: ProviderFetchContext
    }

    static func route(
        account: ProviderTokenAccount,
        globalSource: ProviderSourceMode,
        fixture: ClaudeConfigDirectoryFixture,
        runtime: ProviderRuntime) throws -> Routed
    {
        var providerConfig = ProviderConfig(id: .claude)
        providerConfig.source = globalSource
        providerConfig.cookieSource = .manual
        providerConfig.tokenAccounts = ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0)
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: [providerConfig]),
            verbose: false)
        let sourceMode = tokenContext.effectiveSourceMode(base: globalSource, provider: .claude, account: account)
        let settings = try #require(tokenContext.settingsSnapshot(for: .claude, account: account))
        let env = tokenContext.environment(base: fixture.ambientEnvironment, provider: .claude, account: account)
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: account.id)
        return Routed(env: env, settings: settings, context: context)
    }

    final class ProbeCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private var environments: [[String: String]] = []

        var binaries: [String] {
            self.lock.withLock { self.recorded }
        }

        var launchEnvironments: [[String: String]] {
            self.lock.withLock { self.environments }
        }

        func record(_ binary: String) {
            self.lock.withLock { self.recorded.append(binary) }
        }

        func record(_ environment: [String: String]) {
            self.lock.withLock { self.environments.append(environment) }
        }
    }
}

/// A throwaway home with a default Claude Code login that must stay untouched, an account folder, and a stub
/// `claude` executable. Paths are resolved once so assertions compare the spelling CodexBar stores.
struct ClaudeConfigDirectoryFixture {
    let root: URL
    let home: URL
    let accountDirectory: URL
    let claudeExecutable: URL

    init() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-claude-config-dir-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        self.root = base.resolvingSymlinksInPath()
        self.home = self.root.appendingPathComponent("home", isDirectory: true)
        self.accountDirectory = self.root.appendingPathComponent("account", isDirectory: true)
        let bin = self.root.appendingPathComponent("bin", isDirectory: true)
        self.claudeExecutable = bin.appendingPathComponent("claude")
        try fileManager.createDirectory(at: self.home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: self.accountDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: self.claudeExecutable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.claudeExecutable.path)

        let defaultRoot = self.home.appendingPathComponent(".claude", isDirectory: true)
        try fileManager.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-default-login","scopes":["user:profile"]}}"#.write(
            to: defaultRoot.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8)
    }

    var ambientEnvironment: [String: String] {
        [
            "HOME": self.home.path,
            "PATH": "/usr/bin:/bin",
            "CLAUDE_CLI_PATH": self.claudeExecutable.path,
            "CODEXBAR_DISABLE_CLAUDE_WATCHDOG": "1",
            ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey: self.home.path,
            "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-ambient",
            ClaudeOAuthCredentialsStore.environmentTokenKey: "sk-ant-oat01-ambient",
        ]
    }

    func account(token: String = "", directory: String? = nil) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(),
            label: "Browser sign-in",
            token: token,
            addedAt: 0,
            lastUsed: nil,
            claudeConfigDirectory: directory ?? self.accountDirectory.path)
    }

    func writeSignedInAccountConfig() throws {
        try #"{"oauthAccount":{"accountUuid":"00000000-0000-4000-8000-000000000001"}}"#.write(
            to: self.accountDirectory.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }

    static func usageStatusSnapshot() -> ClaudeStatusSnapshot {
        ClaudeStatusSnapshot(
            sessionPercentLeft: 75,
            weeklyPercentLeft: 60,
            opusPercentLeft: nil,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            primaryResetDescription: nil,
            secondaryResetDescription: nil,
            opusResetDescription: nil,
            rawText: "Current session 25% used")
    }
}
