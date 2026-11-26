import AppKit
import AccountCore

struct ClientLocation: Sendable {
    let app: URL
    let cli: URL
    var bundleIdentifier: String { Bundle(url: app)?.bundleIdentifier ?? "com.openai.codex" }
    static func discover() throws -> ClientLocation {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { throw AccountError.message("未找到 Codex 桌面应用。") }
        let candidates = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
        guard let cli = candidates.map({ app.appendingPathComponent($0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw AccountError.message("未找到桌面应用内的 Codex CLI。") }
        return ClientLocation(app: app, cli: cli)
    }
}

final class Desktop: @unchecked Sendable {
    // All lifecycle methods run on the coordinator worker; AppKit callback data is synchronized by a semaphore.
    private var quitting: [NSRunningApplication] = []
    let location: ClientLocation
    private let snapshotFilter: ([DesktopProcess]) -> [DesktopProcess]
    init(_ location: ClientLocation, snapshotFilter: @escaping ([DesktopProcess]) -> [DesktopProcess] = { $0 }) {
        self.location = location; self.snapshotFilter = snapshotFilter
    }
    private func processes() throws -> [DesktopProcess] { try snapshotFilter(ProcessScan.read { try processSnapshot() }) }
    private func processSnapshot() throws -> [DesktopProcess] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-wwaxo", "pid=,ppid=,stat=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AccountError.message("无法核对客户端进程，尚未修改登录资料。") }
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let row = ProcessScan.parse(String(line)), !ProcessScan.isZombie(row.status) else { return nil }
            let pid = row.pid
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
                if (row.executable.hasPrefix(location.app.path + "/") || URL(fileURLWithPath: row.executable).lastPathComponent == "codex"), kill(pid, 0) == 0 {
                    throw AccountError.message("无法核对仍在运行的客户端进程身份（PID \(pid)），尚未修改登录资料。")
                }
                return nil
            }
            guard info.pbi_status != 5 else { return nil } // SZOMB: cannot execute or write credentials.
            return DesktopProcess(pid: pid, parent: Int32(info.pbi_ppid), executable: row.executable, birth: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
        }
    }
    func reportReadOnly() throws {
        let rows = try processes()
        let roots = Set(NSRunningApplication.runningApplications(withBundleIdentifier: location.bundleIdentifier).map(\.processIdentifier))
        let scope = DesktopProcessScope(appPath: location.app.path, roots: roots, snapshot: rows)
        let detached = rows.filter { $0.executable.hasPrefix(location.app.path + "/") && !scope.owns($0) }
        let matched = rows.filter { roots.contains($0.pid) && $0.executable.hasPrefix(location.app.path + "/Contents/MacOS/") }
        print("registered_main_matches=\(matched.count)")
        print("desktop_roots=\(roots.count) detached_bundle_processes=\(detached.count) detached_blockers=\(scope.blockers(detached).count)")
        print("readonly=true signals_sent=0 auth_writes=0 state_writes=0")
    }
    func requireStopped() throws {
        let rows = try processes()
        let scope = DesktopProcessScope(appPath: location.app.path, roots: [], snapshot: rows)
        let registered = Set(NSRunningApplication.runningApplications(withBundleIdentifier: location.bundleIdentifier).map(\.processIdentifier))
        let blockers = scope.remainingClients(rows, registeredPIDs: registered)
        guard blockers.isEmpty else { throw blocked(blockers) }
    }
    private func blocked(_ rows: [DesktopProcess]) -> AccountError {
        let names = rows.prefix(8).map { "\(URL(fileURLWithPath: $0.executable).lastPathComponent)（PID \($0.pid)）" }.joined(separator: "、")
        return .message("Codex 相关客户端尚未退出：\(names)。尚未修改登录资料。")
    }
    func quitAndVerify() throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: location.bundleIdentifier)
        var scope = DesktopProcessScope(appPath: location.app.path, roots: Set(apps.map(\.processIdentifier)), snapshot: try processes())
        let outsiders = scope.independentCLI(try processes())
        guard outsiders.isEmpty else { throw blocked(outsiders) }
        quitting = apps
        for app in apps { _ = app.terminate() }
        let grace = Date().addingTimeInterval(5)
        while Date() < grace {
            let live = try processes(); scope.observe(live)
            if scope.blockers(live).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let live = try processes(); scope.observe(live)
            if scope.blockers(live).isEmpty { return }
            for candidate in scope.forceTargets(live) {
                // Re-read microsecond birth time immediately before signalling. Never kill a
                // new process solely because it reused an observed PID or app executable.
                guard let current = try processes().first(where: { $0.pid == candidate.pid }), current.sameInstance(as: candidate) else { continue }
                _ = kill(current.pid, SIGKILL)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw blocked(scope.blockers(try processes()))
    }
    func verifyDesktop(_ credential: Credential, state: DesktopStateStore, authURL: URL) -> Bool {
        let deadline = Date().addingTimeInterval(12)
        var consecutive = 0
        while Date() < deadline {
            let registered = Set(NSRunningApplication.runningApplications(withBundleIdentifier: location.bundleIdentifier).map(\.processIdentifier))
            let running = (try? processes().contains { registered.contains($0.pid) && $0.executable.hasPrefix(location.app.path + "/Contents/MacOS/") }) == true
            let valid = running && DesktopIdentity.matches(credential, auth: try? PrivateFiles.read(authURL), state: try? state.read().data)
            consecutive = valid ? consecutive + 1 : 0
            if consecutive >= 2 { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
    func reopen() throws {
        // LaunchServices may otherwise return the same application instance that is still quitting.
        let exitDeadline = Date().addingTimeInterval(6)
        let exitingPIDs = Set(quitting.map(\.processIdentifier))
        func oldInstanceExists() throws -> Bool { try processes().contains { exitingPIDs.contains($0.pid) } }
        while try oldInstanceExists(), Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.1) }
        guard try !oldInstanceExists() else {
            throw AccountError.message("原 Codex 仍在退出，未确认重新打开。请稍后点击重新打开。")
        }
        quitting = []
        for _ in 0..<2 {
            let semaphore = DispatchSemaphore(value: 0)
            var launched: NSRunningApplication?
            var failure: Error?
            DispatchQueue.main.async {
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                NSWorkspace.shared.openApplication(at: self.location.app, configuration: config) { app, error in
                    launched = app; failure = error; semaphore.signal()
                }
            }
            guard semaphore.wait(timeout: .now() + 15) == .success else { break }
            if failure == nil, let app = launched {
                Thread.sleep(forTimeInterval: 1)
                if try processes().contains(where: { $0.pid == app.processIdentifier && $0.executable.hasPrefix(location.app.path + "/Contents/MacOS/") }) { return }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw AccountError.message("Codex 未能稳定重开；请点击重新打开。当前登录资料保持实际已完成阶段的状态。")
    }
}
