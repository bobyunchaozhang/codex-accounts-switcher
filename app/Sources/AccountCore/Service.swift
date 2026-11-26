import Foundation

public struct QueryResult {
    public let usage: Usage
    public let credential: Credential
}
public final class AccountService: Sendable {
    public let cli: URL
    public let runtime: URL
    public init(cli: URL, runtime: URL) throws { self.cli = cli; self.runtime = runtime; try PrivateFiles.directory(runtime) }
    private func session<T>(credential: Data? = nil, _ body: (AppServer, URL) throws -> T) throws -> T {
        let home = runtime.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(home)
        defer { try? FileManager.default.removeItem(at: home) }
        if let credential { try PrivateFiles.write(credential, to: home.appendingPathComponent("auth.json")) }
        let server = try AppServer(cli: cli, home: home)
        defer { server.stop() }
        return try body(server, home)
    }
    public func login(expected: Identity?, cancelled: CancellationFlag, open: (URL) throws -> Void) throws -> Credential {
        try session { server, _ in
            let c = try server.login(open: open, cancelled: { cancelled.isCancelled })
            if let expected, !c.identity.matches(expected) { throw AccountError.message("登录了另一个账号或工作区，原记录未改变。请重试。") }
            return c
        }
    }
    public func query(_ credential: Credential, active: Bool, persist: ((Credential) throws -> Void)? = nil) throws -> QueryResult {
        // Never let a cloned current profile refresh the same refresh token as the working desktop.
        let data = active ? try credential.withoutRefreshToken() : credential.data
        return try session(credential: data) { server, home in
            let usage: Usage
            do { usage = try server.usage(expected: credential.identity) }
            catch {
                // Auth can rotate before the quota endpoint fails. Preserve only the same identity,
                // including on error, so the next attempt does not reuse an invalidated refresh token.
                if !active, let rotated = try? Credential(PrivateFiles.read(home.appendingPathComponent("auth.json"))), rotated.identity.matches(credential.identity) {
                    try persist?(rotated)
                }
                throw error
            }
            let refreshed = active ? credential : try Credential(PrivateFiles.read(home.appendingPathComponent("auth.json")))
            guard refreshed.identity.matches(credential.identity) else { throw AccountError.message("刷新身份不匹配，已丢弃临时资料。") }
            if !active { try persist?(refreshed) }
            return QueryResult(usage: usage, credential: refreshed)
        }
    }
}
