# DSH 复核补丁（2026-11-24 23:18）

Antigravity 交付后由 DSH 独立复核，发现并修复一处性能问题：

## 问题

`Scan-WatchHits` 原先用 `Get-ChildItem -Path $rootDir -Recurse -File` 扫**整个根目录**再逐个正则匹配。在真实 `.dsh`（49,804 个文件 / 3.4 GB）上，只要 `watchPatterns` 非空，单次 `-Snapshot` 耗时 **> 120 秒**（实测被工具超时截断）。

## 修复

`identity-guard.ps1` 新增：

1. `Get-SkipDirs` —— 读配置里的 `excludeDirs`，没配就用默认表（`node_modules` / `.git` / `cache` / `storages` / `sessions` / `logs` / `snapshots` / `attachments`）
2. `Enumerate-FilesPruned` —— 显式栈遍历，**整棵子树剪枝**，不再进入被排除目录
3. `maxScanFiles`（默认 20000）—— 扫到上限就停并发 Warning，避免无声漏检

## 实测

| 场景 | 修复前 | 修复后 |
|---|---|---|
| `profiles/**/*.yml`（真实 `.dsh`） | > 120 秒（超时截断） | **2.9 秒** |
| 自测 `tests/selftest.ps1` | 28 项全过 | 28 项仍全过 |

## 两个必须知道的语义坑

1. **排除 `node_modules` 会漏掉装在里面的插件文件。** 实测 `.dsh` 里含 `[dsh-purge]` 标记的只有 3 个文件，其中 2 个在 `node_modules` / `dsh_orb` 下。要让监控真正覆盖生效中的插件，`watchPatterns` 应直接指向**实际被加载的那份**，或者把该目录从 `excludeDirs` 里拿掉（代价是变慢）。
2. **隐藏目录也要算进去。** `Get-ChildItem` 不加 `-Force` 会跳过 `.dsh-browser-source` 这类以点开头的目录；本工具用 .NET 的 `GetDirectories()`，默认**包含**隐藏目录 —— 所以命中数会比手工核对多（实测 3 个 vs 手工 2 个，手工漏了隐藏目录）。

## 另外

- `HANDOFF.md` 里含本机绝对路径与临时目录路径，**发布前必须脱敏**（换成占位符），或直接不进仓库。
- 现役 `%AGENT_ROOT%\identity\` 全程未被改动（`identity.ps1` 仍是 12:07:46 的版本，快照与 `latest.txt` 都是 11/23 的，计划任务下次运行 11/25 22:30，未被重注册）。
