import SwiftUI
import AccountCore

struct CompactButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .frame(minWidth: 72, minHeight: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 5))
    }
}
struct CircleActionButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 26)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07), in: Circle())
            .contentShape(Circle())
    }
}
struct Panel: View {
    @ObservedObject var model: MenuModel
    var snapshot = false
    var previewSettingsOpen = false
    @State private var settingsOpen = false
    @State private var removing: Profile?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in content(now: context.date) }
            .fixedSize(horizontal: false, vertical: true)
    }
    private func content(now: Date) -> some View {
        VStack(spacing: 8) {
            if model.screen != .accounts {
                HStack {
                    Button { model.screen = .accounts } label: { Text("返回主界面").padding(.horizontal, 8) }
                        .buttonStyle(CompactButton())
                    Spacer()
                }.padding(.horizontal, 4)
            }
            switch model.screen {
            case .accounts: accounts(now: now)
            case .add:
                VStack(alignment: .leading, spacing: 8) {
                    Text("使用 ChatGPT 账号登录。")
                    Text("添加后不会切换当前账号。登录资料仅保存在本机受限目录。").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("登录") { model.login() }.buttonStyle(CompactButton()).disabled(model.busy) }
                }.font(.system(size: 13)).padding(10)
            case .manage:
                compactList {
                    VStack(spacing: 10) {
                        ForEach(model.rows) { row in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: row.profile.identity.email).font(.system(size: 11.5))
                                        .lineLimit(1).minimumScaleFactor(0.9).truncationMode(.middle)
                                    if model.rows.filter({ $0.profile.identity.email == row.profile.identity.email }).count > 1 {
                                        Text("工作区 · \(row.profile.identity.workspace.suffix(8))").font(.system(size: 9)).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .help(row.profile.identity.email)
                                HStack(spacing: 8) {
                                    Button { model.login(row.profile) } label: { Image(systemName: "arrow.clockwise") }
                                        .buttonStyle(CircleActionButton()).help("重新登录")
                                        .accessibilityLabel("重新登录 \(row.profile.identity.email)")
                                    Button { removing = row.profile } label: { Image(systemName: "minus") }
                                        .buttonStyle(CircleActionButton()).foregroundStyle(.red).help("移除账号")
                                        .accessibilityLabel("移除账号 \(row.profile.identity.email)")
                                }.fixedSize(horizontal: true, vertical: false)
                            }.padding(.vertical, 7)
                        }
                        if model.rows.isEmpty { Text("暂无已保存账号").font(.system(size: 12)).foregroundStyle(.secondary).padding(16) }
                    }.padding(.horizontal, 4)
                }.disabled(model.busy)

            }
            if let message = model.message {
                Text(message).help(message).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).textSelection(.enabled)
            }
            if model.loginWaiting { HStack { ProgressView().controlSize(.small); Spacer(); Button("取消") { model.cancelLogin() }.buttonStyle(CompactButton()) }.padding(.horizontal, 8) }
            if model.canReopen { Button("重新打开 Codex") { model.reopen() }.buttonStyle(CompactButton()).disabled(model.busy) }
            if model.screen == .accounts {
                HStack {
                    settingsControl
                    Spacer()
                    if model.refreshing { ProgressView().controlSize(.mini).help("正在更新额度") }
                    Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 28, height: 28) }.help("退出账号工具，不退出 Codex").disabled(model.busy)
                }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
        .padding(10).frame(width: 360).background(.background)
        .overlay(alignment: .bottomLeading) {
            if model.screen == .accounts && (settingsOpen || (snapshot && previewSettingsOpen)) {
                ZStack(alignment: .bottomLeading) {
                    Button { settingsOpen = false } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭设置菜单")
                    SettingsPopup { destination in
                        settingsOpen = false
                        model.screen = destination
                    }
                    .padding(.leading, 14).padding(.bottom, 46)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AccountMenuPopoverClosed"))) { _ in settingsOpen = false }
        .onExitCommand { settingsOpen = false }
        .onDisappear { settingsOpen = false }
        .onChange(of: model.screen) { _, _ in settingsOpen = false }
        .onChange(of: model.busy) { _, busy in if busy { settingsOpen = false } }
        .onAppear { model.refresh() }
        .alert("移除这个账号？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("移除", role: .destructive) { if let p = removing { model.remove(p) }; removing = nil }
        } message: { Text("只移除本工具保存的资料，不注销 Codex，不删除项目或聊天。") }
    }
    private var settingsControl: some View {
        Button { settingsOpen.toggle() } label: {
            Image(systemName: "gearshape").frame(width: 28, height: 28)
        }
        .buttonStyle(.plain).help("设置").accessibilityLabel("设置")
        .accessibilityValue(settingsOpen ? "已展开" : "已收起")
        .disabled(model.busy)
    }
    private func identity(_ row: AccountRow) -> some View {
        Text(verbatim: row.profile.identity.email).font(.system(size: 14, weight: .semibold).width(.expanded)).tracking(0.15).lineLimit(1).minimumScaleFactor(0.8).allowsTightening(false).truncationMode(.middle)
            .help(row.profile.identity.email)

    }
    private func accounts(now: Date) -> some View {
        VStack(spacing: 8) {
            if model.demo { Text("界面预览 · 模拟数据").font(.system(size: 10)).foregroundStyle(.secondary) }
            if model.rows.isEmpty {
                VStack(spacing: 12) {
                    Text("添加账号，随时切换。 ").font(.system(size: 13))
                    if model.externalAccount { Button("收录当前账号") { model.importCurrent() }.buttonStyle(CompactButton()) }
                    Button("添加账号") { model.screen = .add }.buttonStyle(CompactButton())
                }.padding(20).disabled(model.busy)
            } else {
                compactList {
                    VStack(spacing: 8) { ForEach(model.rows) { row in account(row, now: now) } }
                }
                if model.externalAccount { Button("当前账号未收录 · 加入列表") { model.importCurrent() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).disabled(model.busy) }
                Text("切换将关闭并重开 Codex；退出超时会强制关闭。请先完成或停止任务。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 3)
            }
        }
    }
    private func account(_ row: AccountRow, now: Date) -> some View {
        let window = row.usage?.bucket?.selected
        let color: Color = window.map { $0.remaining >= 0.6 ? .green : ($0.remaining >= 0.2 ? .orange : .red) } ?? .gray
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                identity(row)
                HStack(spacing: 5) {
                    Text(row.planLabel).fontWeight(.semibold).lineLimit(1)
                    Text("│").foregroundStyle(.tertiary)
                    Text(window.map { "\($0.label) \($0.resetsAt.map { DateText.remaining($0, now: now) } ?? "待确认")" } ?? "额度待更新").lineLimit(1)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text("Cards").fontWeight(.semibold)
                    Text(row.usage?.rateLimitResetCredits.map { String($0.availableCount) } ?? "—")
                    Text("│").foregroundStyle(.tertiary)
                    Text(row.usage?.rateLimitResetCredits?.expiryLabel(now: now) ?? "到期待确认").lineLimit(1)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if model.rows.filter({ $0.profile.identity.email == row.profile.identity.email }).count > 1 {
                    Text("工作区 · \(row.profile.identity.workspace.suffix(8))").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if let note = row.error ?? row.usage?.note { Text(note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            }.padding(.horizontal, 10).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
            if row.id == model.activeKey {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(white: 0.17))
                    .frame(width: 24, height: 24)
                    .background(Color(red: 1, green: 0.79, blue: 0.12), in: Circle())
                    .overlay(Circle().stroke(Color.black.opacity(0.16), lineWidth: 0.7))
                    .frame(width: 36).frame(maxHeight: .infinity)
                    .background(Color.primary.opacity(0.045))
                    .accessibilityLabel("当前账号").help("当前账号")
            } else {
                Button { model.switchTo(row.profile) } label: { Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .medium)).frame(width: 36).frame(maxHeight: .infinity).contentShape(Rectangle()) }
                    .buttonStyle(.plain).background(Color.primary.opacity(0.045))
                    .disabled(model.busy).help("切换到 \(row.profile.identity.email)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.primary.opacity(0.04)
                    color.opacity(0.18).frame(width: geo.size.width * (window?.remaining ?? 0))
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func compactList<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if model.rows.count > 3 { ScrollView { content() }.frame(height: 350) }
        else { content() }
    }
}

// A single-window floating menu avoids native NSMenu tracking inside a transient NSPopover.
struct SettingsPopup: View {
    let select: (MenuModel.Screen) -> Void
    var body: some View {
        VStack(spacing: 2) {
            Button("添加账号") { select(.add) }
            Button("管理账号") { select(.manage) }
        }
        .buttonStyle(SettingsOptionStyle())
        .padding(5).frame(width: 120)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置选项")
    }
}
struct SettingsOptionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsOptionLabel(configuration: configuration)
    }
    private struct SettingsOptionLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label.font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.09 : 0)), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle()).onHover { hovering = $0 }
        }
    }
}
