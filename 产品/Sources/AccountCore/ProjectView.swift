import Foundation
import CryptoKit

/// Compatibility adapters for the inspected snapshot and shared-global stores.
/// Mirrors the shared local project view after verified desktop exit.
/// Never copies account atoms, execution permissions, cloud backing fields, or queued work.
public enum ProjectView {
    public static let stateKey = "electron-account-renderer-state-v1"
    public static let sharedKeys = ["local-projects", "app-server-project-id-by-legacy-project-id-by-host",
        "app-server-projects-migration-by-host", "project-appearances", "sidebar-project-thread-orders",
        "thread-project-assignments", "thread-project-membership-host-ids", "project-order",
        "projectless-thread-ids", "thread-workspace-root-hints", "thread-projectless-output-directories"]

    public static func rendererKey(_ credential: Credential) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: credential.data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any], let token = tokens["id_token"] as? String,
              let claims = Credential.claims(token), let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let user = auth["chatgpt_user_id"] as? String, !user.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: [user, credential.identity.workspace], options: [.withoutEscapingSlashes]) else { return nil }
        return SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
    }
    /// The active account's validated local catalog is the shared authoritative view.
    /// Absence is not an empty catalog. Never guess deletion from unavailable state.
    public static func proposedState(_ data: Data, source: Credential, target: Credential, codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) throws -> Data? {
        let desktop = try DesktopState(data)
        if desktop.format == .sharedGlobals { return try desktop.proposedHints(source: source, target: target, home: codexHome) }
        guard let sourceKey = rendererKey(source), let targetKey = rendererKey(target), sourceKey != targetKey,
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var state = root[stateKey] as? [String: Any], state["owner"] as? String == sourceKey,
              var inactive = state["inactive"] as? [String: Any], root["local-projects"] != nil else {
            throw AccountError.message("无法确认当前账号的完整项目清单，未同步或切换。")
        }
        var destination: [String: Any]
        if let existing = inactive[targetKey] {
            guard let snapshot = existing as? [String: Any], snapshot["atoms"] is [String: Any], snapshot["globals"] is [String: Any] else {
                throw AccountError.message("目标项目快照格式无法识别，未修改资料。")
            }
            destination = snapshot
        } else { destination = ["atoms": [String: Any](), "globals": [String: Any]()] }
        var globals = destination["globals"] as! [String: Any]
        let incoming = try catalog(root["local-projects"])
        let previous = try catalog(globals["local-projects"])
        let ids = Set(incoming.keys), oldIDs = Set(previous.keys)
        var projects: [String: [String: Any]] = [:]
        for (id, project) in incoming {
            var record = previous[id] ?? [:]
            for key in ["id", "name", "rootPaths", "createdAt", "updatedAt"] {
                if let value = project[key] { record[key] = value } else { record.removeValue(forKey:key) }
            }
            projects[id] = record
        }
        globals["local-projects"] = projects
        // Project-keyed metadata: replace local entries, retaining unrelated target remote entries.
        for key in ["project-appearances", "sidebar-project-thread-orders"] {
            let sourceValues = try dictionary(root[key]), targetValues = try dictionary(globals[key])
            var values = targetValues.filter { !oldIDs.contains($0.key) && !ids.contains($0.key) }
            for (id, value) in sourceValues where ids.contains(id) { values[id] = value }
            if root[key] != nil || globals[key] != nil { globals[key] = values }
        }
        if root["project-order"] != nil || globals["project-order"] != nil {
            guard root["project-order"] == nil || root["project-order"] is [String],
                  globals["project-order"] == nil || globals["project-order"] is [String] else {
                throw AccountError.message("项目排序格式无法识别，未同步。")
            }
            let localOrder = (root["project-order"] as? [String] ?? []).filter { ids.contains($0) }
            let remoteOrder = (globals["project-order"] as? [String] ?? []).filter { !oldIDs.contains($0) && !ids.contains($0) }
            var seen = Set<String>()
            globals["project-order"] = (localOrder + ids.sorted() + remoteOrder).filter { seen.insert($0).inserted }
        }
        for key in ["app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host"] {
            var values = try dictionary(globals[key]); let sourceValues = try dictionary(root[key])
            // The desktop namespaces its local database with the canonical CODEX_HOME path.
            for host in Array(values.keys) where isLocalHost(host, home: codexHome) { values.removeValue(forKey: host) }
            for (host, value) in sourceValues where isLocalHost(host, home: codexHome) {
                if key == "app-server-project-id-by-legacy-project-id-by-host" {
                    values[host] = try dictionary(value).filter { ids.contains($0.key) }
                } else {
                    let migration = try dictionary(value)
                    guard migration["version"] as? Int == 1,
                          migration["projectsMigrated"] is Bool, migration["threadAssignmentsMigrated"] is Bool,
                          migration["pendingThreadAssignmentIds"] == nil || migration["pendingThreadAssignmentIds"] is [String] else {
                        throw AccountError.message("本机项目迁移状态格式未知，未修改共享视图。")
                    }
                    values[host] = migration
                }
            }
            if root[key] != nil || globals[key] != nil { globals[key] = values }
        }
        let sourceAssignments = try dictionary(root["thread-project-assignments"])
        let targetAssignments = try dictionary(globals["thread-project-assignments"])
        var assignments = targetAssignments
        let targetMemberships = try dictionary(globals["thread-project-membership-host-ids"])
        var memberships = targetMemberships
        let sourceMemberships = try dictionary(root["thread-project-membership-host-ids"])
        for (thread, value) in targetAssignments {
            if try localProjectID(value) != nil { assignments.removeValue(forKey:thread); memberships.removeValue(forKey:thread) }
        }
        for (thread, value) in sourceAssignments {
            guard let id = try localProjectID(value) else { continue }
            // A deleted project's stale assignment is detached, never copied to the target.
            guard ids.contains(id) else { continue }
            assignments[thread] = value
            if let host = sourceMemberships[thread] { memberships[thread] = host }
        }
        if root["thread-project-assignments"] != nil || globals["thread-project-assignments"] != nil { globals["thread-project-assignments"] = assignments }
        if root["thread-project-membership-host-ids"] != nil || globals["thread-project-membership-host-ids"] != nil { globals["thread-project-membership-host-ids"] = memberships }
        // A chat can belong to a project OR be projectless; both are shared local metadata.
        let sourceLoose = try stringList(root["projectless-thread-ids"])
        let targetLoose = try stringList(globals["projectless-thread-ids"])
        func remote(_ thread: String, _ values: [String: Any]) -> Bool {
            if let host = values[thread] as? String { return !isLocalHost(host, home: codexHome) }
            return false
        }
        var loose = targetLoose.filter { remote($0, targetMemberships) }
        loose += sourceLoose.filter { !remote($0, sourceMemberships) && assignments[$0] == nil }
        // Deleting a project must detach its chats rather than hiding their remaining history.
        for (thread, value) in sourceAssignments {
            if let project = try localProjectID(value), !ids.contains(project), !remote(thread, sourceMemberships) { loose.append(thread) }
        }
        for (thread, value) in targetAssignments {
            if let project = try localProjectID(value), oldIDs.contains(project), !ids.contains(project), assignments[thread] == nil,
               !remote(thread, targetMemberships) { loose.append(thread) }
        }
        var seenLoose = Set<String>(); loose = loose.filter { seenLoose.insert($0).inserted }
        if root["projectless-thread-ids"] != nil || globals["projectless-thread-ids"] != nil || !loose.isEmpty { globals["projectless-thread-ids"] = loose }
        var localThreads = Set(sourceLoose.filter { !remote($0, sourceMemberships) })
        for (thread, value) in sourceAssignments where !remote(thread, sourceMemberships) {
            if try localProjectID(value) != nil { localThreads.insert(thread) }
        }
        for thread in sourceLoose where localThreads.contains(thread) {
            if let host = sourceMemberships[thread] { memberships[thread] = host }
        }
        if root["thread-project-membership-host-ids"] != nil || globals["thread-project-membership-host-ids"] != nil { globals["thread-project-membership-host-ids"] = memberships }
        for key in ["thread-workspace-root-hints", "thread-projectless-output-directories"] {
            let incomingHints = try dictionary(root[key]), oldHints = try dictionary(globals[key])
            var hints = oldHints.filter { remote($0.key, targetMemberships) }
            for (thread, value) in incomingHints where localThreads.contains(thread) && !remote(thread, sourceMemberships) {
                guard let path = value as? String, path.hasPrefix("/") else { throw AccountError.message("聊天目录提示格式未知，未修改共享视图。") }
                hints[thread] = path
            }
            if root[key] != nil || globals[key] != nil { globals[key] = hints }
        }
        if let selection = globals["selected-project"] as? [String: Any],
           let id = selection["projectId"] as? String, oldIDs.contains(id), !ids.contains(id) {
            globals.removeValue(forKey:"selected-project")
        }
        if NSDictionary(dictionary: globals).isEqual(to: destination["globals"] as! [String: Any]) { return nil }
        destination["globals"] = globals; inactive[targetKey] = destination
        state["inactive"] = inactive; root[stateKey] = state
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    public static func isLocalHost(_ key: String, home: URL) -> Bool {
        if key == "local" { return true }
        guard key.hasPrefix("local:"), key.dropFirst(6).hasPrefix("/") else { return false }
        return URL(fileURLWithPath: String(key.dropFirst(6))).standardizedFileURL.resolvingSymlinksInPath() == home.standardizedFileURL.resolvingSymlinksInPath()
    }
    private static func stringList(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let list = value as? [String], list.allSatisfy({ !$0.isEmpty }) else { throw AccountError.message("无项目聊天清单格式未知，未修改共享视图。") }
        return list
    }
    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let result = value as? [String: Any] else { throw AccountError.message("项目元数据格式无法识别，未同步。") }
        return result
    }
    private static func localProjectID(_ value: Any) throws -> String? {
        if let id = value as? String { return id }
        guard let record = value as? [String: Any], let kind = record["projectKind"] as? String,
              let id = record["projectId"] as? String else { throw AccountError.message("聊天项目关联格式无法识别，未同步。") }
        return kind == "local" && record["projectOrigin"] as? String != "chatgpt" ? id : nil
    }
    private static func catalog(_ value: Any?) throws -> [String: [String: Any]] {
        guard let value else { return [:] }
        guard let records = value as? [String: [String: Any]], records.allSatisfy({ id, record in
            guard record["name"] is String, let paths = record["rootPaths"] as? [String],
                  record["id"] == nil || record["id"] as? String == id else { return false }
            return paths.allSatisfy { $0.hasPrefix("/") }
        }) else { throw AccountError.message("项目数据不是已支持的本机项目格式，未同步。") }
        return records
    }
    public static func syncTarget(stateURL: URL, source: Credential, target: Credential, backupFolder: URL) throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        let before = try PrivateFiles.read(stateURL)
        guard let after = try proposedState(before, source: source, target: target, codexHome: stateURL.deletingLastPathComponent()) else { return }
        try PrivateFiles.directory(backupFolder)
        let backup = backupFolder.appendingPathComponent("project-view-\(UUID().uuidString).json")
        try PrivateFiles.write(before, to: backup)
        guard try PrivateFiles.read(stateURL) == before else { throw AccountError.message("项目视图在退出后仍发生变化，已保留备份，未继续切换。") }
        try PrivateFiles.write(after, to: stateURL)
        guard try PrivateFiles.read(stateURL) == after else { throw AccountError.message("项目视图保存校验失败，已保留备份。") }
    }
}
