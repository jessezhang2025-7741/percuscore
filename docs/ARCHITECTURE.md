# Percuscore v0.1 结构

## 模块

- `Sources/PercuscoreCore`：可在 macOS 上独立编译的模型、翻页状态机、持久化。
- `Percuscore/App`：App 入口、谱库 Store、系统 Files 导入、原创练习谱生成。
- `Percuscore/Library`：Library、Setlist 双栏编辑器、阅读器设置。
- `Percuscore/Reader`：SwiftUI 阅读器控件、UIKit 手势与缩放、PDF 绘制、PencilKit、书签和笔刷编辑。
- `Tests/PercuscoreCoreTests`：持久化、数据隔离、引用关系、索引损坏恢复和翻页边界测试。

Xcode target 直接编译 App 和 Core 源文件；根 Swift package 仅将 Core 暴露给 XCTest。
无网络依赖，无凭据、服务器或外部数据上传。

## 数据模型

一个 `Score` 对应一个 UUID 和一个 PDF 副本。`ScoreBookmark.endPage == nil` 是跳页书签；非 nil 是包含起止页的 Item Bookmark。
内部页码全部从 0 开始；显示和编辑界面转换为从 1 开始。
SetlistEntry 存储 scoreID 与可选 bookmarkID；自身也有 UUID，因此同一作品可在同一场节目中重复出现。
解析后得到固定起止页的 ReadingItem 队列。删除书签或作品同时移除其 Setlist 引用。

## 保存策略

LibraryStore 在主线程串行发布并保存索引，写盘成功才发布下一份内存状态。
LibraryDisk 用原子替换写入 JSON，并保留上一份可解码索引。损坏文件先保留证据，再尝试旧索引；无法恢复时禁止把空库写回。
如果索引版本比当前 App 新，直接报错，不自动退回旧版数据。

文件选择器 URL 在安全作用域内通过 NSFileCoordinator 读取，然后复制到 Scores 目录。
拖放 provider 的临时 URL 在回调内先复制到 staging，避免异步处理时 URL 过期。
导入索引保存失败时可能留下未引用的 PDF；第一版保留它而不删除潜在的用户文件。

PencilKit drawing.dataRepresentation() 单独保存。编辑中每笔结束立即存草稿，变化期间进行 300ms 防抖保存。
确认写入 Ink 后才删除 Drafts；取消恢复基线并删除草稿。进入后台会尝试刷新草稿。
擦除不会触碰 PDF 内容。撤销／重做按绘画手势保存最多 100 个页面笔迹快照。

SaveActivity 分别跟踪草稿 Ink、已确认 Annotation、ReadingProgress 和 Crop。失败优先于待保存，任何其他操作的成功均不能清除该项失败；重新编辑也不会将失败重置为成功。只有对应写入成功或用户取消对应修改才能清除。阅读器浮动控件显示 Saving…、Saved 或 Save failed，并为失败提供 Retry；重试确认笔迹会执行原来的确认保存，不能由一次草稿写入替代。

布局保存失败时必须在切换页／作品或开始下一轮裁剪前解决，避免把失败的布局带到新页，或作为已保存基线。阅读进度仍采用原有缓冲和 350ms 防抖。离开阅读器时刷新阅读位置，失败则保留阅读器和提示。显示 Saved 表示当前本地写入完成；编辑状态下笔迹仍作为恢复草稿，Done 确认标记。演奏和隐藏控件继续保留原有显示规则。

完整备份的上次成功导出时间使用 LibraryDisk 的独立 backup-export.json 原子存储。临时备份准备与恢复不会改它；BackupFileExporter 的非空成功回调通过 LibraryStore.completeBackupExport 记录本机时间，重复／取消回调仅完成一次。记录成功后才发布新时间；记录失败保留旧时间，并说明备份已导出但时间未记下。缺失历史和损坏历史分别显示 No export recorded / Export time unavailable。该记录不写入 LibraryIndex 或便携备份，通过 .percuscorebackup 迁移谱库不会继承另一台设备的导出历史。

## 页面坐标

