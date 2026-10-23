import XCTest
@testable import MochiCore

/// Connecting and disconnecting must leave everything else in each CLI's
/// config exactly as it was — other hooks, other settings, key order.
final class HookInstallerTests: XCTestCase {
    private var home: URL!
    private var realHome: URL!

    override func setUpWithError() throws {
        realHome = HookInstaller.home
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        HookInstaller.home = home
    }

    override func tearDownWithError() throws {
        HookInstaller.home = realHome
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCodexKeepsOtherHooksAndSettings() throws {
        let original = #"{"model":"o5","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try write(".codex/hooks.json", original)
        XCTAssertFalse(HookInstaller.isInstalled("codex"))

        try HookInstaller.setInstalled("codex", true)
        XCTAssertTrue(HookInstaller.isInstalled("codex"))
        let on = try json(".codex/hooks.json")
        XCTAssertEqual(on["model"] as? String, "o5")
        let stop = try XCTUnwrap((on["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        let mine = try XCTUnwrap((stop[1]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(mine["timeout"] as? Int, 3)
        XCTAssertTrue((mine["command"] as? String ?? "").hasSuffix("mochi-hook.sh codex Stop"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: home.appendingPathComponent(".codex/hooks/mochi-hook.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json.mochi-backup").path))

        // Connecting twice doesn't add a second copy.
        try HookInstaller.setInstalled("codex", true)
        XCTAssertEqual(((try json(".codex/hooks.json"))["hooks"] as? [String: Any])?["Stop"].map { ($0 as! [Any]).count }, 2)

        try HookInstaller.setInstalled("codex", false)
        let off = try json(".codex/hooks.json")
        XCTAssertEqual(off as NSDictionary, try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks/mochi-hook.sh").path))
    }

    func testConnectingTakesOutAIUsagesOldHook() throws {
        try write(".codex/hooks.json", #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/.codex/hooks/aiusage-minis.sh codex Stop"}]}]}}"#)
        try HookInstaller.setInstalled("codex", true)
        let stop = try XCTUnwrap((try json(".codex/hooks.json")["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertFalse("\(stop)".contains("aiusage-minis"))
    }

    func testCursorIsFlatAndVersioned() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        XCTAssertTrue(HookInstaller.canInstall("cursor"))
        try HookInstaller.setInstalled("cursor", true)
        let on = try json(".cursor/hooks.json")
        XCTAssertEqual(on["version"] as? Int, 1)
        let stop = try XCTUnwrap((on["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])
        XCTAssertTrue((stop[0]["command"] as? String ?? "").hasSuffix("mochi-hook.sh cursor stop"))
        // Nothing that can gate an action.
        let events = Set((on["hooks"] as? [String: Any] ?? [:]).keys)
        XCTAssertTrue(events.isDisjoint(with: ["preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "subagentStart"]))
        try HookInstaller.setInstalled("cursor", false)
        XCTAssertFalse(HookInstaller.isInstalled("cursor"))
    }

    func testCodexAndAntigravityShapes() throws {
        try HookInstaller.setInstalled("codex", true)
        let codex = try json(".codex/hooks.json")
        let group = try XCTUnwrap(((codex["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first)
        XCTAssertEqual((group["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 3)

        try write(".gemini/antigravity-cli/hooks.json", #"{"mine":{"Stop":[]}}"#)
        try HookInstaller.setInstalled("antigravity", true)
        let agy = try json(".gemini/antigravity-cli/hooks.json")
        XCTAssertNotNil(agy["mine"])
        let ours = try XCTUnwrap(agy["mochi"] as? [String: Any])
        XCTAssertNil(ours["PreToolUse"], "PreToolUse decides whether a tool may run; leave it alone")
        XCTAssertEqual((ours["PostToolUse"] as? [[String: Any]])?.first?["matcher"] as? String, "*")
        try HookInstaller.setInstalled("antigravity", false)
        XCTAssertNil(try json(".gemini/antigravity-cli/hooks.json")["mochi"])
    }

    func testRefusesANonObjectConfig() throws {
        try write(".codex/hooks.json", "[1, 2]")
        XCTAssertThrowsError(try HookInstaller.setInstalled("codex", true))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".codex/hooks.json"), encoding: .utf8), "[1, 2]")
    }
}
