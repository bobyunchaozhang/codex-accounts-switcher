import SwiftUI

struct FontComparison: View {
    private func example(_ tag: String, _ title: String, _ note: String, _ font: Font, tracking: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(tag).font(.system(size: 12, weight: .bold)).foregroundStyle(.yellow); Text(title).font(.system(size: 13, weight: .semibold)); Spacer(); Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
            Text(verbatim: "alexander.zhang1997@gmail.com").font(font).tracking(tracking)
            Text(verbatim: "lin@example.com").font(font).tracking(tracking)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("邮箱标题字体对比").font(.system(size: 19, weight: .semibold))
            Text("同为 17 pt、直立字形；使用模拟邮箱。字距略作调整以符合宽松、硬朗的方向。").font(.system(size: 11)).foregroundStyle(.secondary)
            example("A", "Chakra Petch Bold", "棱角明显 · 本版暂用", .custom("ChakraPetch-Bold", size: 17), tracking: 0.4)
            example("B", "SF Pro Expanded Semibold", "宽展 · 稳重 · 原生", .system(size: 17, weight: .semibold).width(.expanded), tracking: 0.25)
            example("C", "DIN Alternate Bold", "工业感 · 克制", .custom("DINAlternate-Bold", size: 17), tracking: 0.7)
            example("D", "Menlo Bold", "等宽 · 技术感", .custom("Menlo-Bold", size: 17), tracking: 0.35)
        }.padding(22).frame(width: 600).background(.background)
    }
}
