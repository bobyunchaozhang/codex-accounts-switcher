import AppKit
import SwiftUI
import CoreText

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var model: MenuModel!
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        for name in ["ChakraPetch-BoldItalic", "ChakraPetch-Bold"] { if let font = Bundle.module.url(forResource: name, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil) } }
        let demo = (CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--demo-menu"))
        model = MenuModel(demo: demo)
        let panel = Panel(model: model)
        if demo && !CommandLine.arguments.contains("--demo-menu") {
            let host = NSHostingController(rootView: panel)
            let w = NSWindow(contentViewController: host)
            w.title = "Codex Accounts · 界面预览"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 360, height: 320)); w.center(); w.makeKeyAndOrderFront(nil)
            window = w; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = AccountBoxIcon.image()
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover = NSPopover(); popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: panel)
    }
    func popoverDidClose(_ notification: Notification) {
        NotificationCenter.default.post(name: Notification.Name("AccountMenuPopoverClosed"), object: nil)
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); model.refresh() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.busy == true ? .terminateCancel : .terminateNow
    }
}
if CommandLine.arguments.contains("--undo-shared-repair") { exit(SharedRepairCommand.undo()) }
if CommandLine.arguments.contains("--check-processes-readonly") {
    do { try Desktop(ClientLocation.discover()).reportReadOnly(); exit(0) }
    catch { print(error.localizedDescription); exit(1) }
}
for flag in ["--prepare-shared-repair", "--apply-shared-repair"] {
    if let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > index + 1 {
        exit(SharedRepairCommand.run(apply: flag == "--apply-shared-repair", file: CommandLine.arguments[index + 1]))
    }
}
if CommandLine.arguments.contains("--check-shared-state-readonly") { exit(Probe.sharedStateReadOnly()) }
if CommandLine.arguments.contains("--check-project-sync-readonly") { exit(Probe.projectSyncReadOnly()) }
if CommandLine.arguments.contains("--check-current-readonly") { exit(Probe.run()) }
if CommandLine.arguments.contains("--check-project-view-readonly") { exit(Probe.projectViewReadOnly()) }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.indices.contains(i + 1) {
        for name in ["ChakraPetch-BoldItalic", "ChakraPetch-Bold"] { if let font = Bundle.module.url(forResource: name, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil) } }
        let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = MenuModel(demo: true)
        for (name, screen) in [("accounts", MenuModel.Screen.accounts), ("manage", .manage), ("add", .add), ("settings", .accounts)] {
            model.screen = screen
            let renderer = ImageRenderer(content: Panel(model: model, snapshot: true, previewSettingsOpen: name == "settings").environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let image = renderer.cgImage {
                let bitmap = NSBitmapImageRep(cgImage: image)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }
        model.screen = .accounts
        let lightRenderer = ImageRenderer(content: Panel(model: model, snapshot: true).environment(\.colorScheme, .light))
        lightRenderer.scale = 2
        if let image = lightRenderer.cgImage {
            try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("accounts-light.png"))
        }
        for name in ["DINAlternate-Bold", "Menlo-Bold", "ChakraPetch-Bold"] { print("font_available[\(name)]=\(NSFont(name:name,size:17) != nil)") }
        let fontRenderer = ImageRenderer(content: FontComparison().environment(\.colorScheme, .dark))
        fontRenderer.scale = 2
        if let image = fontRenderer.cgImage {
            try! NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("fonts.png"))
        }
        for option in 0..<3 {
            let renderer = ImageRenderer(content: ManagementOption(option: option).environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let image = renderer.cgImage {
                try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("manage-option-\(option + 1).png"))
            }
        }
        let icon = AccountBoxIcon.image()
        try! NSBitmapImageRep(data: icon.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("account-box.png"))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
