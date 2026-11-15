import XCTest
@testable import AccountCore

final class SwitchEngineTests: XCTestCase {
    func scenario(_ body: (URL, Credential, Credential, AuthTransaction, inout SwitchOperations, () -> [String]) throws -> Void) throws {
        let helper = AccountCoreTests()
        try helper.temp { root in
            let a = try helper.credential(), b = try helper.credential("bob")
            let active = root.appendingPathComponent("auth.json")
            try PrivateFiles.write(a.data, to: active)
            let tx = try AuthTransaction(active: active, folder: root.appendingPathComponent("tx"))
            var events: [String] = []
            var op = SwitchOperations(activity: { .unknown }, validateTarget: { c in events.append("validate"); return c },
                                      stopDesktop: { events.append("stop") }, savePrevious: { _ in events.append("save") },
                                      verifyWritten: { c in events.append("verify"); XCTAssertTrue(c.identity.matches(b.identity)) }, reopen: { events.append("open") }, verifyDesktop: { _ in true })
            try body(active, a, b, tx, &op, { events })
        }
    }
    func testKnownTaskStopsBeforeAnySideEffect() throws {
        try scenario { active, a, b, tx, op, events in
            op.activity = { .running }
            let r = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertFalse(r.targetWritten); XCTAssertTrue(events().isEmpty)
            XCTAssertEqual(try PrivateFiles.read(active), a.data)
        }
    }
    func testUnknownTaskUsesAgreedQuitThenSwitchFlow() throws {
        try scenario { active, _, b, tx, op, events in
            let r = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertTrue(r.identityVerified); XCTAssertNil(r.message)
            XCTAssertEqual(events(), ["validate", "stop", "save", "verify", "open"])
            XCTAssertEqual(try PrivateFiles.read(active), b.data)
        }
    }
    func testFailedTargetValidationDoesNotQuitOrWrite() throws {
        try scenario { active, a, b, tx, op, events in
            op.validateTarget = { _ in throw AccountError.message("expired") }
            let r = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertFalse(r.targetWritten); XCTAssertFalse(events().contains("stop"))
            XCTAssertEqual(try PrivateFiles.read(active), a.data)
        }
    }
    func testClientStillRunningPreventsAuthReplacement() throws {
        try scenario { active, a, b, tx, op, _ in
            op.stopDesktop = { throw AccountError.message("still running") }
            let r = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertFalse(r.targetWritten); XCTAssertEqual(try PrivateFiles.read(active), a.data)
        }
    }
    func testNetworkTimeoutAfterWriteKeepsBAndReopens() throws {
        try scenario { active, _, b, tx, op, events in
            op.verifyWritten = { _ in throw AccountError.message("timeout") }
            let r = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertTrue(r.targetWritten); XCTAssertFalse(r.identityVerified)
            XCTAssertTrue(events().contains("open")); XCTAssertEqual(try PrivateFiles.read(active), b.data)
        }
    }
    func testReopenFailureDoesNotUndoVerifiedB() throws {
        try scenario { active, _, b, tx, op, _ in
            op.reopen = { throw AccountError.message("open failed") }
            let r = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertTrue(r.targetWritten); XCTAssertTrue(r.identityVerified); XCTAssertTrue(r.needsReopen)
            XCTAssertEqual(try PrivateFiles.read(active), b.data)
        }
    }
    func testDefinitiveRejectionAfterWriteRestoresA() throws {
        try scenario { active, a, b, tx, op, events in
            op.verifyWritten = { _ in throw AccountError.authenticationRejected }
            let r = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertFalse(r.targetWritten); XCTAssertFalse(r.identityVerified)
            XCTAssertEqual(try PrivateFiles.read(active), a.data)
            XCTAssertTrue(events().contains("open")); XCTAssertNil(try tx.journal)
        }
    }
    func testTaskStartsDuringValidationPreventsQuit() throws {
        try scenario { active, a, b, tx, op, events in
            var calls = 0
            op.activity = { calls += 1; return calls == 1 ? .idle : .running }
            let r = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertFalse(r.targetWritten); XCTAssertFalse(events().contains("stop"))
            XCTAssertEqual(try PrivateFiles.read(active), a.data)
        }
    }
    func testProjectPreparationRunsAfterQuitAndBeforeAuthWrite() throws {
        try scenario { active, a, b, tx, op, _ in
            var prepared = false
            var stopped = false
            op.stopDesktop = { stopped = true }
            op.prepareProjectView = { source, target in
                XCTAssertTrue(stopped)
                XCTAssertEqual(try PrivateFiles.read(active), a.data)
                XCTAssertTrue(source.identity.matches(a.identity)); XCTAssertTrue(target.identity.matches(b.identity))
                prepared = true
            }
            let r = SwitchEngine.run(target:b,transaction:tx,operations:op)
            XCTAssertTrue(prepared); XCTAssertTrue(r.identityVerified)
        }
    }

