# 基础测试报告

测试基线：KOReader 官方标签 `v2026.07.1`，实际检出提交 `9192014d8bd82a91dc1012473be0f238dedfdb54`；上传的 CoverBrowser 与 Simple UI 均完整解包后审查。测试日期：2026-09-15。

| 场景 | 结果 | 验证方式 |
|---|---|---|
| 插件文件与 Lua 5.1 加载语法 | 通过 | 全部 Lua 文件由 `luaparse` 以 Lua 5.1 模式解析 |
| 设置原子写入与失败回滚 | 通过 | 设置先同步写入同目录 `.tmp` 再 rename；Store 故障注入验证 relocate 写失败后分类、封面和 metadata 内存状态完整回滚 |
| 创建、重命名、删除、排序分类 | 通过 | 数据模型执行测试；删除分类后原文件存在性不变 |
| 同书多分类、重复路径、加入/移出、分类内排序 | 通过 | `tests/store_spec.lua` 覆盖重复消除、排序和原文件保护 |
| 确认式分类操作 | 通过 | 草稿不触碰 Store；`applyBookCategories` 一次应用已有分类与新分类，并经测试确认只 flush 一次；简化模式仍使用立即切换 |
| 打开书籍并沿用原阅读数据 | 接口通过 | 按 2026.07.1 标准顺序执行 `SetupShowReader → 关闭书架 Grid → nextTick → filemanagerutil.openFile`；进程内记录分类 ID/页码，未创建副本或新阅读记录路径 |
| 阅读进度与角标底色 | 几何通过 | 读取 2026.07.1 的 `BookList.getBookInfo(path)`；未开始隐藏，完成显示 100%；`grid_geometry_spec.lua` 检查横竖屏、2/3/4/5 列、50%/75%/100%、三种固定比例下角标不越过封面宽度；白/灰底黑字、黑底白字，`1%` 到 `100%` 共用固定外框 |
| 角标颜色即时应用 | 静态通过 | `RibbonBadge.paintTo()` 每次从当前设置解析白/灰/黑底色及相应文字色；切换设置后重建活动网格并标记整个窗口栈重绘，避免主菜单保存的旧底图覆盖新颜色 |
| 横竖屏切换与返回页码 | 自动几何 + 静态通过 | 每次布局读取 `Screen:getWidth()/getHeight()`，列数分别持久化；修复 `Menu:init()` 将请求页码重置为 1，旋转或返回时在首次分页计算中恢复并夹紧页码 |
| 封面百分比、比例、裁剪、间距、圆角、行数 | 通过 | 设置路径独立；更新时调用当前 Grid 的 `refreshLayout()`；缓存键 8 项失效检查通过（含渲染版本） |
| 字体缺失 | 通过 | `FontChooser.isFontRegistered()` 校验，失败回退 `Font:getFace("cfont", size)` |
| 文件路径失效与暂时卸载存储 | 通过 | 失效记录可显示/隐藏；扫描返回完整性标志，根目录或任一子目录不可读时禁止 metadata GC；根外记录保守保留 |
| metadata GC | 通过 | `store_spec.lua` 验证仅删除“不被分类引用且不在完整扫描中”的缓存；不完整扫描故障注入下保留 metadata |
| 失效书籍重新定位 | 通过 | 覆盖同书多分类、保持位置、目标已存在时去重、metadata 与自定义封面迁移、一次 flush，以及 flush 失败回滚；文件选择与 KOReader provider 校验已做静态接口核对 |
| 自定义分类封面 | 通过 | 覆盖指定分类内路径、重新排序不丢失、路径迁移、移出后恢复默认及指定书失效时 fallback；选择界面使用可分页 Menu |
| 书架搜索 | 通过 | `main_spec.lua` 覆盖中文包含、英文作者大小写无关、分类名称和已归类书籍；只在确认后执行，界面路径每批处理 3 本并让出 UI tick，复用/写回 metadata |
| Smart Shelf | 通过 | `main_spec.lua` 覆盖最近阅读顺序、0% 未读、0%/100% 排除阅读中及完成状态；默认关闭，系统结果不写用户 categories |
| 未分类扫描 | 通过 | `tests/scanner_spec.lua` 覆盖递归、格式过滤、`.sdr/cache` 排除及已分类过滤 |
| 首页分类与未分类单书混排 | 通过 | `tests/main_spec.lua` 验证分类在前、未分类书籍为独立 `book` 卡片且不存在中转卡片 |
| 书籍排序 | 通过 | `tests/main_spec.lua` 覆盖手动顺序、名称升序、文件修改时间最新优先、KOReader 阅读历史时间最新优先及未读书籍后置；排序不修改分类存储数组 |
| 未分类列表文件名解析 | 通过 | 使用 2026.07.1 的 `filemanagerutil.splitFileNameType`；静态回归检查禁止调用不存在的 `util.splitFileNameType` |
| 分类返回及阅读返回 | 自动 + 接口通过 | 分类 Grid 设置 `onReturn`；阅读返回在 FileManager 首个 UI tick 执行；测试覆盖快速重复点击只安排一次打开、teardown 取消待执行回调、分类已删除时回到书架首页；页数减少时夹紧到最后一页 |
| Simple UI 独立底栏及图标选择 | 通过 | `tests/main_spec.lua` 验证 `bookshelf_open`、`bookshelf_grid_nav` 和图标选择运行时目录项的注册/注销；选择结果由 Simple UI 保存为标准动作图标覆盖，不写 `simpleui_bar_tabs` |
| 卡片高度与四边圆角边框 | 几何通过 | 图片按边框宽度内缩，`CoverFrame` 在子图片之后最后绘制黑色圆角边框；缓存渲染版本升级为 3 |
| 分类叠层、数量与次级文字 | 几何通过 | 所有卡片预留同一叠层槽并使用相同封面本体尺寸；分类卡绘制 3 条由窄到宽的灰线，线间距及末线到封面间距均为 `stack_line_gap`；标题底对齐、次级文字顶对齐，并仅保留一个缩放间距 |
| 与 Simple UI、CoverBrowser 同时启用 | 静态兼容通过 | 使用 Simple UI 的 QA 与 Bar Injection 公开注册接口，没有目标类方法赋值或对方设置键写入 |
| 禁用恢复 | 通过 | `stopPlugin/onTeardown` 关闭活动 Grid、注销动作及页面描述、移除文件长按入口，只刷新私有设置 |
| CoverCache 异常路径 | 通过 | 故障注入覆盖缓存目录不可用、单个删除失败不中断、缩放异常释放源缓冲区；生成走 `.tmp` 原子替换，读取拒绝 0 字节文件；淘汰明确为低写入近似策略而非严格 LRU |
| 最后一页不足一行 | 自动几何通过 | 7 项、3 列 × 2 行时验证第 2 页保留 1 项；请求已不存在页时夹紧到最后一页 |

自动测试由 `store_spec.lua`、`cache_key_spec.lua`、`scanner_spec.lua`、`main_spec.lua`、`grid_geometry_spec.lua` 执行；静态接口审查以 KOReader 2026.07.1 源码为准。当前环境不是 Kindle，也没有 KOReader 的 ARM 原生运行库，因此自动、静态与几何通过都不等于实体设备触控、字体渲染和墨水屏刷新验收。插件默认不接管启动页，首次测试应从主菜单手动进入。
