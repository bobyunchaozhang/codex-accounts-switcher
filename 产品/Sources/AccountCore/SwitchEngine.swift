import Foundation

public enum TaskActivity { case running, idle, unknown }
public struct SwitchOperations {
    public var activity: () throws -> TaskActivity
    public var validateTarget: (Credential) throws -> Credential
    public var stopDesktop: () throws -> Void
    public var savePrevious: (Credential) throws -> Void
    public var verifyWritten: (Credential) throws -> Void
    public var reopen: () throws -> Void
    public var beforeCommit: () throws -> Void
    public var preflightView: (Credential) throws -> Void
    public var credentialsChanged: (Credential) throws -> Void
    public var verifyDesktop: (Credential) -> Bool
    public var prepareProjectView: (Credential, Credential) throws -> Void
    public init(activity: @escaping () throws -> TaskActivity, validateTarget: @escaping (Credential) throws -> Credential,
                stopDesktop: @escaping () throws -> Void, savePrevious: @escaping (Credential) throws -> Void,
                verifyWritten: @escaping (Credential) throws -> Void, reopen: @escaping () throws -> Void,
                prepareProjectView: @escaping (Credential, Credential) throws -> Void = { _, _ in },
                preflightView: @escaping (Credential) throws -> Void = { _ in },
                credentialsChanged: @escaping (Credential) throws -> Void = { _ in },
                verifyDesktop: @escaping (Credential) -> Bool = { _ in false },
                beforeCommit: @escaping () throws -> Void = {}) {
        self.activity = activity; self.validateTarget = validateTarget; self.stopDesktop = stopDesktop
        self.savePrevious = savePrevious; self.verifyWritten = verifyWritten; self.reopen = reopen
        self.prepareProjectView = prepareProjectView
        self.beforeCommit = beforeCommit; self.preflightView = preflightView; self.credentialsChanged = credentialsChanged; self.verifyDesktop = verifyDesktop
    }
}
public struct SwitchOutcome {
    public let targetWritten: Bool
    public let identityVerified: Bool
    public let needsReopen: Bool
    public let message: String?
    public var desktopVerified: Bool = false
    public var failureMessage: String? = nil
    public var reopenFailure: String? = nil
}

public enum SwitchEngine {
    public static func run(target: Credential, transaction: AuthTransaction, operations op: SwitchOperations,
                           progress: (String) -> Void = { _ in }) -> SwitchOutcome {
        var attemptedQuit = false
        var verified = false
        var written = false
        do {
            guard try op.activity() != .running else { throw AccountError.message("有任务正在运行，请完成或停止后再切换。") }
            guard try transaction.journal == nil else { throw AccountError.message("上次切换尚未核对，请先处理恢复状态。") }
            let initial = try? PrivateFiles.read(transaction.active)
            if let initial, let c = try? Credential(initial), c.identity.matches(target.identity) {
                try op.verifyWritten(c)
                var desktopVerified = op.verifyDesktop(c)
                if !desktopVerified {
                    do { try op.reopen(); desktopVerified = op.verifyDesktop(c) }
                    catch { return SwitchOutcome(targetWritten: false, identityVerified: true, needsReopen: true, message: error.localizedDescription) }
                }
                return SwitchOutcome(targetWritten: false, identityVerified: true, needsReopen: false, message: desktopVerified ? nil : "活动凭证已是目标账号；桌面身份尚未确认。", desktopVerified: desktopVerified)
            }
            if let initial { try op.preflightView(Credential(initial)) }
            progress("正在核验目标账号…")
            let ready = try op.validateTarget(target)
            guard ready.identity.matches(target.identity) else { throw AccountError.message("目标登录身份不一致，未切换。") }
            // Changes to A during preflight are expected on refresh, but a different identity is not.
            let beforeQuit = try? PrivateFiles.read(transaction.active)
            if let initial, let beforeQuit, let a = try? Credential(initial), let b = try? Credential(beforeQuit), !a.identity.matches(b.identity) {
                throw AccountError.message("准备期间当前账号发生变化，请重试。")
            }
            guard try op.activity() != .running else { throw AccountError.message("有任务正在运行，请完成或停止后再切换。") }
            progress("正在退出 Codex…")
            attemptedQuit = true
            try op.stopDesktop()
            let prior = FileManager.default.fileExists(atPath: transaction.active.path) ? try PrivateFiles.read(transaction.active) : nil
            if let beforeQuit, let prior, let before = try? Credential(beforeQuit), let after = try? Credential(prior), !before.identity.matches(after.identity) {
                throw AccountError.message("退出期间账号发生外部变化，未继续切换。")
            }
            if let prior, let c = try? Credential(prior) {
                try op.savePrevious(c)
                progress("正在核对共享视图…")
                try op.prepareProjectView(c, ready)
            }
            try transaction.prepare(target: ready, expectedCurrent: prior)
            progress("正在切换登录资料…")
            progress("正在确认写入前客户端状态…")
            try op.beforeCommit()
            try transaction.commit()
            written = true
            try op.credentialsChanged(ready)
            let installed = try Credential(PrivateFiles.read(transaction.active))
            guard installed.identity.matches(target.identity) else { throw AccountError.message("写入后身份不符，已保留恢复资料。") }
            try op.verifyWritten(installed)
            verified = true
            try transaction.finish()
            try op.reopen()
            progress("正在核对桌面身份…")
            let desktopVerified = op.verifyDesktop(installed)
            return SwitchOutcome(targetWritten: true, identityVerified: true, needsReopen: false, message: desktopVerified ? nil : "目标凭证已写入；桌面身份尚未确认，请核对客户端账号。", desktopVerified: desktopVerified)
        } catch {
            var recoveryNote = ""
            if written, let failure = error as? AccountError {
                switch failure {
                case .authenticationRejected, .identityMismatch:
                    do { try transaction.rollback(); written = false; if let restored = try? Credential(PrivateFiles.read(transaction.active)) { try op.credentialsChanged(restored) }; recoveryNote = " 已恢复切换前的登录资料。" }
                    catch { recoveryNote = " 自动恢复未完成，已保留恢复资料。" }
                case .message: break
                }
            }
            let current = try? Credential(PrivateFiles.read(transaction.active))
            // Also handles a crash-like error after rename but before the journal-stage update.
            if attemptedQuit, current?.identity.matches(target.identity) == true { written = true }
            if written, recoveryNote.isEmpty { try? transaction.finish() }
            else if let j = try? transaction.journal, let current, j.prior?.matches(current.identity) == true { try? transaction.finish() }
            var needsReopen = attemptedQuit
            var reopenFailure: String?
            if attemptedQuit { do { try op.reopen(); needsReopen = false } catch { needsReopen = true; reopenFailure = error.localizedDescription } }
            return SwitchOutcome(targetWritten: written, identityVerified: verified, needsReopen: needsReopen,
                                 message: error.localizedDescription + recoveryNote + (written && !verified && recoveryNote.isEmpty ? " 已保留目标账号，身份暂未确认。" : "") + (reopenFailure == nil ? "" : " 重新打开也未完成，可点击重新打开。"),
                                 failureMessage: error.localizedDescription, reopenFailure: reopenFailure)
        }
    }
}
