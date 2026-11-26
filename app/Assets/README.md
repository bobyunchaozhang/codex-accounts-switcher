# 图标资源

应用和菜单栏使用 Streamline 的 **Ultimate color icons / Like**，经 Iconify 提供，采用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 许可。

- 作者与上游：[Streamline](https://github.com/webalys-hq/streamline-vectors)。
- 图标页面：[streamline-ultimate-color:like](https://icon-sets.iconify.design/streamline-ultimate-color/like/)。
- 原始 SVG：[Iconify API](https://api.iconify.design/streamline-ultimate-color/like.svg)，保存在 `Like.svg`。
- 许可元数据：[Iconify 图标集](https://github.com/iconify/icon-sets/blob/master/json/streamline-ultimate-color.json)。
- 许可全文：[`Streamline-LICENSE.txt`](../Sources/AccountMenu/Resources/Streamline-LICENSE.txt)。

修改：菜单栏版本缩放为 80 × 80 PNG，显示尺寸为 20 × 20 点，保留原配色；应用版本加入白色圆角背景，生成 `AppIcon.svg` 和多尺寸 `AppIcon.icns`。这些图标沿用 CC BY 4.0，项目代码的 MIT 许可不替代图标许可。本项目与 Streamline 无隶属关系，图标使用不表示作者背书。

再分发原图或修改版时，请保留作者、来源和许可链接，标明修改，不增加限制许可使用的条款或技术措施。仓库的 [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) 和许可全文会随应用打包。

## 重新生成

已提交生成好的 PNG 和 ICNS，普通 Swift 构建无需 Node.js。只有修改图标时才需要在 macOS 上安装 Node.js/npm，然后从仓库根目录运行：

```sh
npm ci --prefix app/Assets
npm --prefix app/Assets run generate
```

渲染器固定为 `@resvg/resvg-js` 2.6.2，使用系统 `iconutil` 生成 ICNS。生成过程读取本地 `Like.svg`，不会重新下载上游图标。
