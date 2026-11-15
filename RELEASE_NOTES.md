## 中文

Codex Accounts 0.1.15（构建 16），macOS 14+。

- Apple Silicon 下载 `arm64.zip`；Intel 下载 `x86_64.zip`。
- 适配 Codex 26.1106 的公共项目／聊天清单及新身份字段，保留旧快照适配。
- 修复旧交接记录误阻断及额度查询失败导致当前标记消失的问题。
- 最近实验核查 Codex：26.1106.51428（26605）。84 项核心及 2 项隔离生命周期测试通过；该版真实在线往返仍待验收，实体 Intel Mac 的真实切换未验收。
- ZIP 采用 ad-hoc 签名，未经过 Apple 公证；每个包附 SHA-256 文件。安装与限制见默认中文 README。

## English

Codex Accounts 0.1.15 (build 16), macOS 14+.

- Download `arm64.zip` for Apple Silicon or `x86_64.zip` for Intel.
- Supports Codex 26.1106 shared project/chat catalogs and identity markers, retaining the legacy adapter.
- Fixes stale-checkpoint blocking and current-marker loss after usage-query failures.
- Latest experimentally inspected Codex: 26.1106.51428 (26605). 84 core and 2 isolated lifecycle tests passed; real online acceptance on this version and real switching on physical Intel hardware remain pending.
- Ad-hoc signed, not Apple-notarized. Each package has a SHA-256 file. See README.en.md for installation and limits.
