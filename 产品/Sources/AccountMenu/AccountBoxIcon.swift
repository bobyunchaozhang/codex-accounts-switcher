import AppKit

// Streamline Ultimate Color / Like, CC BY 4.0. See THIRD_PARTY_NOTICES.md.
enum AccountBoxIcon {
    static func image() -> NSImage {
        guard let url = Bundle.accountMenuResources.url(forResource: "Like-Menu", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing Like menu bar icon")
        }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = false
        image.accessibilityDescription = "Codex 账号"
        return image
    }
}
