## 未发布 / Unreleased

- 修复 SwiftPM 资源包在已安装应用中的定位，避免启动时找不到字体或图标。
- 弹窗打开前按内容计算尺寸，并随内容更新高度，修复面板与菜单栏图标距离过大的问题。
- 应用与菜单栏改用 Streamline 的彩色 Like 图标，补齐应用 ICNS、署名、CC BY 4.0 许可全文、修改说明和图标生成脚本。
- Resolve bundled SwiftPM resources from the installed app before falling back to package resources.
- Size the popover before presentation and track its preferred content size to address the gap below the menu bar.
- Add the Streamline Like application/menu bar icons, attribution, full CC BY 4.0 license, modification notes, and reproducible icon generation.

## 0.1.15 — 中文

Codex Accounts 0.1.15（构建 16），macOS 14+。

- Apple Silicon 下载 `arm64.zip`；Intel 下载 `x86_64.zip`。
- 适配 Codex 26.1106 的公共项目／聊天清单及新身份字段，保留旧快照适配。
- 修复旧交接记录误阻断及额度查询失败导致当前标记消失的问题。
- 最近实验核查 Codex：26.1106.51428（26605）。84 项核心及 2 项隔离生命周期测试通过；该版真实在线往返仍待验收，实体 Intel Mac 的真实切换未验收。
- ZIP 采用 ad-hoc 签名，未经过 Apple 公证；每个包附 SHA-256 文件。安装与限制见默认中文 README。

## 0.1.15 — English

Codex Accounts 0.1.15 (build 16), macOS 14+.

- Download `arm64.zip` for Apple Silicon or `x86_64.zip` for Intel.
- Supports Codex 26.1106 shared project/chat catalogs and identity markers, retaining the legacy adapter.
- Fixes stale-checkpoint blocking and current-marker loss after usage-query failures.
- Latest experimentally inspected Codex: 26.1106.51428 (26605). 84 core and 2 isolated lifecycle tests passed; real online acceptance on this version and real switching on physical Intel hardware remain pending.
- Ad-hoc signed, not Apple-notarized. Each package has a SHA-256 file. See README.en.md for installation and limits.
