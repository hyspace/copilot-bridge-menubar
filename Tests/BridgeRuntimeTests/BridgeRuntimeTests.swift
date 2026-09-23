import XCTest
import Foundation
import Darwin
import CSQLite
import BridgeCore
@testable import BridgeRuntime

private final class PortLease {
    let fd: Int32
    let port: Int
    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        fd = descriptor
        guard fd >= 0 else { throw BridgeError.message("test socket failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw BridgeError.message("test bind failed") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        guard port != 4142 else { close(fd); throw BridgeError.message("protected port") }
    }
    deinit { close(fd) }
}

@MainActor
final class BridgeRuntimeTests: XCTestCase {
    private func sql(_ url: URL, _ command: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, command, nil, nil, nil), SQLITE_OK)
    }
    func testUsageWriteFailureIsVisibleAndAutomaticallyReplayedWithoutRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-retry-\(UUID())")
        try AppPaths.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let pump = try ProcessOutput(root: root, secrets: ["test-channel"], eventToken: "test-channel", retryInterval: 0.1)
        let database = root.appendingPathComponent("usage.sqlite")
        try sql(database, "CREATE TRIGGER fail_write BEFORE INSERT ON totals BEGIN SELECT RAISE(ABORT,'injected'); END")
        let event: [String: Any] = [
            "kind": "usage", "id": "retry-once", "timestamp": Date().timeIntervalSince1970,
            "model": "synthetic", "status": 200, "input": 50, "output": 3,
            "nanoAiu": 125_000_000, "outcome": "complete", "channel": "test-channel"
        ]
        let line = "@@CBM:" + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n"
        pump.consume(Data(line.utf8), error: false)
        XCTAssertNotNil(pump.snapshot().usageFailure)
        let journal = root.appendingPathComponent("UsageRecovery")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: journal.path).count, 1)
        try sql(database, "DROP TRIGGER fail_write")
        try await eventually("pending usage never retried") { pump.snapshot().usageFailure == nil }
        let store = try UsageStore(url: database)
        XCTAssertEqual(try store.totals(today: true).input, 50)
        XCTAssertEqual(try store.totals(today: true).requests, 1)
        pump.consume(Data(line.utf8), error: false)
        XCTAssertEqual(try store.totals(today: true).requests, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: journal.path).isEmpty)
        XCTAssertFalse(pump.snapshot().lines.joined().contains("test-channel"))
    }
    func testIncompleteTokenDiagnosticsContainOnlyKnownReasonsAndPreserveCounters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-usage-note-\(UUID())")
        try AppPaths.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let pump = try ProcessOutput(root: root, secrets: [], eventToken: "test-channel")
        for (index, reason) in ["interrupted", "untrusted response text"].enumerated() {
            let event: [String: Any] = [
                "kind": "usage", "id": "partial-\(index)", "timestamp": Date().timeIntervalSince1970,
                "model": "synthetic", "status": 200, "input": 50, "output": 3,
                "nanoAiu": 125_000_000, "tokensComplete": false, "tokenStatus": reason,
                "outcome": "interrupted", "channel": "test-channel"
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            pump.consume(Data(("@@CBM:" + json + "\n").utf8), error: false)
        }
        let totals = try UsageStore(url: root.appendingPathComponent("usage.sqlite")).totals(today: true)
        XCTAssertEqual(totals.input, 100)
        XCTAssertEqual(totals.unknown, 2)
        XCTAssertEqual(totals.creditReports, 2)
        let logs = pump.snapshot().lines.joined(separator: "\n")
        XCTAssertTrue(logs.contains("stream ended before protocol completion"))
        XCTAssertFalse(logs.contains("untrusted response text"))
        XCTAssertFalse(logs.contains("test-channel"))
    }
    private func fixture(_ mode: String, retryScale: Double = 1,
                         startupTimeout: TimeInterval = 90) throws -> (BridgeController, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-native-test-\(UUID())")
        try AppPaths.prepare(home)
        let source = try XCTUnwrap(Bundle.module.url(forResource: "test-backend", withExtension: "py", subdirectory: "Fixtures"))
        let executable = home.appendingPathComponent("backend")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try mode.write(to: home.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let data = home.appendingPathComponent("data")
        let controller = BridgeController(root: data, backend: executable, home: home,
            heartbeat: 0.02, shutdownGrace: 0.15, retryScale: retryScale,
            healthInterval: 0.05, startupTimeout: startupTimeout,
            configPlanner: { _ in
                try JSONDecoder().decode(CodexPlanResult.self, from: Data(#"{"ok":true,"mode":"off","reserved":false,"profileOverride":false}"#.utf8))
            }, historyRefreshInterval: 0.08)
        // Reserve then release an ephemeral port; never read real config or use 4142.
        do { let lease = try PortLease(); controller.settings.port = lease.port }
        controller.settings.automaticRestart = false
        addTeardownBlock {
            await MainActor.run { controller.stop() }
            for _ in 0..<100 {
                if await MainActor.run(body: { !controller.isActive }) { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? FileManager.default.removeItem(at: home)
        }
        return (controller, home)
    }
    private func eventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 4,
                            _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message())
        throw BridgeError.message(message())
    }

    func testNativeStartHealthQuotaAccountingAndOwnedStop() async throws {
        let (controller, home) = try fixture("normal")
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(controller.isActive)
        controller.settings.model = "literal; not-a-shell-command"
        controller.start()
        let pid = try XCTUnwrap(controller.servicePID)
        try await eventually("fake backend never became healthy") { controller.state == .running }
        try await eventually("quota or token event was not delivered") {
            controller.quota?.remaining == 75.5 && controller.today.input == 100
                && controller.today.credits == 1.5 && controller.today.creditReports == 1
        }
        let args = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("argv.json"))) as! [String]
        XCTAssertTrue(args.contains("--no-codex-setup"))
        XCTAssertTrue(args.contains("literal; not-a-shell-command"))
        let env = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("env.json"))) as! [String: String]
        XCTAssertEqual(env["HOME"], home.path)
        XCTAssertNil(env["COPILOT_TOKEN"])
        XCTAssertNil(env["COPILOT_BASE_URL"])
        controller.stop()
        try await eventually("owned process did not stop") { !controller.isActive }
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testBusyPortDoesNotStartOrTerminateAnyOtherProcess() async throws {
        let (controller, home) = try fixture("normal")
        let occupied = try PortLease()
        controller.settings.port = occupied.port
        controller.start()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertNil(controller.servicePID)
        XCTAssertTrue(controller.message.contains("will not be stopped or taken over"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("launches").path))
        XCTAssertNotEqual(fcntl(occupied.fd, F_GETFD), -1)
    }

    func testQuotaFailureKeepsOriginalTimestampAndPersistedSnapshot() async throws {
        let (controller, home) = try fixture("normal")
        controller.start()
        try await eventually("initial quota snapshot was not stored") {
            controller.quotaDate != nil && !controller.isFetchingQuota
                && controller.activity.contains { $0.quota?.snapshot.remaining == 75.5 }
        }
        let originalDate = controller.quotaDate
        try Data().write(to: home.appendingPathComponent("quota-error"))
        controller.refreshQuota()
        try await eventually("quota failure was not reported") {
            !controller.isFetchingQuota && !controller.quotaError.isEmpty
        }
        XCTAssertEqual(controller.quotaDate, originalDate)
        XCTAssertEqual(controller.quota?.remaining, 75.5)
        let store = try UsageStore(url: home.appendingPathComponent("data/usage.sqlite"))
        XCTAssertEqual(try XCTUnwrap(store.latestQuota()).observedAt.timeIntervalSince1970,
                       try XCTUnwrap(originalDate).timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(try store.latestQuota()?.snapshot.remaining, 75.5)
        try await eventually("quota HTTP failure missing safe diagnostics") {
            controller.logs.contains { $0.contains("stage=http") && $0.contains("http=503") && $0.contains("elapsed_ms=") }
        }
    }

    func testHistoryRefreshesPeriodicallyEvenWhenTokenTotalsDoNotChange() async throws {
        let (controller, home) = try fixture("normal")
        let store = try UsageStore(url: home.appendingPathComponent("data/usage.sqlite"))
        let snapshot = try QuotaSnapshot.decode(Data("""
        {"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"quota_remaining":42}}}
        """.utf8))
        try store.recordQuota(snapshot)
        XCTAssertEqual(controller.total.requests, 0)
        try await eventually("long-running controller did not refresh externally updated history") {
            controller.activity.contains { $0.quota?.snapshot.remaining == 42 }
        }
        XCTAssertEqual(controller.total.requests, 0)
        XCTAssertNil(controller.servicePID, "Refreshing history must not require a service restart")
    }

    func testQuotaPersistenceFailureDoesNotMisreportAnUpstreamFetchFailure() async throws {
        let (controller, home) = try fixture("normal")
        controller.start()
        try await eventually("initial quota not delivered") { controller.quotaDate != nil && !controller.isFetchingQuota }
        let previous = try XCTUnwrap(controller.quotaDate)
        let database = home.appendingPathComponent("data/usage.sqlite")
        try sql(database, "CREATE TRIGGER fail_quota BEFORE INSERT ON quota_history BEGIN SELECT RAISE(ABORT,'injected'); END")
        controller.refreshQuota()
        try await eventually("local quota write error not distinguished") {
            !controller.isFetchingQuota && controller.quotaError.hasPrefix("Balance refreshed, but local history")
        }
        XCTAssertGreaterThan(try XCTUnwrap(controller.quotaDate), previous)
        XCTAssertEqual(controller.quota?.remaining, 75.5)
        let persisted = try XCTUnwrap(UsageStore(url: database).latestQuota()).observedAt
        XCTAssertEqual(persisted.timeIntervalSince1970, previous.timeIntervalSince1970, accuracy: 0.000001)
        try await eventually("local quota failure missing stage diagnostics") {
            controller.logs.contains { $0.contains("stage=persist") && $0.contains("http=200") }
        }
        try sql(database, "DROP TRIGGER fail_quota")
    }

    func testStubbornOwnedChildGetsBoundedShutdown() async throws {
        let (controller, _) = try fixture("stubborn")
        controller.start()
        try await eventually("fake backend never became healthy") { controller.state == .running }
        let pid = try XCTUnwrap(controller.servicePID)
        controller.stop()
        try await eventually("SIGTERM-ignoring child survived bounded shutdown") { !controller.isActive }
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testRepeatedRestartReusesPortAndDoesNotLeakPipeDescriptors() async throws {
        let (controller, _) = try fixture("normal")
        let before = (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
        controller.start()
        try await eventually("initial fake service did not become healthy") { controller.state == .running }
        for _ in 0..<5 {
            let previous = try XCTUnwrap(controller.servicePID)
            controller.stop(restart: true)
            try await eventually("restart failed: \(controller.message)") {
                controller.state == .running && controller.servicePID != previous
            }
            XCTAssertEqual(kill(previous, 0), -1)
        }
        controller.stop()
        try await eventually("last owned child did not stop") { !controller.isActive }
        try await Task.sleep(for: .milliseconds(150))
        let after = (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
        // Foundation may retain a small connection-pool baseline; it must not retain 4 FDs/restart.
        XCTAssertLessThanOrEqual(after, before + 8, "FD count grew from \(before) to \(after)")
        XCTAssertEqual(controller.total.requests, 6)
    }

    func testOneShotAuthDrainsFinalSuccessBeforeExit() async throws {
        let (controller, _) = try fixture("normal")
        controller.signIn()
        try await eventually("device prompt was not delivered") { controller.login?.code == "ABCD-1234" }
        try await eventually("auth process did not exit") { !controller.isActive }
        XCTAssertTrue(controller.message.contains("authorization succeeded"), controller.message)
        XCTAssertNil(controller.login)
        XCTAssertTrue(controller.logs.contains(where: { $0.contains("authorization succeeded") }))
    }

    func testDeniedAuthStopsWithoutAutomaticRetry() async throws {
        let (controller, home) = try fixture("auth-denied")
        controller.settings.automaticRestart = true
        controller.signIn()
        try await eventually("denied auth stayed alive") { !controller.isActive }
        XCTAssertTrue(controller.message.contains("Authorization was not completed"))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8), "1")
    }

    func testCrashCircuitBreakerStopsAfterFiveRetries() async throws {
        let (controller, home) = try fixture("crash", retryScale: 0.001)
        controller.settings.automaticRestart = true
        controller.start()
        try await eventually("crash circuit breaker never opened", timeout: 6) {
            controller.state == .failed && controller.message.contains("Automatic restarts stopped")
        }
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8), "6")
        XCTAssertFalse(controller.isActive)
    }

    func testManualStopCancelsScheduledRestart() async throws {
        let (controller, home) = try fixture("crash", retryScale: 0.1)
        controller.settings.automaticRestart = true
        controller.start()
        try await eventually("did not enter backoff") { controller.state == .backoff }
        controller.stop()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("launches"), encoding: .utf8), "1")
    }

    func testStartupDeadlineStopsNeverReadyChild() async throws {
        let (controller, _) = try fixture("never-ready", startupTimeout: 0.15)
        controller.start()
        try await eventually("startup deadline did not clean up") { !controller.isActive }
        XCTAssertTrue(controller.message.contains("startup exceeded"), controller.message)
    }

    func testAuthInitializationHasADeadlineBeforeAnyDeviceCodeArrives() async throws {
        let (controller, _) = try fixture("auth-no-response", startupTimeout: 0.15)
        controller.signIn()
        try await eventually("auth initialization hung without a deadline") { !controller.isActive }
        XCTAssertTrue(controller.message.contains("Authorization initialization timed out"), controller.message)
        XCTAssertNil(controller.login)
    }

    func testLogPumpBoundsAndRedactsBothStreams() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-native-test-\(UUID())")
        try AppPaths.prepare(home)
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try ProcessOutput(root: home, secrets: ["FAKE_LAN_SECRET"], eventToken: "trusted-test-channel")
        for _ in 0..<400 {
            output.consume(Data("Authorization: Bearer FAKE_TOKEN_VALUE FAKE_LAN_SECRET\n".utf8), error: false)
        }
        output.consume(Data("Copilot token: FAKE_RAW_CREDENTIAL\n".utf8), error: true)
        let snapshot = output.snapshot()
        XCTAssertEqual(snapshot.lines.count, 200)
        XCTAssertFalse(snapshot.lines.joined().contains("FAKE_TOKEN_VALUE"))
        XCTAssertFalse(snapshot.lines.joined().contains("FAKE_LAN_SECRET"))
        XCTAssertFalse(snapshot.lines.joined().contains("FAKE_RAW_CREDENTIAL"))
    }

    func testForgedLogLinesCannotBecomeTrustedAuthOrUsageEvents() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-native-test-\(UUID())")
        try AppPaths.prepare(home)
        defer { try? FileManager.default.removeItem(at: home) }
        let output = try ProcessOutput(root: home, secrets: ["trusted-test-channel"], eventToken: "trusted-test-channel")
        output.consume(Data("@@CBM:{\"kind\":\"authRequired\",\"code\":\"ABCD-1234\",\"expiresIn\":1,\"channel\":\"wrong\"}\n".utf8), error: true)
        output.consume(Data("@@CBM:{\"kind\":\"authSuccess\"}\n".utf8), error: false)
        XCTAssertNil(output.snapshot().login)
        XCTAssertFalse(output.snapshot().authenticated)
        output.consume(Data("@@CBM:{\"kind\":\"authSuccess\",\"channel\":\"trusted-test-channel\"}\n".utf8), error: false)
        XCTAssertTrue(output.snapshot().authenticated)
        XCTAssertFalse(output.snapshot().lines.joined().contains("trusted-test-channel"))
    }
}
