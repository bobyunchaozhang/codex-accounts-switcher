import Foundation
import Darwin

// One request at a time. All pipe I/O stays off the main actor, with bounded reads and process cleanup.
public final class AppServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var sequence = 0
    private var notifications: [[String: Any]] = []
    private var stopped = false
    public let home: URL
    public init(cli: URL, home: URL) throws {
        self.home = home
        try PrivateFiles.directory(home)
        try PrivateFiles.write(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: home.appendingPathComponent("config.toml"))
        process.executableURL = cli
        process.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "app-server", "--listen", "stdio://"]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh",
                               "CODEX_HOME": home.path, "CODEX_SQLITE_HOME": home.path, "TMPDIR": home.path]
        process.currentDirectoryURL = home
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never put auth URLs/tokens in product logs.
        try process.run()
        do {
            _ = try request("initialize", ["clientInfo": ["name": "codex_accounts", "version": "0.1.2"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
        } catch { stop(); throw error }
    }
    deinit { stop() }
    public func stop() {
        guard !stopped else { return }; stopped = true
        try? input.fileHandleForWriting.close()
        let end = Date().addingTimeInterval(2)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate() }
        let termEnd = Date().addingTimeInterval(2)
        while process.isRunning && Date() < termEnd { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
    private func send(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private func next(deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return obj }
                continue
            }
            var p = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let status = poll(&p, 1, 100)
            if status < 0 { if errno == EINTR { continue }; throw AccountError.message("登录服务读取失败。") }
            if status == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(p.fd, &bytes, bytes.count)
            guard count > 0 else { throw AccountError.message("登录服务已退出。") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 4_000_000 else { throw AccountError.message("登录服务返回异常。") }
        }
        throw AccountError.message("连接超时；保留当前账号，可稍后重试。")
    }
    public func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 30) throws -> [String: Any] {
        sequence += 1; let id = sequence
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let obj = try next(deadline: deadline)
            if obj["id"] as? Int == id {
                if let error = obj["error"] as? [String: Any] {
                    let text = (error["message"] as? String ?? "").lowercased()
                    if (error["code"] as? Int) == 401 || ["401 unauthorized", "invalid_grant", "refresh_token_reused", "refresh_token_expired", "token_expired"].contains(where: text.contains) {
                        throw AccountError.authenticationRejected
                    }
                    throw AccountError.message("Codex 接口 \(method) 返回错误，请稍后重试或重新登录。")
                }
                return obj["result"] as? [String: Any] ?? [:]
            }
            if obj["method"] != nil, obj["id"] != nil {
                try send(["id": obj["id"]!, "error": ["code": -32601, "message": "Unsupported request"]])
            } else if obj["method"] as? String == "account/login/completed" { notifications.append(obj) }
        }
    }
    public func login(open: (URL) throws -> Void, cancelled: () -> Bool) throws -> Credential {
        let start = try request("account/login/start", ["type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"])
        guard let id = start["loginId"] as? String, let raw = start["authUrl"] as? String,
              let url = URL(string: raw), url.scheme == "https",
              ["auth.openai.com", "auth0.openai.com", "auth.chatgpt.com", "chatgpt.com"].contains(url.host ?? "") else { throw AccountError.message("登录地址不受支持，未打开浏览器。") }
        try open(url)
        let end = Date().addingTimeInterval(600)
        while Date() < end {
            if cancelled() { _ = try? request("account/login/cancel", ["loginId": id], timeout: 2); throw AccountError.message("已取消登录。") }
            let notification: [String: Any]
            if !notifications.isEmpty { notification = notifications.removeFirst() }
            else {
                do { notification = try next(deadline: Date().addingTimeInterval(0.3)) }
                catch { if !process.isRunning { throw error }; continue }
            }
            if notification["method"] as? String == "account/login/completed", let p = notification["params"] as? [String: Any], p["loginId"] as? String == id {
                guard p["success"] as? Bool == true else { throw AccountError.message("登录未完成，请重试。") }
                _ = try request("account/read", ["refreshToken": false])
                return try Credential(PrivateFiles.read(home.appendingPathComponent("auth.json")))
            }
        }
        _ = try? request("account/login/cancel", ["loginId": id], timeout: 2)
        throw AccountError.message("登录等待已超时，请重试。")
    }
    public func usage(expected: Identity) throws -> Usage {
        let account = try request("account/read", ["refreshToken": false])
        guard let a = account["account"] as? [String: Any], a["type"] as? String == "chatgpt" else { throw AccountError.authenticationRejected }
        guard a["email"] as? String == expected.email else { throw AccountError.identityMismatch }
        let result = try request("account/rateLimits/read", ["excludeResetCreditDetails": false])
        let usage = try JSONDecoder().decode(Usage.self, from: JSONSerialization.data(withJSONObject: result))
        guard let accountID = usage.accountId else { throw AccountError.message("服务未确认目标工作区；保留现状，稍后重试。") }
        guard accountID == expected.workspace else { throw AccountError.identityMismatch }
        return usage
    }
}

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
