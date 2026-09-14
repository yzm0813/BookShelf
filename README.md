# BookShelf for KOReader

2026-09-14：修复从书架卡片打开书籍时，与 Simple UI/KOReader 阅读器启动流程之间的界面关闭顺序冲突。

一个面向 KOReader 2026.07.1 的独立虚拟封面书架插件。分类仅保存电子书原路径与排序信息，同一本书可以加入多个分类；插件不会移动或删除电子书，也不会覆盖 FileChooser、FileManager、Simple UI 或 CoverBrowser 的方法和设置。

安装、使用、恢复与已知限制见 [README_CN.md](README_CN.md)，兼容性审查见 [CONFLICT_AUDIT_CN.md](CONFLICT_AUDIT_CN.md)，测试范围见 [TEST_REPORT_CN.md](TEST_REPORT_CN.md)。

## 安装

下载仓库后，将仓库目录命名为 `bookshelf.koplugin` 并完整复制到 `koreader/plugins/`，然后完全重启 KOReader。首次从“主菜单 → 书架 → 打开书架”进入；自动启动默认关闭。
