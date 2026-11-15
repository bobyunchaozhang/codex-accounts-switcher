import AppKit
import SwiftUI
import AccountCore
import Network

struct AccountRow: Identifiable {
    var profile: Profile
    var id: String { profile.id }
    var planLabel: String { PlanLabel.display(current: usage?.bucket?.planType, stored: profile.identity.plan) }
    var usage: Usage?
    var updated: Date?
    var error: String?
}

@MainActor final class MenuModel: ObservableObject {
    @Published var rows: [AccountRow] = []
    @Published var activeKey: String?
    @Published var busy = false
    @Published var refreshing = false
    @Published var message: String?
    @Published var externalAccount = false
    @Published var canReopen = false
    private var switchFailureMessage: String?
    @Published var screen: Screen = .accounts
    @Published var loginWaiting = false
    enum Screen { case accounts, add, manage }
    let demo: Bool
    private let worker = DispatchQueue(label: "accounts.coordinator", qos: .userInitiated)
    private var store: ProfileStore?
    private var service: AccountService?
    private var desktop: Desktop?
    private var transaction: AuthTransaction?
    private var timer: Timer?
    private var cancellation: CancellationFlag?
    private var observer: NSObjectProtocol?
    private let network = NWPathMonitor()
    private var wasOffline = false
    private var lockFD: Int32 = -1
    private var authWatcher: DispatchSourceFileSystemObject?
    private var observedKey: String?
    private var refreshRequested = false
    private let activeURL: URL
    init(demo: Bool = false) {
        self.demo = demo
        activeURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        if demo { loadDemo(); return }
        do {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccounts")
            let s = try ProfileStore(root: root)
            lockFD = open(root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw AccountError.message("已有一个账号工具正在运行。") }
            store = s
            let location = try ClientLocation.discover()
            service = try AccountService(cli: location.cli, runtime: root.appendingPathComponent("runtime"))
            desktop = Desktop(location)
            transaction = try AuthTransaction(active: activeURL, folder: root.appendingPathComponent("transaction"))
            rows = try s.profiles.map { p in
                let cached = s.cached(p)
                return AccountRow(profile: p, usage: cached?.usage, updated: cached?.date, error: cached == nil ? nil : "上次数据 · 待更新")
            }
            message = try transaction?.inspectRecovery()
            // Previous process cannot still own these sessions once the app lock is held; preserve any
            // leftovers rather than deleting files under a possibly orphaned app-server process.
            externalAccount = (try? Credential(PrivateFiles.read(activeURL))).map { c in !rows.contains { $0.id == c.identity.key } } ?? false
            observedKey = (try? Credential(PrivateFiles.read(activeURL)))?.identity.key
            updateLocalIdentity(try? Credential(PrivateFiles.read(activeURL)))
            let authFD = open(activeURL.deletingLastPathComponent().path, O_EVTONLY)
            if authFD >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: authFD, eventMask: [.write, .rename, .delete], queue: worker)
                let auth = activeURL
                source.setEventHandler { [weak self] in
                    let key = (try? Credential(PrivateFiles.read(auth)))?.identity.key
                    awaitMain {
                        guard let self, self.observedKey != key else { return }
                        self.observedKey = key
                        if !self.busy { self.activeKey = nil }
                        self.externalAccount = key.map { k in !self.rows.contains { $0.id == k } } ?? false
                        self.refresh()
                    }
                }
                source.setCancelHandler { close(authFD) }
                source.resume(); authWatcher = source
            }
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            network.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    if path.status == .satisfied, self.wasOffline { self.refresh() }
                    self.wasOffline = path.status != .satisfied
                }
            }
            network.start(queue: DispatchQueue(label: "accounts.network"))
        } catch { message = error.localizedDescription }
    }
    private func loadDemo() {
        for (email, plan, used) in [("alexander.zhang@example.com", "plus", 20), ("alexander.zhang1997@example.com", "self_serve_business_prolite", 43)] {
            let jwt = { (obj: [String: Any]) -> String in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return "demo." + d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".demo"
            }
            let id = jwt(["sub": email, "email": email, "https://api.openai.com/auth": ["chatgpt_plan_type": plan]])
            let tokens: [String: String] = ["id_token": id, "access_token": id, "refresh_token": "fake", "account_id": email]
            let credentialData = try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
            let c = try! Credential(credentialData)
            let data = """
            {"accountId":"\(email)","rateLimits":{"primary":{"usedPercent":\(used),"windowDurationMins":\(plan == "plus" ? 300 : 10080),"resetsAt":\(Int(Date().timeIntervalSince1970) + (plan == "plus" ? 3 * 3600 + 12 * 60 : 2 * 86400 + 3 * 3600 + 12 * 60))}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"demo1","status":"available","resetType":"codexRateLimits","expiresAt":\(Int(Date().timeIntervalSince1970) + 23 * 86400 + 5 * 3600 + 30 * 60)},{"id":"demo2","status":"available","resetType":"codexRateLimits","expiresAt":\(Int(Date().timeIntervalSince1970) + 25 * 86400)}]}}
            """
            rows.append(AccountRow(profile: Profile(identity: c.identity), usage: try! JSONDecoder().decode(Usage.self, from: Data(data.utf8)), updated: Date()))
        }
        activeKey = rows.first?.id
    }
    func refresh() {
        guard !demo, let store, let service else { return }
        guard !busy else { refreshRequested = true; return }
        guard !refreshing else { return }
        timer?.fireDate = Date().addingTimeInterval(300)
        refreshing = true
        // The current marker is local identity, not a successful quota request.
        updateLocalIdentity(try? Credential(PrivateFiles.read(activeURL)))
        let active = activeURL
        worker.async { [weak self] in
            var output: [(String, Usage?, String?)] = []
            let profiles = (try? store.profiles) ?? []
            for (index, p) in profiles.enumerated() {
                var isCurrent = false
                do {
                    let latest = try? Credential(PrivateFiles.read(active))
                    isCurrent = latest?.identity.matches(p.identity) == true
                    let c = isCurrent ? latest! : try store.credential(p)
                    let result = try service.query(c, active: isCurrent) { refreshed in
                        let now = try? Credential(PrivateFiles.read(active))
                        if now?.identity.matches(p.identity) != true { try store.save(refreshed) }
                    }
                    // Re-check external changes before writing an inactive profile refreshed by the tool.
                    let now = try? Credential(PrivateFiles.read(active))
                    if !isCurrent && now?.identity.matches(p.identity) != true { try store.save(result.credential) }
                    try store.cache(result.usage, for: p)
                    output.append((p.id, result.usage, nil))
                } catch {
                    UsageDiagnostics.record(error, profileIndex: index, active: isCurrent, url: store.root.appendingPathComponent("usage-diagnostics.json"))
                    output.append((p.id, nil, "更新失败 · 保留上次数据"))
                }
            }
            let now = try? Credential(PrivateFiles.read(active))
            DispatchQueue.main.async {
                guard let self else { return }
                for (id, usage, error) in output {
                    if let i = self.rows.firstIndex(where: { $0.id == id }) {
                        if let usage { self.rows[i].usage = usage; self.rows[i].updated = Date() }
                        self.rows[i].error = error
                    }
                }
                self.updateLocalIdentity(now)
                self.externalAccount = now.map { n in !self.rows.contains { $0.id == n.identity.key } } ?? false
                self.refreshing = false
            }
        }
    }
    private func updateLocalIdentity(_ credential: Credential?) {
        let alive = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").contains { !$0.isTerminated }
        let matches = credential.map { DesktopIdentity.matches($0, auth: try? PrivateFiles.read(activeURL), state: try? PrivateFiles.read(activeURL.deletingLastPathComponent().appendingPathComponent(".codex-global-state.json"))) } ?? false
        activeKey = alive && matches ? credential?.identity.key : nil
    }
    func importCurrent() {
        guard !demo, !busy, let store else { return }
        busy = true; message = nil
        worker.async { [weak self] in
            do {
                guard let self else { return }
                let c = try Credential(PrivateFiles.read(self.activeURL))
                _ = try store.save(c)
                let all = try store.profiles
                awaitMain { self.replaceProfiles(all); self.busy = false; self.externalAccount = false; self.refresh() }
            } catch { awaitMain { self?.busy = false; self?.message = error.localizedDescription } }
        }
    }
    func login(_ target: Profile? = nil) {
        guard !busy else { return }
        if demo { message = "预览模式，不打开登录、不改变账号。"; return }
        guard let service, let store else { return }
        busy = true; loginWaiting = true; message = "请在浏览器完成登录。添加不会切换当前账号。"
        let flag = CancellationFlag(); cancellation = flag
        worker.async { [weak self] in
            do {
                let c = try service.login(expected: target?.identity, cancelled: flag) { url in
                    var ok = false
                    DispatchQueue.main.sync { ok = NSWorkspace.shared.open(url) }
                    if !ok { throw AccountError.message("无法打开登录页面。") }
                }
                guard !flag.isCancelled else { throw AccountError.message("已取消登录。") }
                try store.save(c)
                let all = try store.profiles
                awaitMain { self?.replaceProfiles(all); self?.message = nil; self?.screen = .accounts; self?.finishOperation() }
            } catch { awaitMain { self?.message = error.localizedDescription; self?.finishOperation() } }
        }
    }
    func cancelLogin() { cancellation?.cancel() }
    func remove(_ p: Profile) {
        guard !busy else { return }
        if demo { rows.removeAll { $0.id == p.id }; return }
        guard let store else { return }
        busy = true
        worker.async { [weak self] in
            do { try store.remove(p); let all = try store.profiles; awaitMain { self?.replaceProfiles(all); self?.finishOperation() } }
            catch { awaitMain { self?.message = error.localizedDescription; self?.finishOperation() } }
        }
    }
    private func replaceProfiles(_ profiles: [Profile]) { rows = profiles.map { p in var row = rows.first { $0.id == p.id } ?? AccountRow(profile: p); row.profile = p; return row } }
    private func finishOperation() { busy = false; loginWaiting = false; cancellation = nil; refreshRequested = false; refresh() }
    func switchTo(_ profile: Profile) {
        guard !busy, profile.id != activeKey else { return }
        if demo { activeKey = profile.id; return }
        guard let store, let service, let transaction, let desktop else { return }
        busy = true; message = "正在准备切换…"; canReopen = false; switchFailureMessage = nil
        let active = activeURL
        worker.async { [weak self] in
            do {
                try Self.checkFileMode(active.deletingLastPathComponent())
                let credential = try store.credential(profile)
                let checkpoint = store.root.appendingPathComponent("shared-view-checkpoint.json")
                let stateURL = active.deletingLastPathComponent().appendingPathComponent(".codex-global-state.json")
                let trace = SwitchDiagnostics(url: store.root.appendingPathComponent("switch-diagnostics.json"), desktopVersion: DesktopState.diskVersion(desktop.location.app), toolVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
                var preparedState: Data?
                let op = SwitchOperations(
                    // No supported live desktop task-status endpoint is available in this build.
                    // Unknown follows the user's explicit normal-quit / bounded force-quit policy.
                    activity: { .unknown },
                    validateTarget: { c in
                        do {
                            let result = try service.query(c, active: false) { try store.save($0) }
                            try store.save(result.credential)
                            return result.credential
                        } catch let error as AccountError {
                            switch error {
                            case .authenticationRejected, .identityMismatch: throw error
                            case .message: return try store.credential(profile)
                            }
                        } catch {
                            // Usage schema/network failure is not a reason to block manual switching.
                            return try store.credential(profile)
                        }
                    },
                    stopDesktop: {
                        do { try desktop.quitAndVerify() }
                        catch { trace.stage("退出检查：" + error.localizedDescription); throw error }
                    },
                    savePrevious: { c in
                        if try store.profiles.contains(where: { $0.id == c.identity.key }) { try store.save(c) }
                    },
                    verifyWritten: { c in
                        let result = try service.query(c, active: true)
                        try store.cache(result.usage, for: profile)
                        awaitMain {
                            if let i = self?.rows.firstIndex(where: { $0.id == profile.id }) {
                                self?.rows[i].usage = result.usage; self?.rows[i].updated = Date(); self?.rows[i].error = nil
                            }
                        }
                    },
                    reopen: { try desktop.reopen() },
                    prepareProjectView: { source, target in
                        trace.context("after-exit", app: desktop.location.app, state: try? PrivateFiles.read(stateURL))
                        try SharedContinuity.validate(source, checkpoint: checkpoint, state: PrivateFiles.read(stateURL))
                        try desktop.requireStopped()
                        try ProjectView.syncTarget(
                            stateURL: active.deletingLastPathComponent().appendingPathComponent(".codex-global-state.json"),
                            source: source, target: target, backupFolder: store.root.appendingPathComponent("project-view-backups"))
                        preparedState = try PrivateFiles.read(stateURL)
                    },
                    preflightView: { current in
                        trace.context("preflight", app: desktop.location.app, state: try? PrivateFiles.read(stateURL))
                        try SharedContinuity.validate(current, checkpoint: checkpoint, state: PrivateFiles.read(stateURL))
                        _ = try ProjectView.proposedState(PrivateFiles.read(stateURL), source: current, target: credential, codexHome: active.deletingLastPathComponent())
                    },
                    credentialsChanged: { try SharedContinuity.activated($0, checkpoint: checkpoint, state: PrivateFiles.read(stateURL)) },
                    verifyDesktop: {
                        let verified = desktop.verifyDesktop($0, stateURL: stateURL, authURL: active)
                        trace.context("after-reopen", app: desktop.location.app, state: try? PrivateFiles.read(stateURL))
                        return verified
                    },
                    beforeCommit: {
                        try desktop.requireStopped()
                        if let preparedState, try PrivateFiles.read(stateURL) != preparedState {
                            throw AccountError.message("切换前桌面存储再次发生变化，尚未修改登录资料，请重试。")
                        }
                    })
                let outcome = SwitchEngine.run(target: credential, transaction: transaction, operations: op) { stage in
                    trace.stage(stage)
                    awaitMain { self?.message = stage; if stage == "正在切换登录资料…" { self?.activeKey = nil } }
                }
                trace.finish(outcome)
                awaitMain {
                    self?.switchFailureMessage = outcome.message
                    self?.message = outcome.message; self?.canReopen = outcome.needsReopen
                    if outcome.desktopVerified { self?.activeKey = profile.id }
                    else if outcome.targetWritten { self?.activeKey = nil }
                    self?.finishOperation()
                }
            } catch { awaitMain { self?.message = error.localizedDescription; self?.finishOperation() } }
        }
    }
    nonisolated private static func checkFileMode(_ home: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: home.path)
        guard a[.type] as? FileAttributeType == .typeDirectory else { throw AccountError.message("当前 CODEX_HOME 不是普通目录，未修改登录资料。") }
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"], URL(fileURLWithPath: value).standardizedFileURL != home.standardizedFileURL { throw AccountError.message("检测到自定义 CODEX_HOME，尚未验证此配置。") }
        let config = home.appendingPathComponent("config.toml")
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("cli_auth_credentials_store"), !(s.contains("\"file\"") || s.contains("'file'")) { throw AccountError.message("当前认证存储不是已验证的 file 模式。") }
                if s.hasPrefix("forced_chatgpt_workspace_id") || s.hasPrefix("forced_login_method") { throw AccountError.message("存在强制登录策略，需先核对兼容性。") }
            }
        }
    }
    func reopen() {
        guard !demo, !busy, let desktop else { return }
        busy = true
        worker.async { [weak self] in
            do { try desktop.reopen(); awaitMain { self?.busy = false; self?.canReopen = false; self?.message = self?.switchFailureMessage } }
            catch { awaitMain {
                self?.busy = false
                self?.message = [self?.switchFailureMessage, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            } }
        }
    }
}
private func awaitMain(_ body: @escaping @MainActor () -> Void) { DispatchQueue.main.async { body() } }
