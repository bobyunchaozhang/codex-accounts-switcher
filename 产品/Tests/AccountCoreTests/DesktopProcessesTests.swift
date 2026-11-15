import XCTest
@testable import AccountCore

final class DesktopProcessesTests: XCTestCase {
    let app = "/Applications/ChatGPT.app"
    func row(_ pid: Int32, _ parent: Int32, _ path: String, _ birth: String = "100:1") -> DesktopProcess {
        DesktopProcess(pid:pid,parent:parent,executable:path,birth:birth)
    }
    func testIncidentOrphanRuntimeAndCrashpadDoNotBlockOrGetKilled() {
        let main=row(10,1,app+"/Contents/MacOS/ChatGPT")
        let orphan=row(20,1,app+"/Contents/Resources/cua_node/bin/node")
        let crash=row(30,1,app+"/Contents/Frameworks/Codex Framework.framework/Helpers/browser_crashpad_handler")
        let scope=DesktopProcessScope(appPath:app,roots:[10],snapshot:[main,orphan,crash])
        XCTAssertTrue(scope.blockers([orphan,crash]).isEmpty)
        XCTAssertTrue(scope.forceTargets([orphan,crash]).isEmpty)
    }
    func testOwnedAppServerAndNewDescendantRemainTargetsAfterReparenting() {
        let main=row(10,1,app+"/Contents/MacOS/ChatGPT")
        let cli=row(11,10,app+"/Contents/Resources/codex")
        var scope=DesktopProcessScope(appPath:app,roots:[10],snapshot:[main,cli])
        let child=row(12,11,app+"/Contents/Resources/cua_node/bin/node")
        scope.observe([main,cli,child])
        let orphan=row(12,1,child.executable)
        XCTAssertEqual(scope.forceTargets([orphan]).map(\.pid),[12])
        XCTAssertEqual(scope.blockers([cli]).map(\.pid),[11])
    }
    func testReusedPIDNeverBecomesForceTarget() {
        let main=row(10,1,app+"/Contents/MacOS/ChatGPT")
        var scope=DesktopProcessScope(appPath:app,roots:[10],snapshot:[main])
        let replacement=row(10,1,main.executable,"100:2")
        scope.observe([replacement])
        XCTAssertTrue(scope.forceTargets([replacement]).isEmpty)
        XCTAssertFalse(scope.blockers([replacement]).isEmpty)
    }
    func testIndependentCLIBlocksWithoutKillAndAppRelaunchBlocks() {
        let cli=row(20,1,"/opt/homebrew/bin/codex")
        let scope=DesktopProcessScope(appPath:app,roots:[],snapshot:[])
        XCTAssertEqual(scope.independentCLI([cli]).map(\.pid),[20])
        XCTAssertEqual(scope.blockers([cli]).map(\.pid),[20])
        XCTAssertTrue(scope.forceTargets([cli]).isEmpty)
        XCTAssertFalse(scope.blockers([row(30,1,app+"/Contents/MacOS/ChatGPT")]).isEmpty)
    }
    func testUntrackedRendererBlocksButOtherProjectNodeDoesNot() {
        let renderer=row(21,1,app+"/Contents/Frameworks/Codex (Aperitif Renderer).app/Contents/MacOS/Codex (Aperitif Renderer)")
        let other=row(22,1,app+"/Contents/Resources/cua_node/bin/node")
        let scope=DesktopProcessScope(appPath:app,roots:[],snapshot:[])
        XCTAssertEqual(scope.blockers([renderer,other]).map(\.pid),[21])
        XCTAssertTrue(scope.forceTargets([renderer,other]).isEmpty)
    }
    func testDesktopIdentityRequiresRendererAndAuthAgreement() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob")
        let state=try JSONSerialization.data(withJSONObject:[ProjectView.stateKey:["owner":ProjectView.rendererKey(a)!]])
        XCTAssertTrue(DesktopIdentity.matches(a,auth:a.data,state:state))
        XCTAssertFalse(DesktopIdentity.matches(b,auth:b.data,state:state))
        XCTAssertFalse(DesktopIdentity.matches(a,auth:b.data,state:state))
        XCTAssertFalse(DesktopIdentity.matches(a,auth:a.data,state:nil))
    }

    func testWorkspaceGhostDoesNotBlockStoppedDesktop() {
        let scope=DesktopProcessScope(appPath:app,roots:[],snapshot:[])
        XCTAssertTrue(scope.remainingClients([],registeredPIDs:[90268]).isEmpty)
        let unrelated=row(20,1,app+"/Contents/Resources/cua_node/bin/node")
        XCTAssertTrue(scope.remainingClients([unrelated],registeredPIDs:[90268]).isEmpty)
    }
    func testLiveRegisteredProcessOrCLIStillBlocksEvenWithStaleWorkspaceList() {
        let scope=DesktopProcessScope(appPath:app,roots:[],snapshot:[])
        let main=row(10,1,app+"/Contents/MacOS/ChatGPT")
        XCTAssertEqual(scope.remainingClients([main],registeredPIDs:[]).map(\.pid),[10])
        let unidentified=row(11,1,"/unknown/client")
        XCTAssertEqual(scope.remainingClients([unidentified],registeredPIDs:[11]).map(\.pid),[11])
        let cli=row(12,1,"/opt/bin/codex")
        XCTAssertEqual(scope.remainingClients([cli],registeredPIDs:[]).map(\.pid),[12])
    }
}
