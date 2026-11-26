import Darwin
import Foundation
import SQLite3

public struct DesktopStateStore {
    public struct Snapshot: Equatable {
        public enum Storage: String { case json, sqlite }
        public let storage: Storage
        public let data: Data
    }

    public let home: URL
    public var jsonURL: URL { home.appendingPathComponent(".codex-global-state.json") }
    private var databaseURL: URL { home.appendingPathComponent(".codex-global-state.sqlite") }

    public init(home: URL) { self.home = home }

    private func usesDatabase() throws -> Bool {
        var info = stat()
        if lstat(databaseURL.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw AccountError.message("无法检查新版桌面状态数据库，切换已停止。")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw AccountError.message("新版桌面状态数据库不是当前用户的独立普通文件，切换已停止。")
        }
        return true
    }

    public func requireJSONStorage() throws {
        guard try !usesDatabase() else {
            throw AccountError.message("Codex 已使用 SQLite 桌面状态，旧版 JSON 恢复命令不可用。")
        }
    }

    public func read() throws -> Snapshot {
        if try usesDatabase() {
            return Snapshot(storage: .sqlite, data: try readDatabase())
        }
        return Snapshot(storage: .json, data: try PrivateFiles.read(jsonURL))
    }

    public func proposedSwitch(_ snapshot: Snapshot, source: Credential, target: Credential, checkpoint: URL) throws -> Data? {
        try SharedContinuity.validate(source, checkpoint: checkpoint, state: snapshot.data)
        if snapshot.storage == .sqlite {
            guard ProjectView.rendererKey(target) != nil else {
                throw AccountError.message("无法确认目标账号的桌面身份，切换已停止。")
            }
            // The catalog is global. Let Codex manage its owner-specific SQLite settings.
            return nil
        }
        return try ProjectView.proposedState(snapshot.data, source: source, target: target, codexHome: home)
    }

    public func saveJSONSwitch(_ after: Data, from before: Snapshot, backupFolder: URL) throws {
        guard before.storage == .json else {
            throw AccountError.message("桌面状态存储已变化，切换已停止。")
        }
        try requireJSONStorage()
        try ProjectView.saveProposedState(after, expected: before.data, stateURL: jsonURL, backupFolder: backupFolder)
    }

    private func readDatabase() throws -> Data {
        // Canonicalize the directory, leaving SQLite to reject links at the database itself.
        // Foundation can preserve /var even when it resolves other links in the path.
        guard let parent = realpath(home.path, nil) else {
            throw AccountError.message("无法定位新版桌面状态数据库，切换已停止。")
        }
        defer { free(parent) }
        let path = String(cString: parent) + "/" + databaseURL.lastPathComponent
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            throw AccountError.message("无法只读打开新版桌面状态数据库，切换已停止。")
        }
        let fields = Set(DesktopState.sharedKeys + [DesktopState.ownerKey, ProjectView.stateKey])
        let keys = fields.sorted().map { "'\($0)'" }.joined(separator: ", ")
        let sql = """
            SELECT key, value FROM settings
            WHERE scope = 'global' AND key IN (\(keys))
              AND (SELECT user_version FROM pragma_user_version) = 1
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let invalid = AccountError.message("新版桌面状态数据库不可读或结构未知，切换已停止。")
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw invalid }
        var root: [String: Any] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  let key = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  let value = sqlite3_column_text(statement, 1),
                  root[key] == nil else { throw invalid }
            let data = Data(bytes: value, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw invalid }
            root[key] = parsed
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE, root[DesktopState.ownerKey] != nil,
              try DesktopState(root).format == .sharedGlobals else { throw invalid }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
