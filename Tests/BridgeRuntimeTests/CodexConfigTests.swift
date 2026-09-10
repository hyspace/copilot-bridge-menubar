import XCTest
import Foundation
import Darwin
@testable import BridgeCore
@testable import BridgeRuntime

final class CodexConfigTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let data: URL
        let manager: CodexConfigManager
        let planner: CodexConfigPlanner
        var config: URL { manager.configURL }
        func reopened() -> CodexConfigManager {
            CodexConfigManager(home: home, dataRoot: data, planner: planner.plan)
        }
    }
    private func fixture(_ text: String? = "model = \"original\"\nmodel_provider = \"openai\"\n") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-config-test-\(UUID())")
        try AppPaths.prepare(root)
        let home = root.appendingPathComponent("codex"), data = root.appendingPathComponent("app")
        try AppPaths.prepare(home); try AppPaths.prepare(data)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let planner: CodexConfigPlanner
        if let path = ProcessInfo.processInfo.environment["CBM_CONFIG_TEST_BINARY"] {
            let binary = URL(fileURLWithPath: path).standardizedFileURL
            guard binary.path.hasPrefix(repository.appendingPathComponent("build").path + "/") else {
                throw BridgeError.message("Config tests may only execute this checkout's build artifacts.")
            }
            planner = CodexConfigPlanner(executable: binary, home: root)
        } else {
            let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
                + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin").path]
            let bun = try XCTUnwrap(paths.map { URL(fileURLWithPath: $0).appendingPathComponent("bun") }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }, "Bun is required by this project's tests")
            planner = CodexConfigPlanner(executable: bun, home: root,
                arguments: [repository.appendingPathComponent("backend/config-plan-test-entry.ts").path])
        }
        let manager = CodexConfigManager(home: home, dataRoot: data, planner: planner.plan)
        if let text { try Data(text.utf8).write(to: manager.configURL); chmod(manager.configURL.path, 0o600) }
        addTeardownBlock { manager.checkpoint = nil; try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, home: home, data: data, manager: manager, planner: planner)
    }
    private func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func generations(_ fixture: Fixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixture.manager.backupsURL, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }
    private func active(_ fixture: Fixture) throws -> URL {
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixture.manager.backupsURL.appendingPathComponent("state.json"))) as? [String: Any])
        return fixture.manager.backupsURL.appendingPathComponent(try XCTUnwrap(state["active"] as? String))
    }

    func testExactBackupRoundTripPreservesPermissionsAndNeverTouchesAuth() throws {
        let original = "# keep\r\nmodel = \"original\"\r\nmodel_provider = 'custom' # original comment\r\n"
        let f = try fixture(original)
        chmod(f.config.path, 0o640)
        let auth = f.home.appendingPathComponent("auth.json")
        try Data("PRIVATE_AUTH_CANARY".utf8).write(to: auth)
        XCTAssertFalse(f.manager.status(port: 4142).enabled)
        try f.manager.setEnabled(true, port: 4142)
        XCTAssertTrue(f.reopened().status(port: 4142).enabled)
        XCTAssertTrue(try contents(f.config).contains("requires_openai_auth = true"))
        XCTAssertTrue(try contents(f.config).contains("supports_websockets = false"))
        let first = try active(f)
        XCTAssertEqual(try contents(first.appendingPathComponent("before.toml")), original)
        for name in ["before.toml", "after.toml", "manifest.json"] {
            let mode = try FileManager.default.attributesOfItem(atPath: first.appendingPathComponent(name).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
        }
        try f.manager.setEnabled(true, port: 4142)
        XCTAssertEqual(try generations(f).count, 1, "Repeated enable must not replace the restore point")
        try f.reopened().setEnabled(false, port: 4142)
        XCTAssertEqual(try contents(f.config), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.config.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try contents(auth), "PRIVATE_AUTH_CANARY")
        try f.manager.setEnabled(false, port: 4142)
        XCTAssertEqual(try generations(f).count, 2)
    }
    func testAbsentConfigIsRemovedOnRestoreButAnOriginallyEmptyFileRemains() throws {
        for initial in [nil, ""] as [String?] {
            let f = try fixture(initial)
            XCTAssertTrue(f.manager.status(port: 4142).canChange)
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.config.path), initial != nil)
            try f.manager.setEnabled(true, port: 4142)
            try f.reopened().setEnabled(false, port: 4142)
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.config.path), initial != nil)
            if initial != nil { XCTAssertEqual(try contents(f.config), "") }
        }
    }
    func testUnrelatedEditsAndNewSettingsSurviveRestore() throws {
        let f = try fixture()
        try f.manager.setEnabled(true, port: 4142)
        let edited = try contents(f.config).replacingOccurrences(of: "\"original\"", with: "\"user-selected\"")
            + "\n[projects.\"/new/project\"]\ntrust_level = \"trusted\"\n"
        try Data(edited.utf8).write(to: f.config)
        try f.reopened().setEnabled(false, port: 4142)
        let restored = try contents(f.config)
        XCTAssertTrue(restored.contains("user-selected"))
        XCTAssertTrue(restored.contains("/new/project"))
        XCTAssertTrue(restored.contains("model_provider = \"openai\""))
        XCTAssertFalse(restored.contains("copilot_bridge_app"))
    }
    func testQualifiedModelRestoresFromVerifiedBaselineWithoutLosingOtherEdits() throws {
        for model in ["local/org/model", "codex/official-model", "copilot/another-model"] {
            let f = try fixture()
            try f.manager.setEnabled(true, port: 4142)
            let edited = try contents(f.config).replacingOccurrences(of: "\"original\"", with: "\"\(model)\"")
                + "\n[projects.\"/new/project\"]\ntrust_level = \"trusted\"\n"
            try Data(edited.utf8).write(to: f.config)
            let reopened = f.reopened()
            XCTAssertTrue(reopened.status(port: 4142).canChange)
            XCTAssertEqual(try contents(f.config), edited, "Status must not rewrite the selected model")
            try reopened.setEnabled(false, port: 4142)
            let restored = try contents(f.config)
            XCTAssertTrue(restored.contains("\"original\""))
            XCTAssertTrue(restored.contains("/new/project"))
            XCTAssertFalse(restored.contains(model))
        }
    }
    func testUserChangesToOwnedFieldsAreNeverOverwritten() throws {
        let f = try fixture()
        try f.manager.setEnabled(true, port: 4142)
        let edited = try contents(f.config).replacingOccurrences(of: "requires_openai_auth = true", with: "requires_openai_auth = false")
        try Data(edited.utf8).write(to: f.config)
        XCTAssertThrowsError(try f.reopened().setEnabled(false, port: 4142))
        XCTAssertEqual(try contents(f.config), edited)
        XCTAssertFalse(f.manager.status(port: 4142).canChange)
    }
    func testManualBridgeWithoutPriorBackupUsesExplicitDefaultProviderMigration() throws {
        let original = "model_provider=\"bridge\"\nmodel=\"keep\"\n[model_providers.bridge]\nbase_url=\"http://127.0.0.1:4142/v1\"\n"
        let f = try fixture(original)
        let initial = f.manager.status(port: 4142)
        XCTAssertTrue(initial.enabled); XCTAssertFalse(initial.managed)
        XCTAssertTrue(initial.message.contains("previous provider is unknown"))
        try f.manager.setEnabled(false, port: 4142)
        let disabled = try contents(f.config)
        XCTAssertFalse(disabled.contains("model_provider="))
        XCTAssertTrue(disabled.contains("[model_providers.bridge]"))
        XCTAssertTrue(try generations(f).contains { try contents($0.appendingPathComponent("before.toml")) == original })
        try f.manager.setEnabled(true, port: 4142)
        try f.manager.setEnabled(false, port: 4142)
        XCTAssertEqual(try contents(f.config), disabled)
    }
    func testCorruptOrMissingBackupBlocksRestoreWithoutChangingConfig() throws {
        for missing in [false, true] {
            let f = try fixture()
            try f.manager.setEnabled(true, port: 4142)
            let installed = try contents(f.config)
            let backup = try active(f).appendingPathComponent("before.toml")
            if missing { try FileManager.default.removeItem(at: backup) }
            else { try Data("CORRUPT".utf8).write(to: backup) }
            XCTAssertThrowsError(try f.reopened().setEnabled(false, port: 4142))
            XCTAssertFalse(f.manager.status(port: 4142).canChange)
            XCTAssertEqual(try contents(f.config), installed)
        }
        let orphan = try fixture("model_provider=\"copilot_bridge_app\"\n")
        XCTAssertFalse(orphan.manager.status(port: 4142).canChange)
        XCTAssertThrowsError(try orphan.manager.setEnabled(false, port: 4142))
        XCTAssertEqual(try contents(orphan.config), "model_provider=\"copilot_bridge_app\"\n")
    }
    func testCorruptJournalAndWrongHomeAreRejected() throws {
        let f = try fixture()
        try f.manager.setEnabled(true, port: 4142)
        let installed = try contents(f.config)
        let state = f.manager.backupsURL.appendingPathComponent("state.json")
        let saved = try Data(contentsOf: state)
        try Data("broken".utf8).write(to: state)
        XCTAssertThrowsError(try f.manager.setEnabled(false, port: 4142))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object["configPath"] = "/different/home/config.toml"
        try JSONSerialization.data(withJSONObject: object).write(to: state)
        XCTAssertThrowsError(try f.reopened().setEnabled(false, port: 4142))
        XCTAssertEqual(try contents(f.config), installed)
    }
    func testOwnershipMetadataCannotBeChangedWithoutBreakingItsSeal() throws {
        let f = try fixture()
        try f.manager.setEnabled(true, port: 4142)
        let manifest = try active(f).appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var plan = try XCTUnwrap(object["plan"] as? [String: Any])
        plan["originalSelector"] = "model_provider=\"wrong-provider\"\n"
        object["plan"] = plan
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        let installed = try contents(f.config)
        XCTAssertThrowsError(try f.reopened().setEnabled(false, port: 4142))
        XCTAssertEqual(try contents(f.config), installed)
        let status = f.manager.status(port: 4142)
        XCTAssertTrue(status.known); XCTAssertTrue(status.enabled); XCTAssertFalse(status.canChange)
    }
    func testConfigSymlinksAndHardLinksAreRejected() throws {
        for hard in [false, true] {
            let f = try fixture(nil)
            let other = f.root.appendingPathComponent("other.toml")
            try Data("model=\"keep\"\n".utf8).write(to: other)
            if hard { try FileManager.default.linkItem(at: other, to: f.config) }
            else { try FileManager.default.createSymbolicLink(at: f.config, withDestinationURL: other) }
            XCTAssertThrowsError(try f.manager.setEnabled(true, port: 4142))
            XCTAssertEqual(try contents(other), "model=\"keep\"\n")
        }
    }
    func testReadOnlyConfigIsNotReplaced() throws {
        let f = try fixture()
        let original = try contents(f.config)
        chmod(f.config.path, 0o400)
        XCTAssertThrowsError(try f.manager.setEnabled(true, port: 4142))
        XCTAssertEqual(try contents(f.config), original)
        XCTAssertFalse(f.manager.status(port: 4142).canChange)
        chmod(f.config.path, 0o600)
    }
    func testBackupDirectorySymlinkIsRejected() throws {
        let f = try fixture()
        let other = f.root.appendingPathComponent("other")
        try AppPaths.prepare(other)
        try FileManager.default.createSymbolicLink(at: f.data.appendingPathComponent("CodexConfig"), withDestinationURL: other)
        XCTAssertThrowsError(try f.manager.setEnabled(true, port: 4142))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }
    func testConfigurationLockExcludesAnotherManagerAndSurvivesReopening() throws {
        let f = try fixture()
        let second = f.reopened()
        f.manager.checkpoint = { step in
            if step == "prepared" { XCTAssertThrowsError(try second.setEnabled(true, port: 4142)) }
        }
        try f.manager.setEnabled(true, port: 4142)
        XCTAssertTrue(second.status(port: 4142).enabled)
        try second.setEnabled(false, port: 4142)
    }
    func testCrashRecoveryBeforeAndAfterAtomicSwapNeverChangesConfigOnStatus() throws {
        for stage in ["backup", "prepared", "swapped", "committed"] {
            let f = try fixture()
            let original = try contents(f.config)
            f.manager.checkpoint = { if $0 == stage { throw BridgeError.message("simulated crash") } }
            XCTAssertThrowsError(try f.manager.setEnabled(true, port: 4142))
            let atCrash = try contents(f.config)
            let reopened = f.reopened()
            let status = reopened.status(port: 4142)
            XCTAssertEqual(try contents(f.config), atCrash, "Status must never rewrite config")
            XCTAssertTrue(status.canChange, "\(stage): \(status.message)")
            XCTAssertEqual(status.enabled, ["swapped", "committed"].contains(stage))
            if status.enabled { try reopened.setEnabled(false, port: 4142) }
            XCTAssertEqual(try contents(f.config), original)
        }
    }
    func testCrashDuringRestoreReconcilesTheCorrectActiveBackup() throws {
        for stage in ["prepared", "swapped", "committed"] {
            let f = try fixture()
            let original = try contents(f.config)
            try f.manager.setEnabled(true, port: 4142)
            f.manager.checkpoint = { if $0 == stage { throw BridgeError.message("simulated crash") } }
            XCTAssertThrowsError(try f.manager.setEnabled(false, port: 4142))
            let atCrash = try contents(f.config)
            let reopened = f.reopened()
            let status = reopened.status(port: 4142)
            XCTAssertEqual(try contents(f.config), atCrash)
            XCTAssertTrue(status.canChange, status.message)
            XCTAssertEqual(status.enabled, stage == "prepared")
            if status.enabled { try reopened.setEnabled(false, port: 4142) }
            XCTAssertEqual(try contents(f.config), original)
        }
    }
    func testConcurrentEditsBeforeCommitAndAtAtomicSwapAreRetained() throws {
        for step in ["prepared", "beforeSwap"] {
            let f = try fixture()
            let external = "model = \"external-edit\"\n"
            f.manager.checkpoint = { if $0 == step { try Data(external.utf8).write(to: f.config, options: .atomic) } }
            XCTAssertThrowsError(try f.manager.setEnabled(true, port: 4142))
            XCTAssertEqual(try contents(f.config), external)
            let reopened = f.reopened()
            XCTAssertTrue(reopened.status(port: 4142).canChange)
            try reopened.setEnabled(true, port: 4142)
            try reopened.setEnabled(false, port: 4142)
            XCTAssertEqual(try contents(f.config), external)
        }
    }
    func testConcurrentCreationNeverOverwritesANewUserConfig() throws {
        let f = try fixture(nil)
        let external = "model=\"created-elsewhere\"\n"
        f.manager.checkpoint = { if $0 == "beforeSwap" { try Data(external.utf8).write(to: f.config) } }
        XCTAssertThrowsError(try f.manager.setEnabled(true, port: 4142))
        XCTAssertEqual(try contents(f.config), external)
        XCTAssertTrue(f.reopened().status(port: 4142).canChange)
    }
    func testUnrelatedEditsAfterSwapAreRecoveredWithoutRewritingThem() throws {
        for enabling in [true, false] {
            let f = try fixture()
            if !enabling { try f.manager.setEnabled(true, port: 4142) }
            f.manager.checkpoint = { step in
                if step == "swapped" {
                    let edited = try self.contents(f.config).replacingOccurrences(of: "\"original\"", with: "\"late-edit\"")
                    try Data(edited.utf8).write(to: f.config)
                }
            }
            XCTAssertThrowsError(try f.manager.setEnabled(enabling, port: 4142))
            let edited = try contents(f.config)
            let reopened = f.reopened()
            let status = reopened.status(port: 4142)
            XCTAssertTrue(status.canChange, status.message)
            XCTAssertEqual(status.enabled, enabling)
            XCTAssertEqual(try contents(f.config), edited)
            if enabling { try reopened.setEnabled(false, port: 4142) }
            XCTAssertTrue(try contents(f.config).contains("late-edit"))
        }
    }
    func testEachActivationGetsANewBackupAndPortCannotReplaceItsBaseline() throws {
        let f = try fixture()
        try f.manager.setEnabled(true, port: 4142)
        let first = try active(f)
        XCTAssertThrowsError(try f.manager.setEnabled(true, port: 4143))
        XCTAssertEqual(try active(f), first)
        try f.manager.setEnabled(false, port: 4142)
        let nextOriginal = "model=\"new-original\"\n"
        try Data(nextOriginal.utf8).write(to: f.config)
        try f.manager.setEnabled(true, port: 4143)
        XCTAssertNotEqual(try active(f), first)
        try f.manager.setEnabled(false, port: 4143)
        XCTAssertEqual(try contents(f.config), nextOriginal)
    }
    func testExactRestoreStillWorksIfTheParsingHelperBecomesUnavailable() throws {
        let f = try fixture()
        let original = try contents(f.config)
        try f.manager.setEnabled(true, port: 4142)
        let manager = CodexConfigManager(home: f.home, dataRoot: f.data) { _ in
            throw BridgeError.message("helper unavailable")
        }
        XCTAssertTrue(manager.status(port: 4142).canChange)
        try manager.setEnabled(false, port: 4142)
        XCTAssertEqual(try contents(f.config), original)
    }
    func testPlannerFailureDoesNotCreateATransactionOrTouchConfig() throws {
        let f = try fixture()
        let original = try contents(f.config)
        let manager = CodexConfigManager(home: f.home, dataRoot: f.data) { _ in
            throw BridgeError.message("planner failed")
        }
        XCTAssertThrowsError(try manager.setEnabled(true, port: 4142))
        XCTAssertEqual(try contents(f.config), original)
        XCTAssertTrue(try generations(f).isEmpty)
    }
    func testDeadHelperCannotKillTheAppWithSIGPIPEOrEchoPrivateConfig() throws {
        let f = try fixture()
        let planner = CodexConfigPlanner(executable: URL(fileURLWithPath: "/usr/bin/false"),
            home: f.root, arguments: [])
        XCTAssertThrowsError(try planner.plan(.init(action: "inspect",
            text: "PRIVATE_CANARY" + String(repeating: "x", count: 900000), port: 4142))) {
            XCTAssertFalse($0.localizedDescription.contains("PRIVATE_CANARY"))
        }
    }
    @MainActor
    func testControllerCanRestoreRoutingEvenWhenUnrelatedBridgeSettingsAreInvalid() async throws {
        let f = try fixture()
        let original = try contents(f.config)
        try f.manager.setEnabled(true, port: 4142)
        let controller = BridgeController(root: f.data, backend: nil, home: f.root,
            heartbeat: 1000, codexHome: f.home, configPlanner: f.planner.plan)
        for _ in 0..<100 where controller.isUpdatingCodex { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.codexSwitch.enabled)
        controller.settings.proxyURL = "invalid-proxy"
        controller.setCodexEnabled(false)
        for _ in 0..<100 where controller.isUpdatingCodex { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(controller.isUpdatingCodex)
        XCTAssertFalse(controller.codexSwitch.enabled)
        XCTAssertEqual(try contents(f.config), original)
        XCTAssertTrue(controller.message.contains("Restart Codex App"))
    }
    @MainActor
    func testInvalidCodexHomeDoesNotSilentlyFallBackToEditingDefaultConfig() async throws {
        let f = try fixture()
        let original = try contents(f.config)
        let controller = BridgeController(root: f.data, backend: nil, home: f.root,
            heartbeat: 1000, codexHome: f.home, configPlanner: f.planner.plan,
            codexHomeError: "CODEX_HOME must be an absolute path.")
        controller.setCodexEnabled(true)
        XCTAssertFalse(controller.codexSwitch.canChange)
        XCTAssertEqual(try contents(f.config), original)
        XCTAssertTrue(controller.message.contains("absolute path"))
    }
}
