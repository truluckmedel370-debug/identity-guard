# HANDOFF · identity-guard 交付与验收记录

## 交付清单

目录：`launch/identity-guard/`

- `identity-guard.ps1`：配置驱动主脚本（`-Snapshot` / `-Check` / `-Restore [-From]` / `-List` / `-Quiet` / `-Config`），UTF-8 带 BOM
- `identity.config.example.json`：示例配置（假路径，不含任何真实私人路径/内容）
- `.gitignore`：忽略 `identity.config.json`、`snapshots/`、`latest.txt`、`ALERT.txt`、`last-check.txt`、`restore-bak-*/`
- `install-task.ps1` + `task.xml`：计划任务注册/卸载/查询脚本（`-Mode on|off|status`，默认任务名 `AgentIdentityCheck`，每日定时 + 登录后 5 分钟 + `StartWhenAvailable`）
- `tests/selftest.ps1`：零依赖沙箱自测（覆盖 1~9 全链路，含 `[MODIFIED]`、`[MISSING ]`、`[ADDED   ]`、`-Restore` 备份与自检、`-List` 与 `retainSnapshots`、`-Quiet`、非法 JSON）
- `README.md`：定位说明、输出示例、快速开始、配置说明与退出码表

---

## 验收结果

### 1. 沙箱全链路自测（`tests\selftest.ps1`）

执行命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\selftest.ps1
```

真实输出摘要：

```text
=== 1. 造 3 个核心文件 + 配置 -> -Snapshot ===
  PASS: 1a~1e (5/5)
=== 2. 修改 1 个字节 -> -Check ===
  PASS: 2a~2c (3/3, [MODIFIED] rules/daily.md)
=== 3. 删除另一个文件 -> -Check ===
  PASS: 3a~3c (3/3, [MISSING ] memory/MEMORY.md)
=== 5 & 6. -Restore 还原 + 备份改坏版本 + 自动 -Check ===
  PASS: 6, 5a~5e (6/6, restore-bak-* 保存改坏现场，还原后自检退出码 0)
=== 4. 新增匹配 watchPatterns 且含标记的文件 -> -Check ===
  PASS: 4a~4c (3/3, [ADDED   ] profiles/desktop/cordis.patch.yml)
=== 9. -Quiet 模式只输出一行结论 ===
  PASS: 9a~9c (3/3)
=== 8. -List 与 retainSnapshots 清理 ===
  PASS: 8a~8c (3/3, 6 份自动清理至 3 份)
=== 7. 配置 JSON 写坏 -> 退出码 2 且不误删 ===
  PASS: 7a~7b (2/2)

自测完成：PASS=28, FAIL=0
```

退出码：`0`。

### 2. 真实路径只读试运行（临时配置指向现役 `.dsh`，快照写入 `$env:TEMP`）

```text
快照已生成：%TEMP%\idguard-livecheck\snapshots\20261124-230246
  核心文件 9 个，扩展监控 0 个，宿主 0.2.1-rc.3，模型 deepseek-flash
基线快照：%TEMP%\idguard-livecheck\snapshots\20261124-230246
[OK      ] 9 个核心文件一致，0 个扩展文件一致
Check ExitCode: 0
```

### 3. 现役 `.dsh\identity` 目录核验（`Get-ChildItem %AGENT_ROOT%\identity -Recurse | Select FullName,LastWriteTime`）

```text
FullName                                                                                    LastWriteTime      
--------                                                                                    -------------      
%AGENT_ROOT%\identity\restore-bak-20261123-221044                                   2026/11/23 22:10:44
%AGENT_ROOT%\identity\snapshots                                                     2026/11/23 22:10:30
%AGENT_ROOT%\identity\identity-watch.cmd                                            2026/11/23 22:10:29
%AGENT_ROOT%\identity\identity.ps1                                                  2026/11/24 12:07:46
%AGENT_ROOT%\identity\last-check.txt                                                2026/11/24 22:30:01
%AGENT_ROOT%\identity\latest.txt                                                    2026/11/23 22:10:35
%AGENT_ROOT%\identity\task.xml                                                      2026/11/23 22:10:39
%AGENT_ROOT%\identity\身份核验.cmd                                                      2026/11/23 22:10:29
%AGENT_ROOT%\identity\snapshots\20261123-221008\...                                 2026/11/23 22:10:16
%AGENT_ROOT%\identity\snapshots\20261123-221030\...                                 2026/11/23 22:10:35
```

现役 `.dsh\identity\` 下所有文件与目录时间戳均未变化。

### 4. `cordis.patch.yml` 时间戳

```text
FullName                                               LastWriteTime      
--------                                               -------------      
%AGENT_ROOT%\profiles\desktop\cordis.patch.yml 2026/11/24 14:25:50
```
