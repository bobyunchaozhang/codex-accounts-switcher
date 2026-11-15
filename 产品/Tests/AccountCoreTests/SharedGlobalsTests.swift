import XCTest
@testable import AccountCore

final class SharedGlobalsTests: XCTestCase {
    let home = URL(fileURLWithPath: "/tmp/shared-home")
    func data(_ root: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) }
    func fixture(_ a: Credential, _ b: Credential) -> [String: Any] {
        [DesktopState.ownerKey: ProjectView.rendererKey(a)!,
         "local-projects": ["p1": ["id":"p1", "name":"Project", "rootPaths":["/tmp/project"]]],
         "thread-project-assignments": ["chat": ["projectKind":"local", "projectId":"p1"], "remote": ["projectKind":"remote", "projectId":"cloud"]],
         "projectless-thread-ids": ["loose"], "project-order":["p1"],
         "thread-project-membership-host-ids":["chat":"local:/tmp/shared-home", "loose":"local", "remote":"remote-host"],
         DesktopState.hintKey("thread-workspace-root-hints", owner:ProjectView.rendererKey(a)!): ["chat":"/tmp/project", "loose":"/tmp/loose", "remote":"/private/remote-A"],
         DesktopState.hintKey("thread-workspace-root-hints", owner:ProjectView.rendererKey(b)!): ["remote":"/private/remote-B", "target-only":"/tmp/keep"],
         DesktopState.hintKey("thread-writable-roots", owner:ProjectView.rendererKey(a)!): ["chat":["/private/permission-A"]],
         DesktopState.hintKey("thread-writable-roots", owner:ProjectView.rendererKey(b)!): ["chat":["/private/permission-B"]],
         DesktopState.hintKey("app-server-projects-migration-by-host", owner:ProjectView.rendererKey(b)!): ["local":["version":1,"projectsMigrated":false]],
         "electron-owner-atoms:" + ProjectView.rendererKey(b)!:["account-private":"keep"],
         "queued-follow-ups":["never-copy"]]
    }

    func testIdentityRecognizesBothSchemasAndRejectsConflictAndSignedOut() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob")
        var root=fixture(a,b)
        XCTAssertTrue(DesktopIdentity.matches(a,auth:a.data,state:try data(root)))
        XCTAssertFalse(DesktopIdentity.matches(b,auth:b.data,state:try data(root)))
        XCTAssertTrue(DesktopIdentity.matches(a,auth:a.data,state:try data(ProjectViewTests().fixture(a,b))))
        root[ProjectView.stateKey] = ["owner":ProjectView.rendererKey(a)!,"inactive":[:]]
        XCTAssertThrowsError(try DesktopState(data(root)))
        XCTAssertFalse(DesktopIdentity.matches(a,auth:a.data,state:try data(root)))
        root.removeValue(forKey:ProjectView.stateKey);root[DesktopState.ownerKey]="signed-out"
        XCTAssertFalse(DesktopIdentity.matches(a,auth:a.data,state:try data(root)))
        root[DesktopState.ownerKey]=NSNull()
        XCTAssertThrowsError(try DesktopState(data(root)))
        XCTAssertThrowsError(try DesktopState(data([:])))
    }

    func testOldOrAbsentCheckpointDoesNotBlockValidPublicCatalogAfterExternalLogin() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob"), state=try data(fixture(a,b))
        try h.temp { dir in
            let checkpoint=dir.appendingPathComponent("checkpoint.json")
            XCTAssertNoThrow(try SharedContinuity.validate(a,checkpoint:checkpoint,state:state))
            XCTAssertFalse(FileManager.default.fileExists(atPath:checkpoint.path),"Preflight must not write")
            try SharedContinuity.activated(b,checkpoint:checkpoint)
            let old=try PrivateFiles.read(checkpoint)
            XCTAssertNoThrow(try SharedContinuity.validate(a,checkpoint:checkpoint,state:state))
            XCTAssertEqual(try PrivateFiles.read(checkpoint),old)
            XCTAssertThrowsError(try SharedContinuity.validate(b,checkpoint:checkpoint,state:state))
            try SharedContinuity.activated(a,checkpoint:checkpoint,state:state)
            let record=try JSONDecoder().decode(SharedContinuity.Checkpoint.self,from:PrivateFiles.read(checkpoint))
            XCTAssertEqual(record.format,.sharedGlobals)
            let backups=try FileManager.default.contentsOfDirectory(at:dir.appendingPathComponent("checkpoint-backups"),includingPropertiesForKeys:nil)
            XCTAssertEqual(backups.count,1);XCTAssertEqual(try PrivateFiles.read(backups[0]),old)
            try SharedContinuity.activated(b,checkpoint:checkpoint,state:state)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.appendingPathComponent("checkpoint-backups").path).count,1)
            XCTAssertThrowsError(try SharedContinuity.validate(b,checkpoint:checkpoint,state:try data(ProjectViewTests().fixture(b,a))))
        }
    }

    func testMissingMalformedOrContradictoryCatalogIsNotAnIntentionalDelete() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob"), base=fixture(a,b)
        try h.temp { dir in
            let cp=dir.appendingPathComponent("checkpoint.json")
            for key in DesktopState.requiredSharedKeys {
                var root=base;root.removeValue(forKey:key)
                XCTAssertThrowsError(try SharedContinuity.validate(a,checkpoint:cp,state:data(root)))
                root[key]=NSNull()
                XCTAssertThrowsError(try SharedContinuity.validate(a,checkpoint:cp,state:data(root)))
            }
            var root=base;root["thread-project-assignments"]=["chat":"missing"]
            XCTAssertThrowsError(try SharedContinuity.validate(a,checkpoint:cp,state:data(root)))
            root=base;root["projectless-thread-ids"]=["chat"]
            XCTAssertThrowsError(try SharedContinuity.validate(a,checkpoint:cp,state:data(root)))
            root=base;root["local-projects"]=["p1":["name":"Bad","rootPaths":["relative"]]]
            XCTAssertThrowsError(try SharedContinuity.validate(a,checkpoint:cp,state:data(root)))
            root=base;root["thread-project-membership-host-ids"]=["chat":23]
            XCTAssertThrowsError(try SharedContinuity.validate(a,checkpoint:cp,state:data(root)))
        }
    }

    func testOnlyKnownLocalHintsChangeWhilePublicCatalogAndAccountDataStayExact() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob"), before=fixture(a,b)
        let result=try XCTUnwrap(ProjectView.proposedState(data(before),source:a,target:b,codexHome:home))
        let after=try DesktopState(result).root
        let hint=DesktopState.hintKey("thread-workspace-root-hints",owner:ProjectView.rendererKey(b)!)
        for key in Set(before.keys).union(after.keys) where key != hint {
            XCTAssertTrue(NSDictionary(dictionary:["value":before[key] ?? NSNull()]).isEqual(to:["value":after[key] ?? NSNull()]),key)
        }
        XCTAssertEqual(after[hint] as? [String:String],["chat":"/tmp/project","loose":"/tmp/loose","remote":"/private/remote-B","target-only":"/tmp/keep"])
        XCTAssertNil(try ProjectView.proposedState(result,source:a,target:b,codexHome:home),"Second handoff is a no-op")
        var broken=before;broken[DesktopState.hintKey("thread-workspace-root-hints",owner:ProjectView.rendererKey(a)!)]=["chat":"relative"]
        XCTAssertThrowsError(try ProjectView.proposedState(data(broken),source:a,target:b,codexHome:home))
    }

    func testAddsRenamesDeletesAndEmptyLastProjectStayInTheSingleCatalogAcrossOwners() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob")
        var root=fixture(a,b)
        root["local-projects"]=["new":["name":"Renamed","rootPaths":[]]]
        root["thread-project-assignments"]=["chat":"new"]
        let first=try ProjectView.proposedState(data(root),source:a,target:b,codexHome:home) ?? data(root)
        var next=try DesktopState(first).root
        XCTAssertEqual((next["local-projects"] as? [String:[String:Any]])?["new"]?["name"] as? String,"Renamed")
        next[DesktopState.ownerKey]=ProjectView.rendererKey(b)!
        next["local-projects"]=[String:Any]();next["thread-project-assignments"]=[String:Any]();next["projectless-thread-ids"]=["chat","loose"]
        let second=try ProjectView.proposedState(data(next),source:b,target:a,codexHome:home) ?? data(next)
        var back=try DesktopState(second).root;back[DesktopState.ownerKey]=ProjectView.rendererKey(a)!
        let third=try ProjectView.proposedState(data(back),source:a,target:b,codexHome:home) ?? data(back)
        XCTAssertTrue((try DesktopState(third).root["local-projects"] as! [String:Any]).isEmpty)
        XCTAssertEqual(try DesktopState(third).root["projectless-thread-ids"] as? [String],["chat","loose"])
    }

    func testNewStructureDoesNotApplyOrUndoLegacyRecoveryOrResurrectSnapshots() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob")
        let old=try data(ProjectViewTests().fixture(a,b)), new=try data(fixture(a,b))
        let plan=try SharedContinuity.prepareRepair(old,active:a,accounts:[a,b],home:home)
        XCTAssertThrowsError(try SharedContinuity.prepareRepair(new,active:a,accounts:[a,b],home:home))
        XCTAssertThrowsError(try SharedContinuity.repairState(new,plan:plan,active:a,accounts:[a,b],home:home))
        XCTAssertThrowsError(try SharedContinuity.undoRepair(current:new,before:old,expectedAfterDigest:SharedContinuity.digest(old),active:a))
        XCTAssertNotEqual(try SharedContinuity.digest(old),try SharedContinuity.digest(new))
    }

    func testUnknownSchemaStopsBeforeQuitOrAuthWrite() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob")
        try h.temp { dir in
            let active=dir.appendingPathComponent("auth.json"), cp=dir.appendingPathComponent("checkpoint.json")
            try PrivateFiles.write(a.data,to:active)
            let tx=try AuthTransaction(active:active,folder:dir.appendingPathComponent("transaction"))
            var quit=false, opened=false
            let op=SwitchOperations(activity:{.idle},validateTarget:{$0},stopDesktop:{quit=true},savePrevious:{_ in},verifyWritten:{_ in},reopen:{opened=true},preflightView:{try SharedContinuity.validate($0,checkpoint:cp,state:self.data(["future-format":[:]]))})
            let outcome=SwitchEngine.run(target:b,transaction:tx,operations:op)
            XCTAssertFalse(outcome.targetWritten);XCTAssertFalse(quit);XCTAssertFalse(opened)
            XCTAssertEqual(try PrivateFiles.read(active),a.data);XCTAssertNil(try tx.journal)
        }
    }

    func testStateIsRevalidatedAfterQuitBeforeAnyAuthWrite() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob")
        try h.temp { dir in
            let active=dir.appendingPathComponent("auth.json"), cp=dir.appendingPathComponent("checkpoint.json")
            try PrivateFiles.write(a.data,to:active)
            var state=try self.data(self.fixture(a,b)), quit=false, reopened=false
            let tx=try AuthTransaction(active:active,folder:dir.appendingPathComponent("transaction"))
            let op=SwitchOperations(activity:{.idle},validateTarget:{$0},stopDesktop:{
                quit=true
                state=try self.data([DesktopState.ownerKey:ProjectView.rendererKey(a)!])
            },savePrevious:{_ in},verifyWritten:{_ in},reopen:{reopened=true},prepareProjectView:{source,target in
                try SharedContinuity.validate(source,checkpoint:cp,state:state)
                _ = try ProjectView.proposedState(state,source:source,target:target,codexHome:self.home)
            },preflightView:{try SharedContinuity.validate($0,checkpoint:cp,state:state)})
            let result=SwitchEngine.run(target:b,transaction:tx,operations:op)
            XCTAssertTrue(quit);XCTAssertTrue(reopened);XCTAssertFalse(result.targetWritten)
            XCTAssertEqual(try PrivateFiles.read(active),a.data);XCTAssertNil(try tx.journal)
        }
    }

    func testSwitchHandlesSchemaMigrationDuringReopenAndNextRoundtrip() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob")
        try h.temp { dir in
            let active=dir.appendingPathComponent("auth.json"), cp=dir.appendingPathComponent("checkpoint.json"), state=dir.appendingPathComponent("state.json")
            var old=ProjectViewTests().fixture(a,b);old["projectless-thread-ids"]=["loose"]
            try PrivateFiles.write(a.data,to:active);try PrivateFiles.write(data(old),to:state)
            try SharedContinuity.activated(a,checkpoint:cp,state:PrivateFiles.read(state))
            let tx=try AuthTransaction(active:active,folder:dir.appendingPathComponent("transaction"))
            for target in [b,a] {
                let op=SwitchOperations(activity:{.idle},validateTarget:{$0},stopDesktop:{},savePrevious:{_ in},verifyWritten:{_ in},reopen:{
                    var root=try DesktopState(PrivateFiles.read(state)).root
                    // Fixture simulates the inspected migration when the updated desktop starts.
                    root.removeValue(forKey:ProjectView.stateKey);root[DesktopState.ownerKey]=ProjectView.rendererKey(target)!
                    try PrivateFiles.write(self.data(root),to:state)
                },prepareProjectView:{source,target in
                    try SharedContinuity.validate(source,checkpoint:cp,state:PrivateFiles.read(state))
                    try ProjectView.syncTarget(stateURL:state,source:source,target:target,backupFolder:dir.appendingPathComponent("backups"))
                },preflightView:{try SharedContinuity.validate($0,checkpoint:cp,state:PrivateFiles.read(state))},credentialsChanged:{try SharedContinuity.activated($0,checkpoint:cp,state:PrivateFiles.read(state))},verifyDesktop:{DesktopIdentity.matches($0,auth:try? PrivateFiles.read(active),state:try? PrivateFiles.read(state))})
                let outcome=SwitchEngine.run(target:target,transaction:tx,operations:op)
                XCTAssertTrue(outcome.targetWritten);XCTAssertTrue(outcome.desktopVerified);XCTAssertNil(outcome.message)
            }
            XCTAssertEqual(try JSONDecoder().decode(SharedContinuity.Checkpoint.self,from:PrivateFiles.read(cp)).format,.sharedGlobals)
            XCTAssertEqual(try DesktopState(PrivateFiles.read(state)).root["projectless-thread-ids"] as? [String],["loose"])
        }
    }

    func testDiskVersionRefreshesAndDiagnosticsRetainSchemaWithoutSecrets() throws {
        try AccountCoreTests().temp { dir in
            let app=dir.appendingPathComponent("Fixture.app"), contents=app.appendingPathComponent("Contents")
            try PrivateFiles.directory(contents)
            for version in ["old","new"] {
                try PrivateFiles.write(PropertyListSerialization.data(fromPropertyList:["CFBundleShortVersionString":version],format:.xml,options:0),to:contents.appendingPathComponent("Info.plist"))
                XCTAssertEqual(DesktopState.diskVersion(app),version)
            }
            let log=dir.appendingPathComponent("trace.json"), trace=SwitchDiagnostics(url:log,desktopVersion:DesktopState.diskVersion(app))
            trace.context("preflight",app:app,state:try data([DesktopState.ownerKey:"signed-out"]))
            let records=try JSONDecoder().decode([SwitchDiagnostics.Attempt].self,from:PrivateFiles.read(log))
            XCTAssertEqual(records.last?.contexts?.last?.stateFormat,DesktopState.Format.sharedGlobals.rawValue)
            XCTAssertEqual(records.last?.contexts?.last?.desktopVersion,"new")
            let usage=dir.appendingPathComponent("usage.json")
            for _ in 0..<45 { UsageDiagnostics.record(AccountError.message("secret-token@example.invalid"),profileIndex:0,active:false,url:usage) }
            let entries=try JSONDecoder().decode([UsageDiagnostics.Entry].self,from:PrivateFiles.read(usage))
            XCTAssertEqual(entries.count,40);XCTAssertEqual(entries.last?.category,"local-service-error")
            XCTAssertFalse(String(decoding:try PrivateFiles.read(usage),as:UTF8.self).contains("secret-token"))
            XCTAssertEqual(UsageDiagnostics.category(AccountError.authenticationRejected),"authentication-rejected")
        }
    }
}
