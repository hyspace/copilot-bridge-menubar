import XCTest
@testable import BridgeCore

final class BridgeCoreTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try AppPaths.prepare(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testDefaultArgumentsNeverRewriteConsumerConfiguration() {
        let args = BridgeSettings().arguments()
        XCTAssertEqual(args, ["start", "--host", "127.0.0.1", "--port", "4142",
                              "--no-codex-setup", "--no-claude-setup", "--no-prompt"])
        XCTAssertFalse(args.contains("--show-token"))
    }
    func testEverySupportedRuntimeFlagIsPassedWithoutShellInterpolation() {
        var settings = BridgeSettings()
        settings.scope = .lan; settings.port = 51420; settings.model = "a; touch /tmp/nope"
        settings.debug = true; settings.autoMode = true; settings.waitForRateLimit = true; settings.rateLimitSeconds = 4
        let args = settings.arguments()
        XCTAssertTrue(args.contains("a; touch /tmp/nope"))
        for flag in ["--debug", "--auto", "--wait", "--rate-limit"] { XCTAssertTrue(args.contains(flag)) }
        XCTAssertEqual(args[2], "0.0.0.0")
        XCTAssertEqual(settings.arguments(authOnly: true), ["auth", "--host", "127.0.0.1", "--port", "51420"])
    }
    func testEnvironmentClearsCredentialsAndLoadersButPreservesProxy() {
        let source = ["COPILOT_TOKEN":"secret", "COPILOT_BASE_URL":"https://wrong.test", "BUN_OPTIONS":"evil",
                      "NODE_OPTIONS":"evil", "COPILOT_BRIDGE_TRACE_REQUESTS_FILE":"/tmp/prompt",
                      "HTTPS_PROXY":"http://127.0.0.1:7890"]
        let env = BridgeSettings().environment(inheriting: source, home: "/tmp/test", parentPID: 123, instance: "one")
        for key in ["COPILOT_TOKEN","COPILOT_BASE_URL","BUN_OPTIONS","NODE_OPTIONS","COPILOT_BRIDGE_TRACE_REQUESTS_FILE"] { XCTAssertNil(env[key]) }
        XCTAssertEqual(env["HTTPS_PROXY"],source["HTTPS_PROXY"])
        XCTAssertEqual(env["HOME"],"/tmp/test"); XCTAssertEqual(env["CBM_PARENT_PID"],"123")
    }
    func testValidationDoesNotAllowInvalidPortOrEmbeddedSecrets() throws {
        var settings = BridgeSettings()
        for port in [-1, 0, 80, 65536] { settings.port = port; XCTAssertThrowsError(try settings.validated()) }
        settings.port = 4142; settings.proxyURL = "http://user:password@localhost:8080"
        XCTAssertThrowsError(try settings.validated())
        settings.proxyURL = ""; settings.upstreamURL = "http://insecure.test"
        XCTAssertThrowsError(try settings.validated())
        settings.upstreamURL = "https://api.githubcopilot.com"; XCTAssertNoThrow(try settings.validated())
    }
    func testLANRemainsKeylessAndLegacyReferenceSettingsAreIgnored() throws {
        let settings = BridgeSettings()
        let environment = settings.environment(inheriting: ["COPILOT_BRIDGE_ACCESS_KEY":"old"],
            home:"/tmp/test",parentPID:123,instance:"one")
        XCTAssertNil(environment["COPILOT_BRIDGE_ACCESS_KEY"])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy["referenceRequiresOpenAIAuth"] = true
        legacy["referenceReasoningSummaries"] = true
        let decoded = try JSONDecoder().decode(BridgeSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded, settings)
    }
    func testSettingsPersistAtomicallyWithPrivatePermissions() throws {
        let root = try temporaryDirectory()
        var settings = BridgeSettings(); settings.model = "gpt-6-astra"
        try AppPaths.saveSettings(settings, root: root)
        XCTAssertEqual(try AppPaths.loadSettings(root: root),settings)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("settings.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode,0o600)
    }
    func testUsageIsDeduplicatedAndUnknownTokensStayVisible() throws {
        let root = try temporaryDirectory()
        let store = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
        let event = UsageEvent(kind:"usage",id:"one",timestamp:Date().timeIntervalSince1970,
                               model:"gpt",status:200,input:100,output:20,cached:40,outcome:"complete")
        try store.record(event); try store.record(event)
        try store.record(UsageEvent(kind:"usage",id:"two",timestamp:Date().timeIntervalSince1970,
                                   model:"gpt",status:413,input:nil,output:nil,cached:nil,outcome:"http_error"))
        let total = try store.totals(today:true)
        XCTAssertEqual(total.input,100); XCTAssertEqual(total.output,20); XCTAssertEqual(total.cached,40)
        XCTAssertEqual(total.requests,2); XCTAssertEqual(total.errors,1); XCTAssertEqual(total.unknown,1)
    }
    func testQuotaRecognizesActualTokenBillingSchemaWithoutRoundingAwayCreditFractions() throws {
        let data = Data(#"{"token_based_billing":true,"copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"quota_remaining":7500.5,"remaining":7500,"entitlement":10000,"credits_used":2499,"percent_remaining":75.0,"unlimited":false}}}"#.utf8)
        let quota = try QuotaSnapshot.decode(data)
        XCTAssertEqual(quota.title,"GitHub credits")
        XCTAssertEqual(quota.remaining,7500.5); XCTAssertEqual(quota.creditsUsed,2499)
        XCTAssertThrowsError(try QuotaSnapshot.decode(Data("{}".utf8)))
    }
    func testRedactorRemovesSecretsAndLogLineLengthIsBounded() {
        let text = Redactor.clean("Bearer abcdefghijk ghp_supersecrettoken X-Bridge-Key: secret access secret",secrets:["secret"])
        XCTAssertFalse(text.contains("abcdefghijk")); XCTAssertFalse(text.contains("ghp_super"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertEqual(Redactor.clean(String(repeating:"x",count:100000)).count,8192)
    }
    func testFramerHandlesSplitUTF8AndCapsLongLines() {
        var framer=LineFramer()
        let data=Data("你好\n".utf8)
        XCTAssertTrue(framer.append(data.prefix(2)).isEmpty)
        XCTAssertEqual(framer.append(data.dropFirst(2)),["你好"])
        let lines=framer.append(Data((String(repeating:"x",count:100000)+"\n").utf8))
        XCTAssertEqual(lines[0].count,65536); XCTAssertEqual(framer.droppedBytes,34464)
    }
    func testLogsRotateWithoutGrowingUnbounded() throws {
        let root=try temporaryDirectory()
        let log=try RotatingLog(root:root,maxBytes:100)
        for _ in 0..<30 { try log.append(String(repeating:"x",count:60)) }
        let logs=try FileManager.default.contentsOfDirectory(atPath:root.path).filter{$0.hasSuffix(".log")}
        XCTAssertEqual(logs.count,4)
    }
    func testRestartCircuitBreakerAndCooldown() {
        var policy=RestartPolicy(); let now=Date()
        XCTAssertEqual((0..<5).compactMap{_ in policy.nextDelay(now:now)},[2,4,8,16,32])
        XCTAssertNil(policy.nextDelay(now:now))
        XCTAssertEqual(policy.nextDelay(now:now.addingTimeInterval(601)),2)
    }
}
