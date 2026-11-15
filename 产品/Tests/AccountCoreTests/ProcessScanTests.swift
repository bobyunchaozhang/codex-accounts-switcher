import XCTest
@testable import AccountCore
final class ProcessScanTests: XCTestCase {
    func testTransientIdentityFailureRetriesFreshSnapshot() throws {
        var calls=0, pauses=0
        let rows: [Int] = try ProcessScan.read(attempts:3,pause:{ pauses += 1 }) {
            calls += 1
            if calls==1 { throw AccountError.message("exiting") }
            return []
        }
        XCTAssertTrue(rows.isEmpty);XCTAssertEqual(calls,2);XCTAssertEqual(pauses,1)
    }
    func testPersistentFailureNeverBecomesEmptySnapshot() {
        var calls=0
        XCTAssertThrowsError(try ProcessScan.read(attempts:3,pause:{}) { () throws -> [Int] in
            calls += 1;throw AccountError.message("unreadable live process")
        })
        XCTAssertEqual(calls,3)
    }
    func testRecoveredLiveProcessRemainsBlocking() throws {
        var calls=0
        let live = try ProcessScan.read(attempts:2,pause:{}) { () throws -> [DesktopProcess] in
            calls += 1;if calls==1 { throw AccountError.message("transient") }
            return [DesktopProcess(pid:10,parent:1,executable:"/opt/bin/codex",birth:"1:2")]
        }
        XCTAssertEqual(DesktopProcessScope(appPath:"/Applications/ChatGPT.app",roots:[],snapshot:[]).blockers(live).count,1)
    }
    func testZombieStatusOnly() {
        XCTAssertTrue(ProcessScan.isZombie("Z+"));XCTAssertFalse(ProcessScan.isZombie("S+"));XCTAssertFalse(ProcessScan.isZombie("R"))
    }

    func testActualPSPaddingPreservesSpacesInsideExecutableButNotBeforeIt() throws {
        let raw="93726     1 S       /Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        let row=try XCTUnwrap(ProcessScan.parse(raw))
        XCTAssertEqual(row.executable,"/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
        let helper=try XCTUnwrap(ProcessScan.parse("  5  1 S+   /Applications/ChatGPT.app/Contents/Frameworks/Codex (Aperitif Renderer).app/Contents/MacOS/Codex (Aperitif Renderer)"))
        XCTAssertTrue(helper.executable.hasPrefix("/Applications/ChatGPT.app/"))
        XCTAssertTrue(helper.executable.hasSuffix("Codex (Aperitif Renderer)"))
        XCTAssertNil(ProcessScan.parse("broken"))
    }
    func testParsedRealisticRowBlocksExitAndMatchesReopenPredicate() throws {
        let app="/Applications/ChatGPT.app"
        let parsed=try XCTUnwrap(ProcessScan.parse(" 93726     1 S    /Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        let p=DesktopProcess(pid:parsed.pid,parent:parsed.parent,executable:parsed.executable,birth:"100:1")
        let scope=DesktopProcessScope(appPath:app,roots:[93726],snapshot:[p])
        XCTAssertEqual(scope.blockers([p]).count,1)
        XCTAssertTrue(p.pid==93726 && p.executable.hasPrefix(app+"/Contents/MacOS/"))
    }
}
