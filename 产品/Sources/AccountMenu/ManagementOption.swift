import SwiftUI

// Mock-only layout alternatives, never connected to authentication or deletion.
struct ManagementOption: View {
    let option: Int
    private let emails = ["lin@example.com", "alexander.zhang1997@gmail.com"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(["A · 轻分隔", "B · 两行留白", "C · 行内操作"][option])
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Button("返回主界面") {}.buttonStyle(CompactButton()).padding(.bottom, 4)
                ForEach(emails, id: \.self) { email in
                    if option == 0 {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(verbatim: email).font(.system(size: 12))
                            HStack { Spacer(); actions }
                        }.padding(.vertical, 3)
                        if email != emails.last { Divider().opacity(0.35) }
                    } else if option == 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: email).font(.system(size: 12))
                            HStack { actions; Spacer() }
                        }.padding(.vertical, 7)
                    } else {
                        HStack(spacing: 8) {
                            Text(verbatim: email).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                .frame(width: 200, alignment: .leading).clipped()
                            actions
                        }.padding(.vertical, 7)
                    }
                }
            }.padding(12).frame(width: 360).background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 12))
        }.padding(16).background(Color(white: 0.09))
    }
    private var actions: some View {
        HStack(spacing: 12) {
            Button("重新登录") {}.buttonStyle(CompactButton())
            Button("移除") {}.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.red).frame(minHeight: 28)
        }
    }
}
