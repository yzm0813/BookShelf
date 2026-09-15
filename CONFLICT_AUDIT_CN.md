# CoverBrowser 与 Simple UI 冲突审查

核心判断：Bookshelf 不能加入现有的 FileChooser 方法包装链；最安全的边界是独立窗口、独立设置文件，并且只使用 KOReader 主菜单注册和 `FileManager.addFileDialogButtons` 两个公开入口。

## CoverBrowser

上传版本的 `main.lua:19-21` 在模块加载时保存 `FileChooser._recalculateDimen`、`updateItems`、`onCloseWidget`。`main.lua:662-704` 会根据显示模式恢复或替换这三个类方法，并附加 `_updateItemsBuildUI`、`_do_cover_images` 等类字段；`main.lua:676-788` 还替换 FileSearcher、History、Collections 的 `updateItemTable` 或生成的 BookList 实例方法。它在 `main.lua:562-618` 以 `coverbrowser_1`、`coverbrowser_2` 注册和删除文件长按按钮。

CoverBrowser 的封面/元数据和显示配置保存在 `bookinfo_cache.sqlite3` 的 `bookinfo/config` 表；首次运行还写全局键 `coverbrowser_initial_default_setup_done`。因此 Bookshelf 不复用其显示配置，不调用其显示模式切换，也不覆盖相同方法；封面读取走 KOReader `FileManagerBookInfo`，处理后的缩略图保存在 Bookshelf 私有缓存中。

## Simple UI

上传版本的 `infra/sui_patches.lua:262-449` 包装 `FileManager.setupLayout/initGesListener/onHome/reinit` 和 `FileChooser.init/changeToPath`；`infra/sui_patches.lua:2942-2968、4432-4497、4819-4869` 继续包装 `FileManager.updateTitleBarPath/paintTo/setupLayout/deleteFile`。`features/library/sui_library_browse.lua:628-873` 包装 `FileChooser.genItemTableFromPath/genItemTable/refreshPath/onMenuSelect/getMenuItemMandatory/showFileDialog/onMenuHold`；`features/library/sui_series_grouping.lua:306-499` 还包装 `switchItemTable/onMenuSelect/onMenuHold/onFolderUp/changeToPath/refreshPath/updateItems`；Folder Covers 又包装 `genItemTableFromPath`。

Simple UI 在 `main.lua:928-949` 首次运行时写全局 `start_with=homescreen_simpleui`，随后安装上述包装；它在 `main.lua:980、1098、1152` 注册 `sui_tbr/sui_browse_author/sui_book_stats` 三个文件长按入口，并在 `onTeardown` 中移除和恢复。主要设置位于 `settings/simpleui/sui_settings.lua`，另有少量明确的全局兼容键。

## Bookshelf 的避让结果

Bookshelf 没有给 FileChooser、FileManager、CoverBrowser、History、Collections 或 FileSearcher 的类/实例方法赋值；长按注册键为 `bookshelf_add_to_shelf`。检测到 Simple UI 时，插件通过其公开的 `QA.register` 注册 `bookshelf_open` 候选动作，并通过 `sui_core.BarInjection.register` 声明 `bookshelf_grid` 页面；同时仅在内存中的 `Config.ALL_ACTIONS` 目录加入同一动作，使 Simple UI 的图标选择页能够列出它，禁用时按对象引用清理该目录项。插件不会修改 Simple UI 源码，不写 `start_with` 或 `simpleui_bar_tabs`；只有用户在 Simple UI 图标选择器中主动选择图标时，Simple UI 自身才写标准键 `simpleui_action_bookshelf_open_icon`。插件只读全局 `home_dir` 与 `language`，不会覆盖 CoverBrowser SQLite 配置或两个插件的文件。阅读返回上下文只放在 UIManager 的进程内存中，KOReader 重启后自动消失。启动书架使用自身布尔设置和 `FileManager.registerPostInitCallback`；默认关闭，回调异常由 `pcall` 捕获并仅写日志。

这消除了方法保存/恢复顺序冲突：无论三个插件按什么路径顺序加载，Bookshelf 都不成为现有 monkey-patch 链的一层，禁用它也不会把 FileChooser/FileManager 恢复到错误版本。
