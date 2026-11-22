## 中文

Codex Accounts 0.1.16（构建 17），macOS 14+，需安装 Codex 桌面应用。

- 修复已安装应用中 SwiftPM 资源包的定位，避免启动时找不到字体或图标。
- 弹窗打开前按内容计算尺寸，并随内容更新高度，修复面板与菜单栏图标距离过大的问题。
- 应用和菜单栏改用 Streamline 的彩色 Like 图标。安装包包含署名、CC BY 4.0 许可全文及修改说明；仓库提供原始 SVG 和固定版本的图标生成脚本。
- Apple Silicon 下载 `Codex-Accounts-0.1.16-arm64.zip`；Intel 下载 `Codex-Accounts-0.1.16-x86_64.zip`。每个包均附 SHA-256 校验文件。
- 解压后用新应用替换「应用程序」中的旧版本。ZIP 采用 ad-hoc 签名，未经过 Apple 公证；首次打开若被拦截，按 README 中的系统设置步骤允许打开。
- 最新实验核查的 Codex 仍为 26.1106.51428（26605）；本次不新增真实在线换号或实体 Intel Mac 验收结论。

## English

Codex Accounts 0.1.16 (build 17), macOS 14+. Requires the Codex desktop app.

- Resolve SwiftPM resource bundles from the installed app, preventing missing-font or missing-icon startup failures.
- Size the popover before presentation and track its preferred content size to address the gap below the menu bar.
- Use the Streamline color Like icon for the app and menu bar. Packages include attribution, the full CC BY 4.0 license and modification notes. The repository includes the original SVG and a pinned icon-generation toolchain.
- Download `Codex-Accounts-0.1.16-arm64.zip` for Apple Silicon or `Codex-Accounts-0.1.16-x86_64.zip` for Intel. Each archive has a SHA-256 checksum file.
- Extract and replace the old app in Applications. Packages are ad-hoc signed, not Apple-notarized; see README.en.md for first-launch instructions.
- The latest experimentally inspected Codex remains 26.1106.51428 (26605). This release adds no new real online account-switching or physical Intel Mac acceptance results.

Icon attribution and license: [Third-party notices](https://github.com/bobyunchaozhang/codex-accounts-switcher/blob/v0.1.16/THIRD_PARTY_NOTICES.md).
