import Foundation
import Darwin

public enum PrivateFiles {
    public static func directory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let a = try FileManager.default.attributesOfItem(atPath: url.path)
            guard a[.type] as? FileAttributeType == .typeDirectory, (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw AccountError.message("资料目录不是当前用户拥有的普通目录。") }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        guard chmod(url.path, 0o700) == 0 else { throw AccountError.message("无法保护资料目录。") }
    }
    public static func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AccountError.message("无法读取登录资料。") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1, st.st_size < 2_000_000 else { throw AccountError.message("登录资料不是当前用户的独立普通文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }
    public static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let tmp = parent.appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AccountError.message("无法创建安全临时文件。") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? h.close(); try? FileManager.default.removeItem(at: tmp) }
        try h.write(contentsOf: data); try h.synchronize(); try h.close()
        guard rename(tmp.path, url.path) == 0 else { throw AccountError.message("无法原子保存资料。") }
        let d = open(parent.path, O_RDONLY); if d >= 0 { _ = fsync(d); close(d) }
    }
}

// A single coordinator owns the store. Profiles contain only auth + metadata, never Codex history/config.
public final class ProfileStore: Sendable {
    public let root: URL
    public init(root: URL) throws { self.root = root; try PrivateFiles.directory(root); try PrivateFiles.directory(root.appendingPathComponent("profiles")) }
    public var profiles: [Profile] {
        get throws {
            let url = root.appendingPathComponent("accounts.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try JSONDecoder().decode([Profile].self, from: PrivateFiles.read(url))
        }
    }
    public func authURL(_ key: String) throws -> URL {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { throw AccountError.message("账号标识无效。") }
        return root.appendingPathComponent("profiles/\(key).json")
    }
    @discardableResult public func save(_ credential: Credential) throws -> Profile {
        var all = try profiles
        let old = all.first { $0.id == credential.identity.key }
        let profile = Profile(identity: credential.identity, added: old?.added ?? Date())
        try PrivateFiles.write(credential.data, to: authURL(profile.id))
        if let i = all.firstIndex(where: { $0.id == profile.id }) { all[i] = profile } else { all.append(profile) }
        try PrivateFiles.write(JSONEncoder().encode(all), to: root.appendingPathComponent("accounts.json"))
        return profile
    }
    public func credential(_ profile: Profile) throws -> Credential {
        let c = try Credential(PrivateFiles.read(authURL(profile.id)))
        guard c.identity.matches(profile.identity) else { throw AccountError.message("保存资料的身份不一致，请重新登录。") }
        return c
    }
    public func remove(_ profile: Profile) throws {
        let all = try profiles.filter { $0.id != profile.id }
        // Remove secret first: an interrupted metadata write leaves a repairable row, never a hidden credential.
        let auth = try authURL(profile.id)
        if FileManager.default.fileExists(atPath: auth.path) { try FileManager.default.removeItem(at: auth) }
        try PrivateFiles.write(JSONEncoder().encode(all), to: root.appendingPathComponent("accounts.json"))
        let cache = root.appendingPathComponent("profiles/\(profile.id).usage.json")
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
    }
    public func cache(_ usage: Usage, for profile: Profile) throws {
        _ = try authURL(profile.id)
        try PrivateFiles.write(JSONEncoder().encode(CachedUsage(usage: usage)), to: root.appendingPathComponent("profiles/\(profile.id).usage.json"))
    }
    public func cached(_ profile: Profile) -> CachedUsage? {
        guard (try? authURL(profile.id)) != nil else { return nil }
        return try? JSONDecoder().decode(CachedUsage.self, from: PrivateFiles.read(root.appendingPathComponent("profiles/\(profile.id).usage.json")))
    }
}

public struct SwitchJournal: Codable {
    public enum Stage: String, Codable { case prepared, written, verified }
    public var stage: Stage
    public let target: Identity
    public let prior: Identity?
}

public final class AuthTransaction: Sendable {
    public let active: URL
    public let folder: URL
    private var journalURL: URL { folder.appendingPathComponent("switch.json") }
    private var backupURL: URL { folder.appendingPathComponent("before.json") }
    private var targetURL: URL { folder.appendingPathComponent("target.json") }
    public init(active: URL, folder: URL) throws { self.active = active; self.folder = folder; try PrivateFiles.directory(folder) }
    public var journal: SwitchJournal? {
        get throws {
            guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
            return try JSONDecoder().decode(SwitchJournal.self, from: PrivateFiles.read(journalURL))
        }
    }
    public func prepare(target: Credential, expectedCurrent: Data?) throws {
        guard try journal == nil else { throw AccountError.message("上次切换尚未核对，不能覆盖恢复资料。") }
        let actual = FileManager.default.fileExists(atPath: active.path) ? try PrivateFiles.read(active) : nil
        guard actual == expectedCurrent else { throw AccountError.message("当前登录已在外部变化，请重试。") }
        if let actual { try PrivateFiles.write(actual, to: backupURL) }
        else if FileManager.default.fileExists(atPath: backupURL.path) { try FileManager.default.removeItem(at: backupURL) }
        try PrivateFiles.write(target.data, to: targetURL)
        let j = SwitchJournal(stage: .prepared, target: target.identity, prior: actual.flatMap { try? Credential($0).identity })
        try PrivateFiles.write(JSONEncoder().encode(j), to: journalURL)
    }
    public func commit() throws {
        guard var j = try journal, j.stage == .prepared else { throw AccountError.message("切换阶段无效。") }
        let expected = FileManager.default.fileExists(atPath: backupURL.path) ? try PrivateFiles.read(backupURL) : nil
        let actual = FileManager.default.fileExists(atPath: active.path) ? try PrivateFiles.read(active) : nil
        guard actual == expected else { throw AccountError.message("写入前发现外部登录变化，已保留现状。") }
        try PrivateFiles.write(PrivateFiles.read(targetURL), to: active)
        j.stage = .written
        try PrivateFiles.write(JSONEncoder().encode(j), to: journalURL)
        guard try PrivateFiles.read(active) == PrivateFiles.read(targetURL) else { throw AccountError.message("写入校验失败。") }
    }
    public func rollback() throws {
        guard try journal != nil else { return }
        // Never overwrite an independent login/refresh that happened after our write.
        let now = FileManager.default.fileExists(atPath: active.path) ? try PrivateFiles.read(active) : nil
        guard now == (try? PrivateFiles.read(targetURL)) else { throw AccountError.message("活动凭证已变化，不能安全自动恢复；已保留恢复资料。") }
        if FileManager.default.fileExists(atPath: backupURL.path) { try PrivateFiles.write(PrivateFiles.read(backupURL), to: active) }
        else { try FileManager.default.removeItem(at: active) }
        try finish()
    }
    public func finish() throws {
        // Journal is the commit marker. Leftover snapshots without a journal are removed at next start.
        if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
        for u in [backupURL, targetURL] where FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
    public func inspectRecovery() throws -> String? {
        guard let j = try journal else { try finish(); return nil }
        if let current = try? Credential(PrivateFiles.read(active)) {
            if current.identity.matches(j.target) { try finish(); return "上次切换已写入目标身份；保留该账号，待联网核验。" }
            if let prior = j.prior, current.identity.matches(prior) { try finish(); return "上次切换未生效，保留原账号。" }
        }
        // Unknown/invalid state requires examination, never blind rollback or launch.
        return "上次切换状态尚未确认，恢复资料已保留。请先核对 Codex 登录状态。"
    }
}
