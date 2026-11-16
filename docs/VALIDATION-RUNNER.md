# 一键本地验收

在 Finder 双击项目根目录的 **验收.command**，选择快速、完整或发布检查。
也可以在项目目录运行 `python3 scripts/verify.py`；默认执行快速检查。
第一次使用 Mac 可能要求你允许打开本地脚本。工具不安装软件，不访问账号或真机谱库。

## 三档检查

| 层级 | 内容 |
|---|---|
| quick | 工程引用、版本占位符、配置及资源检查；Python 工具测试；真实 Core XCTest |
| full | quick 全部项目；正式 App 模拟器构建；原生阅读器；已有界面测试；独立真实画布重启回归 |
| release | full 全部项目；干净源码；扫描样本验证；性能测量与同条件对比；人工真机记录 |

```sh
python3 scripts/verify.py --level quick
python3 scripts/verify.py --level full
python3 scripts/verify.py --level full --simulator <iPad-Simulator-UUID>
python3 scripts/verify.py --level release --plan
```

完整检查优先复用已启动的 iPad 模拟器，否则选择最新可用的 iPad runtime 并启动。
缺少运行环境会明确记录未执行。只使用专用测试 App 和临时谱库。
普通界面测试每次启动都使用新谱库，避免上一份测试曲单引用污染后续样本；
重启回归单独使用固定本次标识的谱库，以检验保存和重载。
同一 Mac 上统一入口通过进程锁串行运行；每次检查使用独立的测试副本，
不会同时向同一模拟器提交两组界面测试。请不要同时手动启动旧检查脚本。

## 报告与结果

每次产生独立的 `dist/validation/<时间-随机标识>/` 文件夹，包含：

- `report.md`：可读报告，显示每项状态、数量、失败测试及日志链接。
- `report.json`：源码提交、干净／修改状态、文件指纹、工具链、系统、模拟器、
  每条命令、参数、耗时、退出码和证据标识。
- 各项 `.log`；原生与 UI 检查另保留 `.xcresult` 和可用的结构化摘要。
- 发布档另提供未填的 `manual-device-template.json`，测量成功时保存
  `performance-record.json`、原始指标与趋势。

可用 `--output <新的空目录>` 指定位置；已有报告不会被覆盖。
自选输出位置应在项目外或已忽略的 `dist` 内，避免输出本身改变源码指纹。
报告在每一步后更新，中断或超时保留已取得的结果。运行期间源码改变会使一致性检查失败。
用 `--developer-dir /absolute/path/to/Xcode.app/Contents/Developer` 选择 Xcode；
该选择会传递到全部子检查。统一入口会清理继承的测试控制变量，固定检查当前项目。

| 状态 | 含义 |
|---|---|
| passed／通过 | 本项实际执行并满足检查要求 |
| failed／失败 | 命令、测试、配置或证据校验失败 |
| not_run／未执行 | 缺少环境、输入、验收记录，或只生成计划 |

总体只有全部必需项目通过才为 passed（退出码 0）；有失败为 failed（1）；
有未执行且无失败为 incomplete（2）。`--plan` 始终显示未完成，不能当作验收。
测试进程退出 0 但没有实际通过的测试，同样不能算通过。
报告保留跳过数量；大 PDF 测试在普通 UI 套件中被明确排除，必须由发布档测量。

## 真实画布的固定回归

独立的 `live_relaunch` 项使用正式 ReaderView、ScoreSurface、保存逻辑，
在测试 App 中实际拖动画笔输入，执行 Done、翻页、结束进程、重新启动，
检查已保存页码以及确认笔迹在画布中的重新加载，也检查其他页没有串笔迹。
诊断文字仅存在于生成的测试宿主。模拟器使用手指输入，真实 Pencil 仍需人工验收。

## 性能基线和阈值

使用 `scripts/make_large_pdf_fixture.swift` 生成的本地 120 页、300 dpi 样本。
不自动读取个人乐谱。已有 `check_large_pdf_fixture.swift` 会验证页数、图像尺寸与颜色。

```sh
python3 scripts/verify.py --level release \
  --fixture /absolute/path/to/scanned.pdf --runs 5 \
  --simulator <iPad-Simulator-UUID>
```

第一次测量会生成 `performance-record.json`；没有基线、阈值或真机记录时，
整份发布验收仍显示未完成。先在相同条件重复测量，判断正常波动，再手动制定容忍范围。

阈值 JSON 必须包含以下三个数值，单位为允许增长百分比。
下面仅说明格式，**不是内置或已验证的容忍范围**：

```json
{"open_ms": 10, "turn_tile_ms": 10, "peak_bytes": 5}
```

分别比较首个可见 PDF tile 时间中位数、可见翻页 P95 和采样内存峰值中位数。
报告可记录趋势；没有明确阈值不能通过发布门槛。基线和本次的样本哈希、模拟器与 runtime
构建、Mac 系统与架构、Xcode/Swift、轮次、玻璃开关及测试宿主指纹必须一致。
旧报告缺少这些条件时不能自动升级为可信基线。源码版本可以不同，正是要比较的对象。
系统缓存不清空；模拟器内存和时间不能替代实体 iPad/GPU 性能。

```sh
python3 scripts/verify.py --level release \
  --fixture /absolute/path/to/scanned.pdf \
  --performance-baseline /absolute/path/to/performance-record.json \
  --performance-limits /absolute/path/to/limits.json \
  --manual-record /absolute/path/to/device-record.json
```

报告记录输入路径、哈希、轮次和测试命令，以便同条件重测。保留样本和基线文件，
不要仅保存截图或汇总数字。脚本不会自动改变已有基线或放宽阈值。

## 人工真机记录

从发布报告目录复制 `manual-device-template.json`，在实际安装和验收之后填写。
记录应放在项目目录外或已忽略的 `dist` 目录，避免记录本身改变待验收源码指纹。

填写操作者、带时区的测试日期、设备与系统、Pencil 型号、App 版本和构建号；
逐项按实际结果填写 passed、failed 或 not_run，并保留失败说明。检查项目来自
`docs/IPAD-CHECKLIST.md`，默认全部 not_run。缺项、重复、旧源码／旧清单、
未提交源码和版本不匹配都不能得到有效通过结果。

这是人工提交的证据；工具核对其完整性和版本关联，不会冒充自动完成了真机测试。
它不会安装或删除 iPad App，也不会修改谱库。上线或稳定版标签仍需你明确决定。
