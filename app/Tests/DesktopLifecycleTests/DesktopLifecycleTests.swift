import XCTest
import AppKit
@testable import AccountMenu
import AccountCore
import CryptoKit

final class DesktopLifecycleTests: XCTestCase {
    func testRealQuitAndReopenOfIsolatedFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEX_ACCOUNTS_FIXTURE_APP"] else {
            throw XCTSkip("Run scripts/test-desktop-lifecycle.sh to provide the isolated fixture app.")
        }
        let app = URL(fileURLWithPath:path)
        let identifier = try XCTUnwrap(Bundle(url:app)?.bundleIdentifier)
        guard identifier.hasPrefix("local.codex.accounts.fixture."), path.hasPrefix("/private/tmp/") else {
            XCTFail("Refuse to operate a non-fixture application"); return
        }
        let realBefore = Set(NSRunningApplication.runningApplications(withBundleIdentifier:"com.openai.codex").map(\.processIdentifier))
        let desktop = Desktop(ClientLocation(app:app,cli:app.appendingPathComponent("unused")),snapshotFilter:{ rows in
            rows.filter { $0.executable.hasPrefix(app.path + "/") }
        })
        let done=expectation(description:"fixture lifecycle")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                try desktop.requireStopped()
                for _ in 0..<2 {
                    try desktop.reopen()
                    XCTAssertThrowsError(try desktop.requireStopped(),"A running fixture must block writes")
                    try desktop.quitAndVerify()
                    XCTAssertNoThrow(try desktop.requireStopped(),"A stopped fixture must allow the next phase")
                }
            } catch { XCTFail("Fixture lifecycle failed: \(error)") }
        }
        wait(for:[done],timeout:60)
        XCTAssertEqual(realBefore,Set(NSRunningApplication.runningApplications(withBundleIdentifier:"com.openai.codex").map(\.processIdentifier)))
        // Cleanup is restricted to this unique fixture bundle even on a failed assertion.
        for instance in NSRunningApplication.runningApplications(withBundleIdentifier:identifier) { _ = instance.terminate() }
    }

    func testFirstAttemptSwitchesFixtureCredentialsAndReopensBothWays() throws {
        guard let path=ProcessInfo.processInfo.environment["CODEX_ACCOUNTS_FIXTURE_APP"] else { throw XCTSkip("Isolated fixture is required") }
        let app=URL(fileURLWithPath:path), root=app.deletingLastPathComponent()
        let identifier=try XCTUnwrap(Bundle(url:app)?.bundleIdentifier)
        guard identifier.hasPrefix("local.codex.accounts.fixture."), path.hasPrefix("/private/tmp/") else { XCTFail("Not a fixture");return }
        let realBefore=Set(NSRunningApplication.runningApplications(withBundleIdentifier:"com.openai.codex").map(\.processIdentifier))
        func credential(_ name:String) throws -> Credential {
            let claims:[String:Any] = ["sub":name,"email":name+"@example.invalid","https://api.openai.com/auth":["chatgpt_user_id":name]]
            let part=try JSONSerialization.data(withJSONObject:claims).base64EncodedString().replacingOccurrences(of:"=",with:"").replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_")
            return try Credential(JSONSerialization.data(withJSONObject:["tokens":["id_token":"fake."+part+".fake","access_token":"fixture","account_id":"fixture-"+name,"refresh_token":""]]))
        }
        let a=try credential("A"),b=try credential("B"),active=root.appendingPathComponent("fixture-auth.json")
        try PrivateFiles.write(a.data,to:active)
        let stateStore = DesktopStateStore(home: root)
        let state=stateStore.jsonURL, checkpoint=root.appendingPathComponent("fixture-checkpoint.json")
        let initial:[String:Any] = [DesktopState.ownerKey:ProjectView.rendererKey(a)!,
            "local-projects":["p1":["name":"Shared","rootPaths":[root.path]]],
            "thread-project-assignments":["chat":"p1"],"projectless-thread-ids":["loose"],
            DesktopState.hintKey("thread-workspace-root-hints",owner:ProjectView.rendererKey(a)!):["chat":root.path]]
        try PrivateFiles.write(JSONSerialization.data(withJSONObject:initial),to:state)
        // Reproduce the incident: old checkpoint names another account, public state is valid.
        try SharedContinuity.activated(b,checkpoint:checkpoint)
        let tx=try AuthTransaction(active:active,folder:root.appendingPathComponent("fixture-transaction"))
        let desktop=Desktop(ClientLocation(app:app,cli:app.appendingPathComponent("unused")),snapshotFilter: { $0.filter { $0.executable.hasPrefix(app.path+"/") } })
        let done=expectation(description:"fixture credential roundtrip")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                try desktop.reopen()
                for target in [b,a] {
                    let op=SwitchOperations(activity:{ .idle },validateTarget:{ $0 },stopDesktop:{ try desktop.quitAndVerify() },savePrevious:{ _ in },verifyWritten:{ written in
                        XCTAssertTrue(written.identity.matches(target.identity))
                    },reopen:{ try desktop.reopen() },prepareProjectView:{ source,target in
                        try SharedContinuity.validate(source,checkpoint:checkpoint,state:PrivateFiles.read(state))
                        try desktop.requireStopped()
                        try ProjectView.syncTarget(stateURL:state,source:source,target:target,backupFolder:root.appendingPathComponent("fixture-state-backups"))
                    },preflightView:{ current in
                        try SharedContinuity.validate(current,checkpoint:checkpoint,state:PrivateFiles.read(state))
                        _ = try ProjectView.proposedState(PrivateFiles.read(state),source:current,target:target,codexHome:root)
                    },credentialsChanged:{ try SharedContinuity.activated($0,checkpoint:checkpoint,state:PrivateFiles.read(state)) },verifyDesktop:{ written in
                        let expected=SHA256.hash(data:written.data).map { String(format:"%02x",$0) }.joined()
                        return (try? String(contentsOf:root.appendingPathComponent("loaded-auth-digest.txt"),encoding:.utf8)) == expected
                            && desktop.verifyDesktop(written,state:stateStore,authURL:active)
                    },beforeCommit:{ try desktop.requireStopped() })
                    let outcome=SwitchEngine.run(target:target,transaction:tx,operations:op)
                    XCTAssertTrue(outcome.targetWritten);XCTAssertTrue(outcome.desktopVerified);XCTAssertNil(outcome.message)
                    XCTAssertEqual(try PrivateFiles.read(active),target.data)
                    let actual=try DesktopState(PrivateFiles.read(state))
                    XCTAssertEqual(actual.format,.sharedGlobals)
                    for key in DesktopState.requiredSharedKeys {
                        XCTAssertTrue(NSDictionary(dictionary:["value":initial[key]!]).isEqual(to:["value":actual.root[key]!]),key)
                    }
                }
                try desktop.quitAndVerify()
            } catch { XCTFail("Fixture roundtrip failed: \(error)") }
        }
        wait(for:[done],timeout:60)
        XCTAssertEqual(realBefore,Set(NSRunningApplication.runningApplications(withBundleIdentifier:"com.openai.codex").map(\.processIdentifier)))
        for instance in NSRunningApplication.runningApplications(withBundleIdentifier:identifier) { _ = instance.terminate() }
    }
}
