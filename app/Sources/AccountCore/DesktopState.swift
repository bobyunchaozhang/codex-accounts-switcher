import Foundation

/// Storage capabilities inspected in the 26.1103 and 26.1106 desktop builds.
/// Ownership and data validation are deliberately separate: an owner alone is not
/// proof that every project list is loaded, nor a successful online login.
public struct DesktopState {
    public enum Format: String, Codable { case legacySnapshots = "account-snapshots-v1", sharedGlobals = "shared-globals-v1" }
    public static let ownerKey = "electron-renderer-content-owner"
    public static let requiredSharedKeys = ["local-projects", "thread-project-assignments", "projectless-thread-ids"]
    public static let sharedKeys = ["local-projects", "thread-project-assignments", "projectless-thread-ids",
        "project-order", "project-appearances", "sidebar-project-thread-orders", "thread-project-membership-host-ids",
        "app-server-project-id-by-legacy-project-id-by-host"]
    public static let hintKeys = ["thread-workspace-root-hints", "thread-projectless-output-directories"]
    public let format: Format
    public let owner: String
    public let root: [String: Any]
    public let inactive: [String: [String: Any]]

    public init(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountError.message("桌面状态格式无效，尚未修改登录资料。")
        }
        try self.init(root)
    }
    public init(_ root: [String: Any]) throws {
        self.root = root
        let legacy = root[ProjectView.stateKey] != nil, shared = root[Self.ownerKey] != nil
        guard legacy != shared else {
            throw AccountError.message(legacy ? "桌面新旧存储结构同时存在，迁移状态未确认；尚未修改登录资料。" : "客户端存储格式无法识别，切换器需要适配；尚未修改登录资料。")
        }
        if legacy {
            guard let state = root[ProjectView.stateKey] as? [String: Any], let owner = state["owner"] as? String,
                  !owner.isEmpty, state["inactive"] == nil || state["inactive"] is [String: [String: Any]] else {
                throw AccountError.message("旧版账号视图结构不完整，尚未修改登录资料。")
            }
            self.format = .legacySnapshots; self.owner = owner; self.inactive = state["inactive"] as? [String: [String: Any]] ?? [:]
        } else {
            guard let owner = root[Self.ownerKey] as? String,
                  owner == "signed-out" || (owner.count == 64 && owner.allSatisfy({ $0.isHexDigit })) else {
                throw AccountError.message("新版桌面身份标记无效，尚未修改登录资料。")
            }
            self.format = .sharedGlobals; self.owner = owner; self.inactive = [:]
        }
    }

    public func validateSharedCatalog() throws {
        guard format == .sharedGlobals,
              Self.requiredSharedKeys.allSatisfy({ root[$0] != nil && !(root[$0] is NSNull) }),
              let projects = root["local-projects"] as? [String: [String: Any]],
              let assignments = root["thread-project-assignments"] as? [String: Any],
              let loose = root["projectless-thread-ids"] as? [String] else {
            throw AccountError.message("公共项目或聊天清单缺失／格式未知；未将缺失信息当作删除。")
        }
        guard projects.allSatisfy({ id, item in
            guard !id.isEmpty, item["name"] is String, let paths = item["rootPaths"] as? [String],
                  item["id"] == nil || item["id"] as? String == id else { return false }
            return paths.allSatisfy { $0.hasPrefix("/") }
        }), loose.allSatisfy({ !$0.isEmpty }), Set(loose).count == loose.count else {
            throw AccountError.message("公共项目或无项目聊天清单格式未知，未继续切换。")
        }
        for (thread, assignment) in assignments {
            guard !thread.isEmpty else { throw AccountError.message("公共聊天归属标识为空，未继续切换。") }
            if let id = try Self.localProjectID(assignment) {
                guard projects[id] != nil, !loose.contains(thread) else {
                    throw AccountError.message("公共聊天归属尚未一致，请等待客户端完成项目更新后重试。")
                }
            }
        }
        // Validate fields used to select local hints. Preserve all other public/account data verbatim.
        if let value = root["thread-project-membership-host-ids"], !(value is [String: String]) {
            throw AccountError.message("聊天所属主机格式未知，未继续切换。")
        }
    }
    static func localProjectID(_ value: Any) throws -> String? {
        if let id = value as? String, !id.isEmpty { return id }
        guard let record = value as? [String: Any], let kind = record["projectKind"] as? String,
              ["local", "remote"].contains(kind), let id = record["projectId"] as? String, !id.isEmpty else {
            throw AccountError.message("聊天项目归属格式未知，未继续切换。")
        }
        return kind == "local" && record["projectOrigin"] as? String != "chatgpt" ? id : nil
    }
    public static func hintKey(_ field: String, owner: String) -> String { "electron-owner-value:\(field):\(owner)" }

    /// Global catalogs are already shared by the desktop. Only known local chat
    /// directory hints need to be handed over; absence is not an instruction to
    /// erase a target hint. Migration flags, permissions and atoms stay untouched.
    public func proposedHints(source: Credential, target: Credential, home: URL) throws -> Data? {
        try validateSharedCatalog()
        guard owner == ProjectView.rendererKey(source), let targetKey = ProjectView.rendererKey(target) else {
            throw AccountError.message("当前认证与桌面身份不一致，尚未修改登录资料。")
        }
        let memberships = root["thread-project-membership-host-ids"] as? [String: String] ?? [:]
        func local(_ thread: String) -> Bool { memberships[thread].map { ProjectView.isLocalHost($0, home: home) } ?? true }
        var threads = Set((root["projectless-thread-ids"] as! [String]).filter(local))
        for (thread, assignment) in root["thread-project-assignments"] as! [String: Any] where local(thread) {
            if try Self.localProjectID(assignment) != nil { threads.insert(thread) }
        }
        var result = root, changed = false
        for field in Self.hintKeys {
            let from = Self.hintKey(field, owner: owner), to = Self.hintKey(field, owner: targetKey)
            guard root[from] != nil else { continue }
            guard let incoming = root[from] as? [String: String],
                  root[to] == nil || root[to] is [String: String] else {
                throw AccountError.message("账号独立目录提示格式未知，未继续切换。")
            }
            var hints = root[to] as? [String: String] ?? [:]
            for (thread, path) in incoming where threads.contains(thread) {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw AccountError.message("本机聊天目录提示无效，未继续切换。") }
                if hints[thread] != path { hints[thread] = path; changed = true }
            }
            if !hints.isEmpty { result[to] = hints }
        }
        return changed ? try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) : nil
    }

    /// Foundation caches Bundle.infoDictionary for a running switcher even after
    /// an updater replaces the desktop bundle. Read the plist bytes each time.
    public static func diskVersion(_ app: URL) -> String {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else { return "unknown" }
        return version
    }
}
