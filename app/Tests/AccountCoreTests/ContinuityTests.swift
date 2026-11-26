import XCTest
@testable import AccountCore

final class ContinuityTests: XCTestCase {
    func testExternalLoginBlocksAndExplicitCheckpointActivationAllowsNextOwner() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob")
        try h.temp { folder in
            let file=folder.appendingPathComponent("checkpoint.json")
            XCTAssertThrowsError(try SharedContinuity.validate(a,checkpoint:file))
            try SharedContinuity.activated(a,checkpoint:file)
            XCTAssertNoThrow(try SharedContinuity.validate(a,checkpoint:file))
            XCTAssertThrowsError(try SharedContinuity.validate(b,checkpoint:file))
            try SharedContinuity.activated(b,checkpoint:file)
            XCTAssertNoThrow(try SharedContinuity.validate(b,checkpoint:file))
        }
    }
    func testRepairKeepsBothCatalogsAndProjectlessWhileNormalSyncStillDeletes() throws {
        let h=AccountCoreTests(), a=try h.credential(), b=try h.credential("bob"), helper=ProjectViewTests()
        let root=helper.fixture(a,b,targetGlobals:["local-projects":["onlyB":["name":"Saved","rootPaths":[]]],"projectless-thread-ids":["loose"],"thread-workspace-root-hints":["loose":"/tmp/work"]])
        let data=try JSONSerialization.data(withJSONObject:root),home=URL(fileURLWithPath:"/tmp/home")
        let plan=try SharedContinuity.prepareRepair(data,active:a,accounts:[a,b],home:home)
        XCTAssertEqual(plan.projectNames,["Local","Saved"])
        let result=try SharedContinuity.repairState(data,plan:plan,active:a,accounts:[a,b],home:home)
        let g=try helper.targetGlobals(result,b)
        XCTAssertEqual(Set((g["local-projects"] as! [String:Any]).keys),["p1","onlyB"])
        XCTAssertEqual(g["projectless-thread-ids"] as? [String],["loose"])
        let parsed=try JSONSerialization.jsonObject(with:result) as! [String:Any]
        XCTAssertNil(parsed["thread-writable-roots"] as? String)
        XCTAssertEqual(parsed["electron-persisted-atom-state"] as? [String:String],["secret-cache":"A"])
        var next=parsed; next["local-projects"]=[String:Any]()
        let deleted=try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:next),source:a,target:b,codexHome:home))
        XCTAssertTrue((try helper.targetGlobals(deleted,b)["local-projects"] as! [String:Any]).isEmpty)
    }
    func testRepairRejectsChangedSharedDataButIgnoresWindowLayoutChanges() throws {
        let h=AccountCoreTests(),a=try h.credential(),b=try h.credential("bob"), helper=ProjectViewTests()
        var root=helper.fixture(a,b);let home=URL(fileURLWithPath:"/tmp/home")
        let data=try JSONSerialization.data(withJSONObject:root)
        let plan=try SharedContinuity.prepareRepair(data,active:a,accounts:[a,b],home:home)
        root["electron-main-window-bounds"]=["x":500]
        XCTAssertNoThrow(try SharedContinuity.repairState(JSONSerialization.data(withJSONObject:root),plan:plan,active:a,accounts:[a,b],home:home))
        root["projectless-thread-ids"]=["new"]
        XCTAssertThrowsError(try SharedContinuity.repairState(JSONSerialization.data(withJSONObject:root),plan:plan,active:a,accounts:[a,b],home:home))
    }
    func testCurrentMoveOutOfProjectWinsDuringExplicitRepair() throws {
        let h=AccountCoreTests(),a=try h.credential(),b=try h.credential("bob"),helper=ProjectViewTests()
        var root=helper.fixture(a,b,targetGlobals:["local-projects":["p1":["name":"Old","rootPaths":[]]],"thread-project-assignments":["moved":"p1"]])
        root["projectless-thread-ids"]=["moved"]
        let plan=try SharedContinuity.prepareRepair(JSONSerialization.data(withJSONObject:root),active:a,accounts:[a,b],home:URL(fileURLWithPath:"/tmp/home"))
        let g=try JSONSerialization.jsonObject(with:plan.globals) as! [String:Any]
        XCTAssertNil((g["thread-project-assignments"] as? [String:Any])?["moved"])
        XCTAssertEqual(g["projectless-thread-ids"] as? [String],["moved"])
    }

    func testMissingPreviouslySeededListIsNotAnIntentionalDelete() throws {
        let h=AccountCoreTests(),a=try h.credential(),b=try h.credential("bob")
        var root=ProjectViewTests().fixture(a,b); root["projectless-thread-ids"]=["free"]
        try h.temp { folder in
            let checkpoint=folder.appendingPathComponent("checkpoint.json")
            try SharedContinuity.activated(a,checkpoint:checkpoint,state:JSONSerialization.data(withJSONObject:root))
            root.removeValue(forKey:"projectless-thread-ids")
            XCTAssertThrowsError(try SharedContinuity.validate(a,checkpoint:checkpoint,state:JSONSerialization.data(withJSONObject:root)))
            root["projectless-thread-ids"]=[String]()
            XCTAssertNoThrow(try SharedContinuity.validate(a,checkpoint:checkpoint,state:JSONSerialization.data(withJSONObject:root)))
        }
    }
    func testDiagnosticsAreBoundedAndRecordSeparateOutcomes() throws {
        try AccountCoreTests().temp { folder in
            let url=folder.appendingPathComponent("diagnostics.json")
            for _ in 0..<25 {
                let trace=SwitchDiagnostics(url:url,desktopVersion:"fixture")
                trace.stage("正在退出 Codex…")
                trace.finish(SwitchOutcome(targetWritten:true,identityVerified:true,needsReopen:false,message:nil,desktopVerified:false))
            }
            let data=try PrivateFiles.read(url)
            let records=try JSONDecoder().decode([SwitchDiagnostics.Attempt].self,from:data)
            XCTAssertEqual(records.count,20)
            XCTAssertEqual(records.last?.credentialVerified,true)
            XCTAssertEqual(records.last?.desktopVerified,false)
            XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("access_token"))
        }
    }

    func testUndoPreservesUnrelatedUIAndRejectsNewWorkOrDifferentIdentity() throws {
        let h=AccountCoreTests(),a=try h.credential(),b=try h.credential("bob"),helper=ProjectViewTests(),home=URL(fileURLWithPath:"/tmp/home")
        let before=try JSONSerialization.data(withJSONObject:helper.fixture(a,b,targetGlobals:["local-projects":["extra":["name":"Saved","rootPaths":[]]]]))
        let plan=try SharedContinuity.prepareRepair(before,active:a,accounts:[a,b],home:home)
        let after=try SharedContinuity.repairState(before,plan:plan,active:a,accounts:[a,b],home:home)
        let digest=try SharedContinuity.digest(after)
        var live=try JSONSerialization.jsonObject(with:after) as! [String:Any]
        live["electron-persisted-atom-state"]=["new-draft":"must survive"]
        let liveData=try JSONSerialization.data(withJSONObject:live)
        let undone=try SharedContinuity.undoRepair(current:liveData,before:before,expectedAfterDigest:digest,active:a)
        XCTAssertEqual(try SharedContinuity.digest(undone),try SharedContinuity.digest(before))
        let result=try JSONSerialization.jsonObject(with:undone) as! [String:Any]
        XCTAssertEqual(result["electron-persisted-atom-state"] as? [String:String],["new-draft":"must survive"])
        XCTAssertThrowsError(try SharedContinuity.undoRepair(current:liveData,before:before,expectedAfterDigest:digest,active:b))
        live["projectless-thread-ids"]=["newly-created-chat"]
        XCTAssertThrowsError(try SharedContinuity.undoRepair(current:JSONSerialization.data(withJSONObject:live),before:before,expectedAfterDigest:digest,active:a))
    }
}