每页归一化到 1000 点宽，按 PDF MediaBox 及原始页面旋转计算高度。
PDF 与 PKCanvasView 使用相同 bounds，放在同一个 pageContainer 内。
Crop 的缩放、旋转和以页面宽高为单位的偏移应用于这个共同容器，因此笔迹与 PDF 共享变换。
PageViewport 独立保存每页的手动缩放和相对页面宽高的偏移，与 Crop 分开。普通阅读和演奏共用这一记录；完整页面上的双指缩放／移动直接更新共同容器，并保持缩放手势的焦点。手势结束、翻页、后台和退出时收集视图，使用阅读进度缓冲合并写入索引。旧索引缺少该字段时使用默认视图；不改变已有笔迹坐标。

PDF 通过 Core Graphics 绘制，UIKit 页面视图采用瓦片层，支持非破坏性放大。
半页图像使用各页相同的 Crop 和 PageViewport 变换叠加已保存笔迹。相邻页用独立 PDFDocument 预渲染，最多缓存四张合成页；保存笔迹、Crop 或阅读视图后清缓存。后台只生成预览，不再执行内容边界识别或自动放大。

## 翻页状态机

ReadingSession 有当前位置、showingTransition 和 landscapeBottom。

1. 普通模式：下一页，或下一个 ReadingItem 的 startPage。
2. Half-page：先进入 transition；再将位置改为下一页并退出 transition。
3. 上一页：对称地返回上一过渡状态或上一整页。
4. Landscape：先显示当前页下部，再去下一页上部；与半页过渡互斥。
5. seek、显示模式切换和窗口方向变化会清除阶段状态。
6. continueSetlist 关闭或到达队列结尾时，不产生不存在的下一页。

## 快速跳页

ReaderView 底部页码按钮打开原生 PageNavigatorPanel。PageNavigatorIndex 从当前 ReadingItem 的起止页与 PDF 实际页数计算有效范围，输入采用从 1 开始的 PDF 页码；无效数字和范围外输入不能跳转。

命名位置来自当前谱面的有效 ScoreBookmark 和 PDFOutline。只读取当前文件内的目标页，不执行 PDF 目录中的外部动作。目录保留层级与标题；范围书签在当前阅读范围内显示。没有 PDF 目录的乐谱可以通过现有命名／范围书签提供乐章入口，无需增加索引或备份字段。

缩略图通过独立 actor 和独立 PDFDocument 按需读取原 PDF，缓存限制为 36 张／16 MB，离屏缩略图释放视图持有的图片并防止取消任务重新写回。缩略图不合成 Percuscore 的 PencilKit 笔迹；打开页面时照常恢复笔迹、Crop 和手动阅读视图。

ReaderModel.seek 在保存和改变会话前检查目标 PDF 页、已保存笔迹及草稿是否可读取。保存失败保持原页与标记状态，面板内显示错误；成功后清除翻页阶段，加载目标页与其独立阅读视图。ReaderModel 释放时取消预览、草稿和进度保存任务，避免关闭后的后台预览积压。

## 可访问性与触控

自定义玻璃按钮的标签最小 44×44 点。阅读器大字号时将页码按钮和翻页按钮排在一行、滑条置于下一行；Crop 将保存、重置、取消和精细调整改为纵向操作，校正、比例、横移和纵移滑条放在原生调整面板。谱库网格扩大最小列宽，Setlist 添加界面改为上下列表，长标题不强制截断。

`ScoreSurfaceView` 为乐谱页建立一个独立的 UIKit 可访问元素，并保留实际 PDF／PencilKit 的视觉坐标。其自定义动作调用现有 `ReaderModel.turn`、显示控件及退出演奏逻辑。半页分隔线是可调节可访问元素，报告 25–75% 位置；VoiceOver 每次调整 5%，与触摸拖动共用 `changeDivider`、保存状态与逐页布局。演奏时保留只读信息，取消可调节特征。辅助功能元素不增加云服务、数据字段或备份格式。

## 官方 API 依据

- [PencilKit drawingPolicy](https://developer.apple.com/documentation/pencilkit/pkcanvasview/drawingpolicy)
- [SwiftUI fileImporter 与安全作用域访问](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:oncompletion:))
- [PDFKit 页面坐标与绘制](https://developer.apple.com/documentation/pdfkit/adding-custom-graphics-to-a-pdf)
- [PDFPage bounds 与页面旋转](https://developer.apple.com/documentation/pdfkit/pdfpage/bounds(for:))

这些文档用于 API 实现依据，不代表当前工程通过 Apple 平台运行验证。