    func testCredentialVerificationDoesNotImplyDesktopVerification() throws {
        try scenario { active, _, b, tx, op, events in
            var opened = false
            op.reopen = { opened = true }
            op.verifyDesktop = { _ in XCTAssertTrue(opened); return false }
            let result = SwitchEngine.run(target: b, transaction: tx, operations: op)
            XCTAssertTrue(result.identityVerified); XCTAssertFalse(result.desktopVerified)
            XCTAssertNotNil(result.message); XCTAssertTrue(result.targetWritten)
            XCTAssertEqual(try PrivateFiles.read(active), b.data)
        }
    }
    func testContinuityFailureDoesNotQuitOrWrite() throws {
        try scenario { active, a, b, tx, op, events in
            op.preflightView = { _ in throw AccountError.message("external login") }
            let r = SwitchEngine.run(target:b, transaction:tx, operations:op)
            XCTAssertFalse(r.targetWritten); XCTAssertTrue(events().isEmpty)
            XCTAssertEqual(try PrivateFiles.read(active),a.data)
        }
    }
    func testRelaunchBeforeCommitPreventsCredentialWrite() throws {
        try scenario { active,a,b,tx,op,_ in
            op.beforeCommit = { throw AccountError.message("desktop relaunched") }
            let r = SwitchEngine.run(target:b,transaction:tx,operations:op)
            XCTAssertFalse(r.targetWritten); XCTAssertEqual(try PrivateFiles.read(active),a.data)
        }
    }
    func testOutsideLoginDuringQuitDoesNotOverwriteOrPrepareView() throws {
        try scenario { active,_,b,tx,op,_ in
            let external = try AccountCoreTests().credential("third")
            op.stopDesktop = { try PrivateFiles.write(external.data,to:active) }
            op.prepareProjectView = { _,_ in XCTFail("must not prepare") }
            let r = SwitchEngine.run(target:b,transaction:tx,operations:op)
            XCTAssertFalse(r.targetWritten); XCTAssertEqual(try PrivateFiles.read(active),external.data)
        }
    }
    func testActivationCheckpointReturnsToPriorOwnerOnRejectedCredential() throws {
        try scenario { _,a,b,tx,op,_ in
            var changed: [String] = []
            op.credentialsChanged = { changed.append($0.identity.key) }
            op.verifyWritten = { _ in throw AccountError.authenticationRejected }
            _ = SwitchEngine.run(target:b,transaction:tx,operations:op)
            XCTAssertEqual(changed,[b.identity.key,a.identity.key])
        }
    }

    func testAlreadyInstalledCredentialReopensMissingDesktopWithoutRewriting() throws {
        try scenario { active,_,b,tx,op,_ in
            try PrivateFiles.write(b.data,to:active)
            var opened=false
            op.verifyDesktop={ _ in opened };op.reopen={ opened=true }
            op.stopDesktop={ XCTFail("must not quit") }
            let r=SwitchEngine.run(target:b,transaction:tx,operations:op)
            XCTAssertTrue(r.desktopVerified);XCTAssertFalse(r.targetWritten)
            XCTAssertEqual(try PrivateFiles.read(active),b.data)
        }
    }
    func testQuitFailureAndFailedRecoveryExposeReopenAction() throws {
        try scenario { active,a,b,tx,op,_ in
            op.stopDesktop={ throw AccountError.message("unreadable") }
            op.reopen={ throw AccountError.message("still exiting") }
            let r=SwitchEngine.run(target:b,transaction:tx,operations:op)
            XCTAssertTrue(r.needsReopen);XCTAssertFalse(r.targetWritten)
            XCTAssertEqual(r.failureMessage,"unreadable");XCTAssertEqual(r.reopenFailure,"still exiting")
            XCTAssertTrue(r.message?.contains("unreadable") == true)
            XCTAssertEqual(try PrivateFiles.read(active),a.data)
        }
    }
}
