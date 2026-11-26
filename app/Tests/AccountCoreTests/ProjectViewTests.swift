import XCTest
@testable import AccountCore

final class ProjectViewTests: XCTestCase {
    func fixture(_ a: Credential, _ b: Credential, targetGlobals: [String: Any] = [:]) -> [String: Any] {
        ["local-projects": ["p1": ["name": "Local", "rootPaths": ["/tmp/project"]]],
         "thread-project-assignments": ["chat": "p1"], "project-order": ["p1"],
         "thread-writable-roots": ["chat": ["/private/permission"]], "queued-follow-ups": ["do-not-copy"],
         "electron-persisted-atom-state": ["secret-cache": "A"],
         ProjectView.stateKey: ["owner": ProjectView.rendererKey(a)!, "inactive": [
            ProjectView.rendererKey(b)!: ["atoms": ["own-preference": "B"], "globals": targetGlobals]]]]
    }
    func testOnlyEmptyTargetGetsLocalMetadataNotAtomsPermissionsOrQueuedTasks() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        let source = fixture(a, b, targetGlobals: ["queued-follow-ups": ["B-own-work"]])
        let proposed = try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject: source), source: a, target: b))
        let root = try JSONSerialization.jsonObject(with: proposed) as! [String: Any]
        let state = root[ProjectView.stateKey] as! [String: Any]
        let destination = (state["inactive"] as! [String: Any])[ProjectView.rendererKey(b)!] as! [String: Any]
        let globals = destination["globals"] as! [String: Any]
        XCTAssertEqual((globals["local-projects"] as? [String: Any])?.count, 1)
        XCTAssertEqual(globals["thread-project-assignments"] as? [String: String], ["chat": "p1"])
        XCTAssertEqual(globals["queued-follow-ups"] as? [String], ["B-own-work"])
        XCTAssertNil(globals["thread-writable-roots"])
        XCTAssertEqual(destination["atoms"] as? [String: String], ["own-preference": "B"])
        XCTAssertEqual(state["owner"] as? String, ProjectView.rendererKey(a))
        XCTAssertEqual(root["electron-persisted-atom-state"] as? [String: String], ["secret-cache": "A"])
    }
    func targetGlobals(_ result: Data, _ b: Credential) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let state = root[ProjectView.stateKey] as! [String: Any]
        return ((state["inactive"] as! [String: Any])[ProjectView.rendererKey(b)!] as! [String: Any])["globals"] as! [String: Any]
    }
    func testActiveCatalogReplacesTargetIncludingDeletedProjects() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        var root = fixture(a,b,targetGlobals: ["local-projects": [
            "p1": ["name":"Old", "rootPaths":["/tmp/project"], "updatedAt":1],
            "onlyB": ["name":"Only B", "rootPaths":[], "updatedAt":3]], "project-order":["onlyB", "p1"],
            "thread-project-assignments":["onlyBChat":"onlyB"]])
        root["local-projects"] = ["p1":["name":"Renamed", "rootPaths":["/tmp/project"], "updatedAt":2],
                                 "new":["name":"New A", "rootPaths":[], "updatedAt":4]]
        root["project-order"] = ["p1","new"]
        let g = try targetGlobals(XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b)),b)
        let projects = g["local-projects"] as! [String:[String:Any]]
        XCTAssertEqual(projects.count,2); XCTAssertEqual(projects["p1"]?["name"] as? String,"Renamed")
        XCTAssertEqual(g["project-order"] as? [String],["p1","new"])
        XCTAssertEqual(g["thread-project-assignments"] as? [String:String],["chat":"p1"])
    }
    func testActiveViewWinsOverTargetSnapshotAndCloudBackingDoesNotCrossAccounts() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        var root = fixture(a,b,targetGlobals:["local-projects":["p1":["name":"Newer B","rootPaths":["/tmp/project"],"updatedAt":5,"chatGptBacking":["accountId":"B"]]]])
        root["local-projects"] = ["p1":["name":"Stale A","rootPaths":["/tmp/project"],"updatedAt":1,"chatGptBacking":["accountId":"A"]], "new":["name":"New","rootPaths":[],"chatGptBacking":["accountId":"A"],"chatGptBackingCreation":["accountId":"A"]]]
        let g = try targetGlobals(XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b)),b)
        let projects = g["local-projects"] as! [String:[String:Any]]
        XCTAssertEqual(projects["p1"]?["name"] as? String,"Stale A")
        XCTAssertEqual(projects["p1"]?["chatGptBacking"] as? [String:String],["accountId":"B"])
        XCTAssertNil(projects["new"]?["chatGptBacking"]); XCTAssertNil(projects["new"]?["chatGptBackingCreation"])
    }
    func testUnknownTargetShapeFailsBeforeMutation() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        let g: [String:Any] = ["local-projects":["other":["name":"Unknown"]]]
        XCTAssertThrowsError(try ProjectView.proposedState(JSONSerialization.data(withJSONObject:fixture(a,b,targetGlobals:g)),source:a,target:b))
    }
    func testInstalledStructuredAssignmentsAndRemoteIsolation() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        var root = fixture(a,b)
        root["thread-project-assignments"] = ["chat":["projectKind":"local","projectId":"p1"],"remote":["projectKind":"remote","projectId":"remote1"],"cloud":["projectKind":"local","projectId":"p1","projectOrigin":"chatgpt"]]
        let output = try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b))
        let assignments = try targetGlobals(output,b)["thread-project-assignments"] as! [String:[String:String]]
        XCTAssertEqual(assignments,["chat":["projectKind":"local","projectId":"p1"]])
    }
    func testRoundTripRetainsNewProjectAndBRename() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        let first = try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:fixture(a,b)),source:a,target:b))
        var globalsB = try targetGlobals(first,b)
        globalsB["local-projects"] = ["p1":["name":"Renamed on B","rootPaths":["/tmp/project"],"updatedAt":100],"p2":["name":"Created on B","rootPaths":[],"updatedAt":100]]
        var rootB = globalsB
        rootB[ProjectView.stateKey] = ["owner":ProjectView.rendererKey(b)!,"inactive":[ProjectView.rendererKey(a)!:["atoms":[:],"globals":fixture(a,b).filter { ProjectView.sharedKeys.contains($0.key) }]]]
        let result = try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:rootB),source:b,target:a))
        let projects = try targetGlobals(result,a)["local-projects"] as! [String:[String:Any]]
        XCTAssertEqual(projects.count,2); XCTAssertEqual(projects["p1"]?["name"] as? String,"Renamed on B")
        XCTAssertNil(try ProjectView.proposedState(result,source:b,target:a))
    }
    func testWrongOwnerOrUnknownProjectShapeMakesNoChange() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        let data = try JSONSerialization.data(withJSONObject: fixture(a,b))
        XCTAssertThrowsError(try ProjectView.proposedState(data, source:b,target:a))
        var state = fixture(a,b); state["local-projects"] = ["p": ["name": "Remote", "rootPaths": ["ssh://host/path"]]]
        XCTAssertThrowsError(try ProjectView.proposedState(JSONSerialization.data(withJSONObject: state), source:a,target:b))
    }
    func testDeletingLastProjectClearsReferencesWithoutTouchingChatsOrOtherAccountData() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        let target: [String:Any] = [
            "local-projects":["p1":["name":"Deleted","rootPaths":[]]],
            "project-order":["p1"], "project-appearances":["p1":["color":"red"]],
            "sidebar-project-thread-orders":["p1":["threadIds":["chat"]]],
            "selected-project":["type":"local","projectId":"p1"],
            "thread-project-assignments":["chat":["projectKind":"local","projectId":"p1"],"remoteChat":["projectKind":"remote","projectId":"remote"]],
            "thread-project-membership-host-ids":["chat":"local","remoteChat":"remote-host"],
            "app-server-project-id-by-legacy-project-id-by-host":["local":["p1":"server-id"],"remote-host":["remote":"remote-id"]],
            "queued-follow-ups":["target-work"], "thread-writable-roots":["chat":["/permission"]]]
        var root = fixture(a,b,targetGlobals:target)
        root["local-projects"] = [String:Any]()
        // A stale source association must not resurrect the deleted project.
        root["chat-history-sentinel"] = ["chat":["original","new round"]]
        let data = try JSONSerialization.data(withJSONObject:root)
        let output = try XCTUnwrap(ProjectView.proposedState(data,source:a,target:b))
        let g = try targetGlobals(output,b)
        XCTAssertTrue((g["local-projects"] as! [String:Any]).isEmpty)
        XCTAssertTrue((g["project-order"] as! [String]).isEmpty)
        XCTAssertTrue((g["project-appearances"] as! [String:Any]).isEmpty)
        XCTAssertTrue((g["sidebar-project-thread-orders"] as! [String:Any]).isEmpty)
        XCTAssertNil(g["selected-project"])
        XCTAssertEqual(g["thread-project-assignments"] as? [String:[String:String]],["remoteChat":["projectKind":"remote","projectId":"remote"]])
        XCTAssertEqual(g["thread-project-membership-host-ids"] as? [String:String],["remoteChat":"remote-host"])
        XCTAssertEqual(g["queued-follow-ups"] as? [String],["target-work"])
        XCTAssertEqual(g["thread-writable-roots"] as? [String:[String]],["chat":["/permission"]])
        let parsed = try JSONSerialization.jsonObject(with:output) as! [String:Any]
        XCTAssertEqual(parsed["chat-history-sentinel"] as? [String:[String]],["chat":["original","new round"]])
        XCTAssertNil(try ProjectView.proposedState(output,source:a,target:b))
    }
    func testMissingCatalogIsNotInterpretedAsDeleteAll() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        var root = fixture(a,b); root.removeValue(forKey:"local-projects")
        XCTAssertThrowsError(try ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b))
        root["local-projects"] = NSNull()
        XCTAssertThrowsError(try ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b))
    }
    func testDeletionDoesNotReturnWhenSwitchingBack() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        let first = try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:fixture(a,b)),source:a,target:b))
        var bGlobals = try targetGlobals(first,b)
        bGlobals["local-projects"] = [String:Any]()
        var bRoot = bGlobals
        bRoot[ProjectView.stateKey] = ["owner":ProjectView.rendererKey(b)!,"inactive":[ProjectView.rendererKey(a)!:["atoms":[:],"globals":fixture(a,b).filter { ProjectView.sharedKeys.contains($0.key) }]]]
        let back = try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:bRoot),source:b,target:a))
        let aGlobals = try targetGlobals(back,a)
        XCTAssertTrue((aGlobals["local-projects"] as! [String:Any]).isEmpty)
        var aRoot = aGlobals
        aRoot[ProjectView.stateKey] = ["owner":ProjectView.rendererKey(a)!,"inactive":[ProjectView.rendererKey(b)!:["atoms":[:],"globals":bGlobals]]]
        if let again = try ProjectView.proposedState(JSONSerialization.data(withJSONObject:aRoot),source:a,target:b) {
            XCTAssertTrue((try targetGlobals(again,b)["local-projects"] as! [String:Any]).isEmpty)
        }
    }
    func testBackupContainsExactPreimageAndSeedingIsIdempotent() throws {
        let h = AccountCoreTests(), a = try h.credential(), b = try h.credential("bob")
        try h.temp { folder in
            let file = folder.appendingPathComponent("state.json"), backups = folder.appendingPathComponent("backups")
            let before = try JSONSerialization.data(withJSONObject: fixture(a,b))
            try PrivateFiles.write(before,to:file)
            try ProjectView.syncTarget(stateURL:file,source:a,target:b,backupFolder:backups)
            let entries = try FileManager.default.contentsOfDirectory(at:backups,includingPropertiesForKeys:nil)
            XCTAssertEqual(entries.count,1); XCTAssertEqual(try PrivateFiles.read(entries[0]),before)
            let after = try PrivateFiles.read(file)
            try ProjectView.syncTarget(stateURL:file,source:a,target:b,backupFolder:backups)
            XCTAssertEqual(try PrivateFiles.read(file),after)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:backups.path).count,1)
        }
    }

    func testActualLocalHomeKeyAndProjectlessMetadataAreSharedWithoutRemoteOrPermissionCopy() throws {
        let h=AccountCoreTests(),a=try h.credential(),b=try h.credential("bob")
        let home=URL(fileURLWithPath:"/tmp/example-home"), host="local:/tmp/example-home"
        var root=fixture(a,b,targetGlobals:["app-server-project-id-by-legacy-project-id-by-host":["remote":["r":"preserve"]],"thread-project-membership-host-ids":["remote-chat":"remote"],"projectless-thread-ids":["remote-chat","old-local"],"thread-workspace-root-hints":["remote-chat":"/remote","old-local":"/old"]])
        root["app-server-project-id-by-legacy-project-id-by-host"]=[host:["p1":"server-p1","deleted":"old"],"remote":["r":"do-not-copy"]]
        root["app-server-projects-migration-by-host"]=[host:["version":1,"projectsMigrated":true,"threadAssignmentsMigrated":false,"pendingThreadAssignmentIds":["chat"]]]
        root["projectless-thread-ids"]=["free"]
        root["thread-project-membership-host-ids"]=["free":"local"]
        root["thread-workspace-root-hints"]=["free":"/work/free"]
        root["thread-projectless-output-directories"]=["free":"/outputs/free"]
        let result=try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b,codexHome:home))
        let g=try targetGlobals(result,b)
        XCTAssertEqual(g["app-server-project-id-by-legacy-project-id-by-host"] as? [String:[String:String]],[host:["p1":"server-p1"],"remote":["r":"preserve"]])
        XCTAssertNotNil((g["app-server-projects-migration-by-host"] as? [String:Any])?[host])
        XCTAssertEqual(g["projectless-thread-ids"] as? [String],["remote-chat","free"])
        XCTAssertEqual(g["thread-workspace-root-hints"] as? [String:String],["remote-chat":"/remote","free":"/work/free"])
        XCTAssertEqual(g["thread-projectless-output-directories"] as? [String:String],["free":"/outputs/free"])
        XCTAssertNil(g["thread-writable-roots"])
    }
    func testMalformedProjectlessAndMigrationStateFailClosed() throws {
        let h=AccountCoreTests(),a=try h.credential(),b=try h.credential("bob")
        var root=fixture(a,b);root["projectless-thread-ids"]="broken"
        XCTAssertThrowsError(try ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b))
        root.removeValue(forKey:"projectless-thread-ids")
        root["app-server-projects-migration-by-host"]=["local":["version":99]]
        XCTAssertThrowsError(try ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b))
    }
    func testDeletedProjectChatBecomesProjectlessAndCanMoveBackIntoProject() throws {
        let h=AccountCoreTests(),a=try h.credential(),b=try h.credential("bob")
        var root=fixture(a,b);root["local-projects"]=[String:Any]()
        let detached=try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b))
        XCTAssertEqual(try targetGlobals(detached,b)["projectless-thread-ids"] as? [String],["chat"])
        root=fixture(a,b,targetGlobals:try targetGlobals(detached,b));root["projectless-thread-ids"]=["chat"]
        let assigned=try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b))
        XCTAssertEqual(try targetGlobals(assigned,b)["projectless-thread-ids"] as? [String],[])
    }

    func testDeletedProjectWithRemovedSourceAssignmentStillDetachesTargetChat() throws {
        let h=AccountCoreTests(),a=try h.credential(),b=try h.credential("bob")
        var root=fixture(a,b,targetGlobals:["local-projects":["p1":["name":"Deleted","rootPaths":[]]],"thread-project-assignments":["chat":"p1"]])
        root["local-projects"]=[String:Any]();root["thread-project-assignments"]=[String:Any]()
        let result=try XCTUnwrap(ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:a,target:b))
        XCTAssertEqual(try targetGlobals(result,b)["projectless-thread-ids"] as? [String],["chat"])
    }
}
