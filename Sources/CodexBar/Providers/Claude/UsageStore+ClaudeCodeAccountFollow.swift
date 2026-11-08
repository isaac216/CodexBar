import CodexBarCore

extension UsageStore {
    /// Selects the Claude token account whose folder is signed in to the account Claude Code itself uses, when Claude
    /// Code switched accounts since the last check (`/login`, Switch Account). A manual pick in Settings stays until
    /// the next switch; after launch the first check follows Claude Code. Runs from `prepareRefreshState`, before a
    /// refresh captures its configuration revision, so the new selection cannot invalidate that refresh.
    func followClaudeCodeActiveAccountIfChanged(refreshing provider: UsageProvider?) {
        guard provider == nil || provider == .claude,
              let data = self.settings.tokenAccountsData(for: .claude),
              data.accounts.count > 1
        else { return }
        let environment = self.environmentBase
        let decision = ClaudeCodeActiveAccountFollow.decide(
            claudeCodeAccountUuid: ClaudeCodeActiveAccountFollow.claudeCodeAccountUuid(environment: environment),
            lastHandledAccountUuid: self.claudeCodeFollowedAccountUuid,
            tokenAccountUuids: {
                data.accounts.map {
                    ClaudeCodeActiveAccountFollow.tokenAccountUuid(
                        configDirectory: $0.claudeConfigDirectory,
                        environment: environment)
                }
            },
            activeIndex: data.clampedActiveIndex())
        if let handled = decision.handledAccountUuid {
            self.claudeCodeFollowedAccountUuid = handled
        }
        guard let index = decision.indexToSelect else { return }
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Selecting the Claude token account Claude Code is signed in to",
            metadata: ["index": "\(index)"])
        self.settings.setActiveTokenAccountIndex(index, for: .claude)
    }
}
