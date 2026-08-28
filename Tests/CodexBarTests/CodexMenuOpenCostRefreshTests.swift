import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexMenuOpenCostRefreshTests {
    @Test
    func `unchanged menu refresh reads summaries while changed logs still scan exactly`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 28)
        let sessionURL = try env.writeCodexSessionFile(
            day: day,
            filename: "menu-refresh.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: day),
                    "payload": ["id": "menu-refresh-session"],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: day),
                    "payload": ["model": "openai/gpt-5.4"],
                ],
                Self.tokenCount(env: env, at: day.addingTimeInterval(1), last: 100, total: 100),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(cold.summary?.totalTokens == 100)

        let recorder = CostUsageStoreReadWorkRecorder(
            databaseURL: CostUsageStore(cacheRoot: env.cacheRoot).databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        options.reuseCodexReportWhenSourcesAreUnchanged = true

        let unchanged = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(unchanged == cold)
        Self.expectSummaryOnly(recorder.snapshot())

        let handle = try FileHandle(forWritingTo: sessionURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            Self.tokenCount(env: env, at: day.addingTimeInterval(3), last: 20, total: 120),
        ]).utf8))
        try handle.synchronize()

        recorder.reset()
        let changed = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: options)
        #expect(changed.summary?.totalTokens == 120)
        let changedWork = recorder.snapshot()
        #expect(changedWork.fullSnapshotReads == 1)
        #expect(changedWork.tokenSnapshotRows > 0)
        #expect(changedWork.usageRows > 0)

        recorder.reset()
        let settled = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(5),
            options: options)
        #expect(settled == changed)
        Self.expectSummaryOnly(recorder.snapshot())
    }

    @Test
    func `low power menu refresh compacts a wider dashboard cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let olderDay = try env.makeLocalNoon(year: 2026, month: 6, day: 1)
        let recentDay = try env.makeLocalNoon(year: 2026, month: 8, day: 28)
        _ = try env.writeCodexSessionFile(
            day: olderDay,
            filename: "older-dashboard.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: olderDay),
                    "payload": ["id": "older-dashboard-session"],
                ],
                Self.tokenCount(env: env, at: olderDay, last: 75, total: 75),
            ]))
        _ = try env.writeCodexSessionFile(
            day: recentDay,
            filename: "recent-menu.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: recentDay),
                    "payload": ["id": "recent-menu-session"],
                ],
                Self.tokenCount(env: env, at: recentDay, last: 25, total: 25),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let wide = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: recentDay,
            now: recentDay,
            options: options)
        #expect(wide.summary?.totalTokens == 100)

        options.reuseCodexReportWhenSourcesAreUnchanged = true
        options.retainWiderCodexCacheWindow = false
        let compacted = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: recentDay,
            until: recentDay,
            now: recentDay.addingTimeInterval(1),
            options: options)
        #expect(compacted.summary?.totalTokens == 25)

        let view = CostUsageStoreAccess.readView(
            cacheRoot: env.cacheRoot,
            calendar: options.calendar,
            purpose: .summary)
        let expectedRange = CostUsageScanner.CostUsageDayRange(
            since: recentDay,
            until: recentDay,
            calendar: options.calendar)
        #expect(view.scanSinceKey == expectedRange.scanSinceKey)
        #expect(view.scanUntilKey == expectedRange.scanUntilKey)
        #expect(view.days.keys.sorted() == ["2026-08-28"])
    }

    private static func tokenCount(
        env: CostUsageTestEnvironment,
        at date: Date,
        last: Int,
        total: Int) -> [String: Any]
    {
        [
            "type": "event_msg",
            "timestamp": env.isoString(for: date),
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": last,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                    "total_token_usage": [
                        "input_tokens": total,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                ],
            ],
        ]
    }

    private static func expectSummaryOnly(_ work: CostUsageStoreReadWorkMetrics) {
        #expect(work.fullSnapshotReads == 0)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.usageRows == 0)
        #expect(work.usagePayloadBytes == 0)
        #expect(work.accumulatorRows == 0)
        #expect(work.readViewConversions == 1)
    }
}
