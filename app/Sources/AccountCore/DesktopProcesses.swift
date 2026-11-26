import Foundation

public struct DesktopProcess: Equatable, Sendable {
    public let pid: Int32
    public let parent: Int32
    public let executable: String
    public let birth: String
    public init(pid: Int32, parent: Int32, executable: String, birth: String) {
        self.pid = pid; self.parent = parent; self.executable = executable; self.birth = birth
    }
    public func sameInstance(as other: Self) -> Bool {
        pid == other.pid && executable == other.executable && birth == other.birth && !birth.isEmpty
    }
}

/// Track process instances, not just PIDs or a shared installation directory.
public struct DesktopProcessScope {
    public let appPath: String
    private var observed: [Int32: DesktopProcess] = [:]
    public init(appPath: String, roots: Set<Int32>, snapshot: [DesktopProcess]) {
        self.appPath = appPath
        for p in snapshot where roots.contains(p.pid) { observed[p.pid] = p }
        observe(snapshot)
    }
    public mutating func observe(_ rows: [DesktopProcess]) {
        var changed = true
        while changed {
            changed = false
            for p in rows where observed[p.pid] == nil {
                guard let parent = rows.first(where: { $0.pid == p.parent }), owns(parent) else { continue }
                observed[p.pid] = p; changed = true
            }
        }
    }
    public func owns(_ p: DesktopProcess) -> Bool { observed[p.pid].map { $0.sameInstance(as: p) } ?? false }
    private func auxiliary(_ p: DesktopProcess) -> Bool {
        p.executable.hasPrefix(appPath + "/Contents/Frameworks/") &&
        URL(fileURLWithPath: p.executable).lastPathComponent == "browser_crashpad_handler"
    }
    public func independentCLI(_ rows: [DesktopProcess]) -> [DesktopProcess] {
        rows.filter { URL(fileURLWithPath: $0.executable).lastPathComponent == "codex" && !owns($0) }
    }
    public func blockers(_ rows: [DesktopProcess]) -> [DesktopProcess] {
        rows.filter { p in
            if auxiliary(p) { return false }
            if URL(fileURLWithPath: p.executable).lastPathComponent == "codex" { return true }
            if p.executable == appPath + "/Contents/MacOS/ChatGPT" || p.executable == appPath + "/Contents/MacOS/Codex" { return true }
            let name = URL(fileURLWithPath: p.executable).lastPathComponent
            if p.executable.hasPrefix(appPath + "/Contents/Frameworks/"), name.hasPrefix("Codex (") || name.hasPrefix("ChatGPT Helper") { return true }
            return owns(p) && p.executable.hasPrefix(appPath + "/")
        }
    }
    /// Workspace registration can outlive the process. It is only a PID hint,
    /// never independent evidence that an application is still executing.
    public func remainingClients(_ rows: [DesktopProcess], registeredPIDs: Set<Int32>) -> [DesktopProcess] {
        let known = Set(blockers(rows).map(\.pid))
        return rows.filter { known.contains($0.pid) || registeredPIDs.contains($0.pid) }
    }
    public func forceTargets(_ rows: [DesktopProcess]) -> [DesktopProcess] {
        blockers(rows).filter { owns($0) && $0.executable.hasPrefix(appPath + "/") }
    }
}
