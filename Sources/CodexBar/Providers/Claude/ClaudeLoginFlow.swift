import CodexBarCore
import Foundation

typealias ClaudeLoginFlowRunner = (
    _ timeout: TimeInterval,
    _ environment: [String: String]?,
    _ onPhaseChange: @escaping @Sendable (ClaudeLoginRunner.Phase) -> Void) async -> ClaudeLoginRunner.Result

@MainActor
extension StatusItemController {
    /// - Parameter configDirectory: A Claude token account's own config directory. Nil keeps the ambient
    ///   `claude auth login` used by the menu's sign-in and account-switch actions, which passes no
    ///   `CLAUDE_CONFIG_DIR`.
    func runClaudeLoginFlow(configDirectory: String? = nil) async -> Bool {
        await self.runClaudeLoginFlow(
            configDirectory: configDirectory,
            loginRunner: { timeout, environment, onPhaseChange in
                await ClaudeLoginRunner.run(timeout: timeout, environment: environment, onPhaseChange: onPhaseChange)
            })
    }

    func runClaudeLoginFlow(configDirectory: String? = nil, loginRunner: ClaudeLoginFlowRunner) async -> Bool {
        let environment = configDirectory.map { ClaudeLoginRunner.environment(configDirectory: $0) }
        let phaseHandler: @Sendable (ClaudeLoginRunner.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .requesting: self?.loginPhase = .requesting
                case .waitingBrowser: self?.loginPhase = .waitingBrowser
                }
            }
        }
        let result = await loginRunner(120, environment, phaseHandler)
        guard !Task.isCancelled else { return false }
        self.loginPhase = .idle
        self.presentClaudeLoginResult(result)
        let outcome = self.describe(result.outcome)
        let length = result.output.count
        self.loginLogger.info("Claude login", metadata: [
            "outcome": outcome,
            "length": "\(length)",
            "scope": configDirectory == nil ? "ambient" : "accountConfigDirectory",
        ])
        if case .success = result.outcome {
            let metadata = self.store.metadata(for: .claude)
            self.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
            self.postLoginNotification(for: .claude)
            return true
        }
        return false
    }

    /// Settings → Providers → Claude → Sign in with Browser… for one token account. Creates the account's own
    /// config directory when it has none, then signs in with `CLAUDE_CONFIG_DIR` set to that folder.
    func runClaudeAccountLoginFlowFromSettings(accountID: UUID) async {
        guard self.loginTask == nil else {
            self.loginLogger.info("Claude account sign-in ignored: login already in-flight")
            return
        }
        self.loginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeLoginProvider = nil
                self.loginTask = nil
            }
            let directory: String
            do {
                directory = try self.settings.prepareClaudeAccountConfigDirectory(accountID: accountID)
            } catch {
                self.presentLoginAlert(
                    title: L("Could not prepare the Claude account folder"),
                    message: L(error.localizedDescription))
                return
            }
            self.activeLoginProvider = .claude
            self.loginPhase = .requesting
            guard await self.runClaudeLoginFlow(configDirectory: directory) else { return }
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refreshProvider(.claude, allowDisabled: true)
            }
        }
        await self.loginTask?.value
    }
}
