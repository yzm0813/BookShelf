# 基础测试报告

测试基线：KOReader 官方标签 `v2026.07.1`，实际检出提交 `9192014d8bd82a91dc1012473be0f238dedfdb54`；上传的 CoverBrowser 与 Simple UI 均完整解包后审查。测试日期：2026-09-15。

| 场景 | 结果 | 验证方式 |
|---|---|---|
| 插件文件与 Lua 5.1 加载语法 | 通过 | 全部 Lua 文件由 `luaparse` 以 Lua 5.1 模式解析 |
| 创建、重命名、删除、排序分类 | 通过 | 数据模型执行测试；删除分类后原文件存在性不变 |
| 同书多分类、重复路径、加入/移出、分类内排序 | 通过 | `tests/store_spec.lua` 覆盖重复消除、排序和原文件保护 |
| 确认式分类操作 | 通过 | 草稿不触碰 Store；`applyBookCategories` 一次应用已有分类与新分类，并经测试确认只 flush 一次；简化模式仍使用立即切换 |
| 打开书籍并沿用原阅读数据 | 接口通过 | 按 2026.07.1 标准顺序执行 `SetupShowReader → 关闭书架 Grid → nextTick → filemanagerutil.openFile`；进程内记录分类 ID/页码，未创建副本或新阅读记录路径 |
| 阅读进度 | 接口通过 | 读取 2026.07.1 的 `BookList.getBookInfo(path)`；未开始隐藏，完成显示 100% |
| 横竖屏切换 | 静态通过 | 每次布局读取 `Screen:getWidth()/getHeight()`，列数分别持久化，尺寸经 `Screen:scaleBySize()` 计算 |
| 封面百分比、比例、裁剪、间距、圆角、行数 | 通过 | 设置路径独立；更新时调用当前 Grid 的 `refreshLayout()`；缓存键 8 项失效检查通过（含渲染版本） |
| 字体缺失 | 通过 | `FontChooser.isFontRegistered()` 校验，失败回退 `Font:getFace("cfont", size)` |
| 文件路径失效与暂时卸载存储 | 通过 | 失效记录可显示/隐藏；书库根不可用时清理拒绝执行；根外路径保守保留 |
| 未分类扫描 | 通过 | `tests/scanner_spec.lua` 覆盖递归、格式过滤、`.sdr/cache` 排除及已分类过滤 |
| 首页分类与未分类单书混排 | 通过 | `tests/main_spec.lua` 验证分类在前、未分类书籍为独立 `book` 卡片且不存在中转卡片 |
| 未分类列表文件名解析 | 通过 | 使用 2026.07.1 的 `filemanagerutil.splitFileNameType`；静态回归检查禁止调用不存在的 `util.splitFileNameType` |
| 分类返回及阅读返回 | 接口通过 | 分类 Grid 在构造时设置 `onReturn`；阅读返回上下文只驻留 UIManager 内存，分类失效时安全回到书架首页 |
| Simple UI 独立底栏候选项 | 通过 | `tests/main_spec.lua` 验证 `bookshelf_open` 与 `bookshelf_grid_nav` 注册/注销；不写 `simpleui_bar_tabs` |
| 卡片高度与四边圆角边框 | 几何通过 | 图片按边框宽度内缩，`CoverFrame` 在子图片之后最后绘制黑色圆角边框；缓存渲染版本升级为 3 |
| 与 Simple UI、CoverBrowser 同时启用 | 静态兼容通过 | 使用 Simple UI 的 QA 与 Bar Injection 公开注册接口，没有目标类方法赋值或对方设置键写入 |
| 禁用恢复 | 通过 | `stopPlugin/onTeardown` 关闭活动 Grid、注销动作及页面描述、移除文件长按入口，只刷新私有设置 |

限制：当前环境不是 Kindle，也没有 KOReader 的 ARM 原生运行库，因此“接口通过/静态通过”不等于实体设备触控、字体渲染和墨水屏刷新验收。安装前建议保留 `settings/bookshelf.lua` 的副本；插件默认不接管启动页，首次测试应从主菜单手动进入。
