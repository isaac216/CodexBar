import CodexBarCore
import Testing

/// Claude Code 2.1.310 opens `/usage` with a "Session" cost block and lists "sessions on this machine only"
/// under the usage insights. Neither is the "Current session" quota label, so a weekly-only plan
/// (verified Ultra) must not fall back to scraping the weekly percent into the session slot.
struct ClaudeWeeklyOnlyPanelLinuxTests {
    private static let costBlock = """
    Settings:  Status   Config   Usage   Stats
    Session
    Total cost:            $0.0000
    Total duration (API):  0s
    Total duration (wall): 8s
    Total code changes:    0 lines added, 0 lines removed
    Usage:                 0 input, 0 output, 0 cache read, 0 cache write
    """

    /// Quota rows end before the insights report; rows after its header belong to the report.
    private static let fableAndInsights = """
    Current week (Fable)
                                                       0% used
    Resets Nov 9 at 9am (America/New_York)
    What's contributing to your limits usage?
    Approximate · sessions on this machine only
    Scanning local sessions…
    Usage credits
    Usage credits are off · /usage-credits to turn them on
    """

    @Test
    func `weekly only panel with session cost block has no session window`() throws {
        let sample = Self.costBlock + "\n" + """
        Current week (all models)
        █████████████████████████████████████████████████▌ 99% used
        Resets Nov 9 at 9am (America/New_York)
        """ + "\n" + Self.fableAndInsights + "\n" + """
        You've used 99% of your weekly limit · resets Nov 9 at 9am (America/New_York)
        """

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.sessionPercentLeft == nil)
        #expect(snap.primaryResetDescription == nil)
        #expect(snap.weeklyPercentLeft == 1)
        let fable = try #require(snap.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable.window.usedPercent == 0)
    }

    @Test
    func `session panel with session cost block keeps the session window`() throws {
        let sample = Self.costBlock + "\n" + """
        Current session
        █▌ 3% used
        Resets 3:50am (America/New_York)
        Current week (all models)
        ▌ 1% used
        Resets Nov 9 at 9am (America/New_York)
        """ + "\n" + Self.fableAndInsights

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.sessionPercentLeft == 97)
        #expect(snap.primaryResetDescription == "Resets 3:50am (America/New_York)")
        #expect(snap.weeklyPercentLeft == 99)
    }

    @Test
    func `garbled session label with session cost block still scrapes the session percent`() throws {
        let sample = Self.costBlock + "\n" + """
        Curretsession
        ███████▌15%used
        Resets 11:30pm (America/New_York)
        Current week (all models)
        █▌ 3% used
        Resets Nov 9 at 9am (America/New_York)
        """ + "\n" + Self.fableAndInsights

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.sessionPercentLeft == 85)
        #expect(snap.weeklyPercentLeft == 97)
    }
}
