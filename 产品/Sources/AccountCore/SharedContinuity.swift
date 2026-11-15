import Foundation
import CryptoKit

public enum SharedContinuity {
    public struct Checkpoint: Codable {
        public var owner: String
        public var requiredKeys: [String] = []
        public var format: DesktopState.Format? = nil
    }
    public struct RepairPlan: Codable {
        public let owner: String
        public let digest: String
        public let globals: Data
        public let projectNames: [String]
        public var format: DesktopState.Format? = nil
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccountError.message("共享视图格式无效。") }
        return value
    }
    private static func encode(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    public static func validate(_ source: Credential, checkpoint: URL, state: Data? = nil) throws {
        let desktop = try state.map { try DesktopState($0) }
        let record = FileManager.default.fileExists(atPath: checkpoint.path)
            ? try JSONDecoder().decode(Checkpoint.self, from: PrivateFiles.read(checkpoint)) : nil
        if let desktop, desktop.format == .sharedGlobals {
            try desktop.validateSharedCatalog()
            guard desktop.owner == ProjectView.rendererKey(source) else {
                throw AccountError.message("当前认证与新版桌面身份尚未一致；尚未修改登录资料。")
            }
            // Shared lists do not change owner when someone logs in outside the tool.
            // A legacy checkpoint can be adopted only after validating the actual shared data.
            guard (record?.requiredKeys ?? []).allSatisfy({ desktop.root[$0] != nil && !(desktop.root[$0] is NSNull) }) else {
                throw AccountError.message("交接记录要求的公共清单缺失，尚未修改登录资料。")
            }
            return
        }
        if record?.format == .sharedGlobals {
            throw AccountError.message("桌面存储从公共清单退回旧结构，尚未确认兼容；未覆盖资料。")
        }
        guard let record else {
            throw AccountError.message("共享视图尚未完成升级核对。请先运行随新版提供的「恢复共享视图」；本次未修改账号。")
        }
        guard record.owner == ProjectView.rendererKey(source) else {
            throw AccountError.message("检测到工具外登录，尚未确认共享视图完整。请先运行「恢复共享视图」，避免把旧列表误当成删除。")
        }
        if let state {
            let root = try object(state)
            guard try views(root).0 == record.owner, record.requiredKeys.allSatisfy({ root[$0] != nil && !(root[$0] is NSNull) }) else {
                throw AccountError.message("共享视图尚未完整加载或关键清单缺失；未将缺失信息当作删除。")
            }
        }
    }
    public static func activated(_ credential: Credential, checkpoint: URL, state: Data? = nil) throws {
        guard let owner = ProjectView.rendererKey(credential) else { throw AccountError.message("无法记录共享视图所属身份。") }
        var keys: [String] = []
        var format: DesktopState.Format? = nil
        if let state {
            let desktop = try DesktopState(state)
            format = desktop.format
            if desktop.format == .sharedGlobals {
                try desktop.validateSharedCatalog()
                keys = DesktopState.requiredSharedKeys
            } else {
                _ = try views(desktop.root)
                let globals = desktop.owner == owner ? desktop.root : (desktop.inactive[owner]?["globals"] as? [String: Any] ?? [:])
                keys = DesktopState.requiredSharedKeys.filter { globals[$0] != nil }
            }
        }
        // Keep a recoverable copy of the tool's old record, not a duplicate chat database.
        if format == .sharedGlobals, FileManager.default.fileExists(atPath: checkpoint.path) {
            let before = try PrivateFiles.read(checkpoint)
            let previous = try JSONDecoder().decode(Checkpoint.self, from: before)
            if previous.format != .sharedGlobals {
                let folder = checkpoint.deletingLastPathComponent().appendingPathComponent("checkpoint-backups")
                try PrivateFiles.directory(folder)
                try PrivateFiles.write(before, to: folder.appendingPathComponent("before-shared-\(UUID().uuidString).json"))
                guard try PrivateFiles.read(checkpoint) == before else { throw AccountError.message("交接记录在升级期间发生变化，未覆盖。") }
            }
        }
        try PrivateFiles.write(JSONEncoder().encode(Checkpoint(owner: owner, requiredKeys: keys, format: format)), to: checkpoint)
    }
    private static func views(_ root: [String: Any]) throws -> (String, [String: [String: Any]]) {
        let desktop = try DesktopState(root)
        guard desktop.format == .legacySnapshots else {
            throw AccountError.message("客户端已使用公共项目与聊天清单，无需旧版恢复命令；请使用新版切换器。")
        }
        guard (root[ProjectView.stateKey] as? [String: Any])?["inactive"] is [String: [String: Any]] else {
            throw AccountError.message("旧版账号快照清单不完整，未同步或切换。")
        }
        return (desktop.owner, desktop.inactive)
    }
    public static func digest(_ data: Data) throws -> String {
        let desktop = try DesktopState(data)
        if desktop.format == .sharedGlobals {
            try desktop.validateSharedCatalog()
            let shared = desktop.root.filter { DesktopState.sharedKeys.contains($0.key) }
            return SHA256.hash(data: try encode(["format": desktop.format.rawValue, "owner": desktop.owner, "shared": shared])).map { String(format: "%02x", $0) }.joined()
        }
        let root = try object(data), (owner, inactive) = try views(root)
        var all: [String: Any] = [owner: root.filter { ProjectView.sharedKeys.contains($0.key) }]
        for (key, value) in inactive {
            guard let globals = value["globals"] as? [String: Any] else { throw AccountError.message("保存视图格式无效。") }
            all[key] = globals.filter { ProjectView.sharedKeys.contains($0.key) }
        }
        return SHA256.hash(data: try encode(["owner": owner, "views": all])).map { String(format: "%02x", $0) }.joined()
    }
    /// Explicit one-time repair proposal: retain current values and add missing local metadata.
    /// This is NOT the normal sync algorithm; the user reviews potentially restored projects first.
    public static func prepareRepair(_ data: Data, active: Credential, accounts: [Credential], home: URL) throws -> RepairPlan {
        let root = try object(data), (owner, inactive) = try views(root)
        guard owner == ProjectView.rendererKey(active) else { throw AccountError.message("活动身份与桌面视图不一致，不能生成恢复方案。") }
        var merged = root
        // Use the regular adapter to validate and strip foreign account-specific project fields.
        for other in accounts where !other.identity.matches(active.identity) {
            guard let key = ProjectView.rendererKey(other), let snapshot = inactive[key], let globals = snapshot["globals"] as? [String: Any] else { continue }
            if globals.isEmpty { continue } // A newly added account has no local view to recover.
            var fake = globals
            fake[ProjectView.stateKey] = ["owner": key, "inactive": [owner: ["atoms": [:], "globals": [:]]]]
            guard let adapted = try ProjectView.proposedState(encode(fake), source: other, target: active, codexHome: home) else { continue }
            let parsed = try object(adapted), (_, adaptedInactive) = try views(parsed)
            let incoming = adaptedInactive[owner]!["globals"] as! [String: Any]
            for name in ProjectView.sharedKeys {
                if let dict = incoming[name] as? [String: Any] {
                    var combined = dict
                    if let existing = merged[name] as? [String: Any] {
                        // Local host mappings contain project-keyed dictionaries one level deeper.
                        if name == "app-server-project-id-by-legacy-project-id-by-host" {
                            for (host, value) in existing {
                                if var map = combined[host] as? [String: Any], let existingMap = value as? [String: Any] {
                                    map.merge(existingMap) { _, current in current }; combined[host] = map
                                } else { combined[host] = value }
                            }
                        } else if name == "app-server-projects-migration-by-host" {
                            for (host, value) in existing {
                                if var migration = combined[host] as? [String: Any], let current = value as? [String: Any] {
                                    let pending = (migration["pendingThreadAssignmentIds"] as? [String] ?? []) + (current["pendingThreadAssignmentIds"] as? [String] ?? [])
                                    migration["pendingThreadAssignmentIds"] = Array(Set(pending)).sorted()
                                    migration["projectsMigrated"] = (migration["projectsMigrated"] as? Bool == true) && (current["projectsMigrated"] as? Bool == true)
                                    migration["threadAssignmentsMigrated"] = (migration["threadAssignmentsMigrated"] as? Bool == true) && (current["threadAssignmentsMigrated"] as? Bool == true)
                                    combined[host] = migration
                                } else { combined[host] = value }
                            }
                        } else { combined.merge(existing) { _, current in current } }
                    }
                    merged[name] = combined
                } else if let list = incoming[name] as? [String] {
                    var seen = Set<String>()
                    merged[name] = ((merged[name] as? [String] ?? []) + list).filter { seen.insert($0).inserted }
                }
            }
        }
        var assignments = merged["thread-project-assignments"] as? [String: Any] ?? [:]
        // The current view's explicit move out of a project wins over an older association.
        for thread in root["projectless-thread-ids"] as? [String] ?? [] { assignments.removeValue(forKey: thread) }
        merged["thread-project-assignments"] = assignments
        merged["projectless-thread-ids"] = (merged["projectless-thread-ids"] as? [String] ?? []).filter { assignments[$0] == nil }
        let projects = merged["local-projects"] as? [String: [String: Any]] ?? [:]
        guard root["local-projects"] != nil else { throw AccountError.message("活动项目清单缺失，不能修复。") }
        return RepairPlan(owner: owner, digest: try digest(data), globals: try encode(merged.filter { ProjectView.sharedKeys.contains($0.key) }), projectNames: projects.values.compactMap { $0["name"] as? String }.sorted(), format: .legacySnapshots)
    }
    public static func repairState(_ data: Data, plan: RepairPlan, active: Credential, accounts: [Credential], home: URL) throws -> Data {
        guard try DesktopState(data).format == .legacySnapshots, (plan.format ?? .legacySnapshots) == .legacySnapshots else {
            throw AccountError.message("恢复候选与当前存储结构不兼容，未应用旧快照；新版公共清单无需旧版恢复命令。")
        }
        guard plan.owner == ProjectView.rendererKey(active), try digest(data) == plan.digest else {
            throw AccountError.message("项目或聊天归属在方案生成后已变化；未应用旧方案，请重新生成并核对。")
        }
        var root = try object(data)
        let globals = try object(plan.globals)
        guard Set(globals.keys).isSubset(of: Set(ProjectView.sharedKeys)) else { throw AccountError.message("恢复方案含非共享字段。") }
        for key in ProjectView.sharedKeys { root[key] = globals[key] }
        var result = try encode(root)
        for other in accounts where !other.identity.matches(active.identity) {
            result = try ProjectView.proposedState(result, source: active, target: other, codexHome: home) ?? result
        }
        return result
    }

    public static func undoRepair(current: Data, before: Data, expectedAfterDigest: String, active: Credential) throws -> Data {
        guard try DesktopState(current).format == .legacySnapshots, try DesktopState(before).format == .legacySnapshots else {
            throw AccountError.message("客户端存储结构已升级，不能用旧快照撤销；已保留当前公共数据。")
        }
        var now = try object(current)
        let old = try object(before), (owner, oldInactive) = try views(old)
        guard owner == ProjectView.rendererKey(active), try views(now).0 == owner,
              try digest(current) == expectedAfterDigest else {
            throw AccountError.message("账号或共享数据已变化，不能自动撤销恢复；已保留备份。")
        }
        for key in ProjectView.sharedKeys { now[key] = old[key] }
        var state = now[ProjectView.stateKey] as! [String: Any]
        var inactive = state["inactive"] as! [String: [String: Any]]
        for (owner, snapshot) in oldInactive {
            guard var destination = inactive[owner], var globals = destination["globals"] as? [String: Any],
                  let original = snapshot["globals"] as? [String: Any] else { throw AccountError.message("账号视图结构已变化，未撤销。") }
            for key in ProjectView.sharedKeys { globals[key] = original[key] }
            destination["globals"] = globals; inactive[owner] = destination
        }
        state["inactive"] = inactive; now[ProjectView.stateKey] = state
        return try encode(now)
    }
}
