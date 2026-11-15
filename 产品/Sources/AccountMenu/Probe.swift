import Foundation
import AccountCore
import CryptoKit

enum Probe {
    /// Production adapters, real state read once, proposed changes kept in memory.
    /// No services, login, checkpoint upgrade, or application lifecycle operations.
    static func sharedStateReadOnly() -> Int32 {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let stateURL = home.appendingPathComponent(".codex-global-state.json"), authURL = home.appendingPathComponent("auth.json")
            let warehouse = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccounts")
            let before = try PrivateFiles.read(stateURL), auth = try PrivateFiles.read(authURL), source = try Credential(auth)
            let state = try DesktopState(before), checkpoint = warehouse.appendingPathComponent("shared-view-checkpoint.json")
            let cpBefore = try? PrivateFiles.read(checkpoint)
            try SharedContinuity.validate(source, checkpoint: checkpoint, state: before)
            let matches = DesktopIdentity.matches(source, auth: auth, state: before)
            let profiles = try JSONDecoder().decode([Profile].self, from: PrivateFiles.read(warehouse.appendingPathComponent("accounts.json")))
            var targets = 0, onlyAllowedChanges = true, changedHints = 0
            for profile in profiles where !profile.identity.matches(source.identity) {
                let target = try Credential(PrivateFiles.read(warehouse.appendingPathComponent("profiles/\(profile.id).json")))
                let after = try ProjectView.proposedState(before, source: source, target: target, codexHome: home) ?? before
                targets += 1
                if state.format == .sharedGlobals {
                    let next = try DesktopState(after).root
                    let allowed = Set(DesktopState.hintKeys.map { DesktopState.hintKey($0, owner: ProjectView.rendererKey(target)!) })
                    for key in Set(state.root.keys).union(next.keys) {
                        let same = NSDictionary(dictionary:["value":state.root[key] ?? NSNull()]).isEqual(to:["value":next[key] ?? NSNull()])
                        if !same { if allowed.contains(key) { changedHints += 1 } else { onlyAllowedChanges = false } }
                    }
                }
            }
            let unchanged = try PrivateFiles.read(stateURL) == before && PrivateFiles.read(authURL) == auth && (try? PrivateFiles.read(checkpoint)) == cpBefore
            print("schema=\(state.format.rawValue) identity_matches=\(matches) preflight=passed targets_checked=\(targets)")
            print("only_allowed_hint_changes=\(onlyAllowedChanges) hint_fields_to_update=\(changedHints) real_files_unchanged=\(unchanged)")
            print("network_requests=0 auth_writes=0 state_writes=0 checkpoint_writes=0 lifecycle_operations=0")
            return matches && onlyAllowedChanges && unchanged ? 0 : 1
        } catch { print("shared_state_probe=failed_without_writes reason=\(error.localizedDescription)"); return 1 }
    }
    static func projectSyncReadOnly() -> Int32 {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let stateURL = home.appendingPathComponent(".codex/.codex-global-state.json")
            let authURL = home.appendingPathComponent(".codex/auth.json")
            let before = try PrivateFiles.read(stateURL), authBefore = try PrivateFiles.read(authURL)
            if try DesktopState(before).format == .sharedGlobals { return sharedStateReadOnly() }
            let source = try Credential(authBefore)
            let warehouse = home.appendingPathComponent("Library/Application Support/CodexAccounts")
            let profiles = try JSONDecoder().decode([Profile].self, from: PrivateFiles.read(warehouse.appendingPathComponent("accounts.json")))
            let candidates = try profiles.map { try Credential(PrivateFiles.read(warehouse.appendingPathComponent("profiles/\($0.id).json"))) }
            guard let target = candidates.first(where: { !$0.identity.matches(source.identity) }),
                  let targetKey = ProjectView.rendererKey(target) else { print("sync_probe=no_other_account"); return 1 }
            var root = try JSONSerialization.jsonObject(with: before) as! [String: Any]
            guard var projects = root["local-projects"] as? [String: [String: Any]], let renamed = projects.keys.sorted().first else { print("sync_probe=no_projects_to_rename"); return 1 }
            projects[renamed]!["name"] = "IN_MEMORY_RENAME_PROBE"
            projects[renamed]!["updatedAt"] = Date().timeIntervalSince1970 * 1000 + 60000
            let newID = "codex-accounts-in-memory-project-probe"
            projects[newID] = ["id":newID,"name":"IN_MEMORY_NEW_PROJECT","rootPaths":[],"createdAt":0,"updatedAt":0]
            root["local-projects"] = projects
            let oldState = root[ProjectView.stateKey] as! [String: Any]
            let oldTarget = (oldState["inactive"] as! [String: Any])[targetKey] as? [String: Any] ?? [:]
            let output = try ProjectView.proposedState(JSONSerialization.data(withJSONObject:root),source:source,target:target)!
            let result = try JSONSerialization.jsonObject(with:output) as! [String: Any]
            let nextState = result[ProjectView.stateKey] as! [String: Any]
            let nextTarget = (nextState["inactive"] as! [String: Any])[targetKey] as! [String: Any]
            let nextGlobals = nextTarget["globals"] as! [String: Any]
            let next = nextGlobals["local-projects"] as! [String: [String: Any]]
            let added = next[newID] != nil
            let renameOK = next[renamed]?["name"] as? String == "IN_MEMORY_RENAME_PROBE"
            let mirrored = Set(next.keys) == Set(projects.keys)
            var deletionRoot = root
            deletionRoot["local-projects"] = [String: Any]()
            let deletedData = try ProjectView.proposedState(JSONSerialization.data(withJSONObject:deletionRoot),source:source,target:target)!
            let deletedRoot = try JSONSerialization.jsonObject(with:deletedData) as! [String:Any]
            let deletedState = deletedRoot[ProjectView.stateKey] as! [String:Any]
            let deletedTarget = (deletedState["inactive"] as! [String:Any])[targetKey] as! [String:Any]
            let deletedGlobals = deletedTarget["globals"] as! [String:Any]
            let cleared = (deletedGlobals["local-projects"] as! [String:Any]).isEmpty
            let atoms = NSDictionary(dictionary: nextTarget["atoms"] as? [String:Any] ?? [:]).isEqual(to:oldTarget["atoms"] as? [String:Any] ?? [:])
            let unchanged = try PrivateFiles.read(stateURL) == before && PrivateFiles.read(authURL) == authBefore
            print("memory_add=\(added) memory_rename=\(renameOK) target_catalog_matches=\(mirrored) memory_delete_all=\(cleared) target_atoms_preserved=\(atoms) real_files_unchanged=\(unchanged)")
            return added && renameOK && mirrored && cleared && atoms && unchanged ? 0 : 1
        } catch { print("sync_probe=failed_without_writes"); return 1 }
    }

    static func projectViewReadOnly() -> Int32 {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let stateURL = home.appendingPathComponent(".codex/.codex-global-state.json")
            let authURL = home.appendingPathComponent(".codex/auth.json")
            let before = try PrivateFiles.read(stateURL), authBefore = try PrivateFiles.read(authURL)
            if try DesktopState(before).format == .sharedGlobals { return sharedStateReadOnly() }
            let target = try Credential(authBefore)
            let root = try JSONSerialization.jsonObject(with: before) as! [String: Any]
            let state = root[ProjectView.stateKey] as! [String: Any]
            var inactive = state["inactive"] as! [String: Any]
            let warehouse = home.appendingPathComponent("Library/Application Support/CodexAccounts")
            let profiles = try JSONDecoder().decode([Profile].self, from: PrivateFiles.read(warehouse.appendingPathComponent("accounts.json")))
            var source: Credential?
            for profile in profiles {
                let c = try Credential(PrivateFiles.read(warehouse.appendingPathComponent("profiles/\(profile.id).json")))
                if let key = ProjectView.rendererKey(c), let snapshot = inactive[key] as? [String: Any],
                   let g = snapshot["globals"] as? [String: Any], let p = g["local-projects"] as? [String: Any], !p.isEmpty { source = c; break }
            }
            guard let source, let sourceKey = ProjectView.rendererKey(source), let targetKey = ProjectView.rendererKey(target),
                  state["owner"] as? String == targetKey, let snapshot = inactive[sourceKey] as? [String: Any],
                  let sourceGlobals = snapshot["globals"] as? [String: Any] else { print("project_dry_run=not_applicable"); return 1 }
            // Simulate the next B -> A transition IN MEMORY, then apply the proposed A -> B fix.
            var simulated = root
            var targetGlobals: [String: Any] = [:]
            for key in ProjectView.sharedKeys + ["queued-follow-ups"] {
                if let value = root[key] { targetGlobals[key] = value }
                simulated.removeValue(forKey:key)
                if let value = sourceGlobals[key] { simulated[key] = value }
            }
            inactive.removeValue(forKey: sourceKey)
            inactive[targetKey] = ["atoms": root["electron-persisted-atom-state"] ?? [:], "globals": targetGlobals]
            simulated[ProjectView.stateKey] = ["owner":sourceKey,"inactive":inactive]
            let simulatedData = try JSONSerialization.data(withJSONObject:simulated)
            guard let result = try ProjectView.proposedState(simulatedData,source:source,target:target) else { print("project_dry_run=shape_not_supported"); return 1 }
            let updated = try JSONSerialization.jsonObject(with:result) as! [String: Any]
            let targetSnapshot = ((updated[ProjectView.stateKey] as! [String: Any])["inactive"] as! [String: Any])[targetKey] as! [String: Any]
            let globals = targetSnapshot["globals"] as! [String: Any]
            let count = (globals["local-projects"] as? [String: Any])?.count ?? 0
            let unchanged = try PrivateFiles.read(stateURL) == before && PrivateFiles.read(authURL) == authBefore
            let atomsPreserved = NSDictionary(dictionary: targetSnapshot["atoms"] as! [String: Any]).isEqual(to:root["electron-persisted-atom-state"] as! [String: Any])
            print("proposed_target_project_count=\(count)")
            print("target_account_atoms_preserved=\(atomsPreserved)")
            print("real_state_and_auth_unchanged=\(unchanged)")
            return count == 2 && unchanged && atomsPreserved ? 0 : 1
        } catch { print("project_dry_run=failed"); return 1 }
    }
    // Explicit developer-only check. Reads A, strips its refresh token in a private temporary copy,
    // makes one usage query, prints only booleans, and removes that copy. Does not start the UI.
    static func run() -> Int32 {
        let active = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("account-readonly-probe-\(UUID())")
        var before: Data?
        var success = false
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let original = try PrivateFiles.read(active); before = original
            let credential = try Credential(original)
            let location = try ClientLocation.discover()
            let service = try AccountService(cli: location.cli, runtime: tmp)
            let result = try service.query(credential, active: true)
            success = result.usage.accountId == credential.identity.workspace
        } catch { print("usage_query_success=false (\(error.localizedDescription))") }
        let unchanged = before != nil && (try? PrivateFiles.read(active)) == before
        print("usage_query_success=\(success)")
        print("active_auth_unchanged=\(unchanged)")
        print("model_requests=0")
        return success && unchanged ? 0 : 1
    }
}
