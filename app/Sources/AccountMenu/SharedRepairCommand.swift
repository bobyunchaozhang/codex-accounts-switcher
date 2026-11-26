import Foundation
import AppKit
import AccountCore

/// Explicit maintenance command. Preparing is read-only; applying never quits or switches a client.
enum SharedRepairCommand {
    struct Receipt: Codable { let backupName: String; let beforeDigest: String; let afterDigest: String }
    static func run(apply: Bool, file: String) -> Int32 {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let state = DesktopStateStore(home: home)
            try state.requireJSONStorage()
            let stateURL = state.jsonURL
            let authURL = home.appendingPathComponent("auth.json")
            let warehouse = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccounts")
            let auth = try PrivateFiles.read(authURL), active = try Credential(auth)
            let profiles = try JSONDecoder().decode([Profile].self, from: PrivateFiles.read(warehouse.appendingPathComponent("accounts.json")))
            let accounts = try profiles.map { profile -> Credential in
                guard profile.id.count == 64, profile.id.allSatisfy({ $0.isHexDigit }) else { throw AccountError.message("保存账号标识无效。") }
                return try Credential(PrivateFiles.read(warehouse.appendingPathComponent("profiles/\(profile.id).json")))
            }
            let planURL = URL(fileURLWithPath: file).standardizedFileURL
            if !apply {
                let before = try PrivateFiles.read(stateURL)
                let plan = try SharedContinuity.prepareRepair(before, active: active, accounts: accounts, home: home)
                // Compute the proposed result now as well: no deferred schema surprises during application.
                _ = try SharedContinuity.repairState(before, plan: plan, active: active, accounts: accounts, home: home)
                try PrivateFiles.directory(planURL.deletingLastPathComponent())
                try PrivateFiles.write(JSONEncoder().encode(plan), to: planURL)
                print("仅生成恢复候选，未修改真实视图／登录。候选项目：")
                plan.projectNames.forEach { print("• \($0)") }
                print("候选保留两边现存项目；可能包含以前删除过但旧视图仍有的项目，请核对后再应用。")
                return 0
            }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.accounts").filter({ $0.processIdentifier != getpid() }).isEmpty else {
                throw AccountError.message("请先退出旧的账号切换工具，再运行恢复；未修改资料。")
            }
            let desktop = Desktop(try ClientLocation.discover())
            try desktop.requireStopped()
            let before = try PrivateFiles.read(stateURL)
            let plan = try JSONDecoder().decode(SharedContinuity.RepairPlan.self, from: PrivateFiles.read(planURL))
            let after = try SharedContinuity.repairState(before, plan: plan, active: active, accounts: accounts, home: home)
            let backups = warehouse.appendingPathComponent("project-view-backups")
            try PrivateFiles.directory(backups)
            let backup = backups.appendingPathComponent("repair-before-\(UUID().uuidString).json")
            try PrivateFiles.write(before, to: backup)
            try desktop.requireStopped()
            try state.requireJSONStorage()
            guard try PrivateFiles.read(stateURL) == before, try PrivateFiles.read(authURL) == auth else { throw AccountError.message("恢复前资料发生变化，已停止。") }
            try PrivateFiles.write(after, to: stateURL)
            do {
                guard try PrivateFiles.read(stateURL) == after, try PrivateFiles.read(authURL) == auth else { throw AccountError.message("恢复后资料核对失败，已保留备份。") }
                let receipt = Receipt(backupName: backup.lastPathComponent, beforeDigest: try SharedContinuity.digest(before), afterDigest: try SharedContinuity.digest(after))
                try PrivateFiles.write(JSONEncoder().encode(receipt), to: warehouse.appendingPathComponent("last-shared-repair.json"))
                try SharedContinuity.activated(active, checkpoint: warehouse.appendingPathComponent("shared-view-checkpoint.json"), state: after)
            } catch {
                if (try? PrivateFiles.read(stateURL)) == after { try? PrivateFiles.write(before, to: stateURL) }
                throw error
            }
            print("共享视图恢复完成；账号未切换，聊天正文和数据库未改写。")
            print("原状态备份：\(backup.path)")
            print("现在可以打开 Codex，再打开新版账号工具进行验证。")
            return 0
        } catch { print("未完成：\(error.localizedDescription)"); return 1 }
    }

    static func undo() -> Int32 {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let state = DesktopStateStore(home: home)
            try state.requireJSONStorage()
            let warehouse = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexAccounts")
            guard NSRunningApplication.runningApplications(withBundleIdentifier:"local.codex.accounts").filter({ $0.processIdentifier != getpid() }).isEmpty else { throw AccountError.message("请先退出账号工具。") }
            let desktop = Desktop(try ClientLocation.discover()); try desktop.requireStopped()
            let stateURL = state.jsonURL, authURL = home.appendingPathComponent("auth.json")
            let auth = try PrivateFiles.read(authURL), credential = try Credential(auth)
            let receipt = try JSONDecoder().decode(Receipt.self, from: PrivateFiles.read(warehouse.appendingPathComponent("last-shared-repair.json")))
            guard receipt.backupName.hasPrefix("repair-before-"), !receipt.backupName.contains("/"), receipt.backupName.hasSuffix(".json") else { throw AccountError.message("恢复记录无效。") }
            let backups = warehouse.appendingPathComponent("project-view-backups")
            let original = try PrivateFiles.read(backups.appendingPathComponent(receipt.backupName))
            guard try SharedContinuity.digest(original) == receipt.beforeDigest else { throw AccountError.message("恢复备份核对失败。") }
            let before = try PrivateFiles.read(stateURL)
            let after = try SharedContinuity.undoRepair(current:before,before:original,expectedAfterDigest:receipt.afterDigest,active:credential)
            try PrivateFiles.write(before,to:backups.appendingPathComponent("undo-before-\(UUID().uuidString).json"))
            try desktop.requireStopped()
            try state.requireJSONStorage()
            guard try PrivateFiles.read(stateURL) == before, try PrivateFiles.read(authURL) == auth else { throw AccountError.message("撤销前资料变化，已停止。") }
            let checkpoint = warehouse.appendingPathComponent("shared-view-checkpoint.json")
            if FileManager.default.fileExists(atPath:checkpoint.path) { try FileManager.default.removeItem(at:checkpoint) }
            try PrivateFiles.write(after,to:stateURL)
            guard try PrivateFiles.read(stateURL) == after else { throw AccountError.message("撤销保存核对失败，备份已保留。") }
            print("已撤销此次共享视图恢复；未切换账号、未修改聊天正文。重新使用新版切换前需再次核对共享视图。")
            return 0
        } catch { print("未撤销：\(error.localizedDescription)"); return 1 }
    }
}
