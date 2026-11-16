# iPad 手工验收指南

本页说明如何检查你自行构建的版本，不是作者设备的安装记录，也不表示本次公开源码已完成真机验收。请使用隔离测试谱库，按实际观察填写结果；版本要求见[构建与安装](BUILDING.md)，当前自动检查范围见[验证状态](VALIDATION-STATUS.md)。

1. **确认版本。** 在 Reader settings 底部核对你实际安装的版本、构建号和源码状态。Share version details 可复制版本信息；Git 下载应对应所构建的公共提交，源码 ZIP 的提交信息可能显示不可用。普通使用不需要保持连接 Mac。
2. **先用独立谱库。** Reader settings → Device acceptance → Prepare test library，完成后 Open test library。初次生成约占 270 MB，可能需要几分钟。测试谱包含四页练习谱、大扫描谱、旋转、裁剪、笔迹和跨作品节目单，不改正式谱库。
3. **验证输入链路。** Pencil 第一笔 → 连续书写 → Done → 点击原笔迹位置 → 翻页 → 返回 → 再标注。重复 30 次，检查首笔、卡死、误翻页和跨页串笔迹；同时检查掌触和双指缩放。在验收页逐次记录，不能仅因计数完成就标通过。
4. **验证生命周期。** 标注时切后台、锁屏再恢复；保存后结束 App 并重开，核对笔迹、草稿和最近页码。完成一次 30–60 分钟跨作品节目单演奏，记录结果。
5. **验证删除恢复。** 在独立测试库中，将有笔迹/裁剪的作品移至 Recently Deleted。重开 App 后，从同一 Device acceptance 记录重新 Open test library，检查节目单占位与跳过；恢复后核对原位置及内容。再测试永久删除和 Storage management → Clear cache，确认其他作品和草稿保留。
6. **验证备份。** 退出真机测试谱库，返回主库的 Reader settings → Library backup → Prepare standard test library → Open practice scores；此按钮只准备独立练习副本。使用练习库将包含最近删除的备份导出到 App 目录以外，再 Choose backup to verify，打开隔离恢复副本目视核对笔迹、页面位置及节目单。文件生成、系统导出和恢复验证是三个不同结果。
7. **保存报告。** 在 Device acceptance 及备份验证详情中记录真实观察并导出报告。遇到问题保留版本、发生页面、复现步骤及诊断日志；不要把尚未执行的项目标成通过。

正式谱库的备份需要你在 App 内手动导出并验证可恢复。更换签名 Team 或 Bundle Identifier 前先备份，不假设不同身份的 App 会自动继承数据。不要通过卸载现有 App 来排查问题；安装成功不代表数据或交互已验收。

Mac 上的一键自动验收仍使用项目根目录的 `验收.command`；它与 iPad 上的人工观察分开记录。数据兼容和清理细节见 [STORAGE.md](STORAGE.md)，备份流程见 [BACKUP.md](BACKUP.md)。
