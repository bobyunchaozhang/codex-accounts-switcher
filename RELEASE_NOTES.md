## 中文

Codex Accounts 0.1.17（构建 18），支持 macOS 14 及以上，需安装 Codex 桌面应用。

- 修复 Codex 将桌面状态迁移到 SQLite 后，切换器读取旧 JSON 导致误报身份不一致、无法换号的问题。
- 切换前和重开后从 SQLite 只读核对桌面身份。旧版 JSON 仍可用。
- 已在 Apple Silicon 上手动验证 Codex 26.1120.50957（构建 30866）的账号切换。
- Apple Silicon 下载 arm64 ZIP，Intel 下载 x86_64 ZIP。解压后替换「应用程序」中的旧版本。两个安装包各附 SHA-256 校验文件，采用 ad-hoc 签名，未经过 Apple 公证。

## English

Codex Accounts 0.1.17 (build 18) requires macOS 14 or later and the Codex desktop app.

- Fixes a false identity mismatch that blocked account switching after Codex migrated desktop state from JSON to SQLite.
- Reads desktop identity from SQLite before switching and after reopening. Older JSON storage remains supported.
- Manual account switching passed on Apple Silicon with Codex 26.1120.50957 (build 30866).
- Download the arm64 ZIP for Apple Silicon or the x86_64 ZIP for Intel. Extract it and replace the old app in Applications. Each package has a SHA-256 checksum and uses ad-hoc signing without Apple notarization.

[Icon attribution and license](https://github.com/bobyunchaozhang/codex-accounts-switcher/blob/v0.1.17/THIRD_PARTY_NOTICES.md)
