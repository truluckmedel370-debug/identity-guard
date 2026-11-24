# identity-guard.ps1 —— Agent 身份基线守护（快照 / 漂移检测 / 还原 / 列表）
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File identity-guard.ps1 [-Check] [-Quiet]
#   powershell -NoProfile -ExecutionPolicy Bypass -File identity-guard.ps1 -Snapshot
#   powershell -NoProfile -ExecutionPolicy Bypass -File identity-guard.ps1 -Restore [-From <目录>]
#   powershell -NoProfile -ExecutionPolicy Bypass -File identity-guard.ps1 -List
#
# 退出码：0 一致 / 1 有漂移 / 2 配置或环境错误

[CmdletBinding()]
param(
  [switch]$Snapshot,
  [switch]$Check,
  [switch]$Restore,
  [switch]$List,
  [string]$From = '',
  [string]$Config = '',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Ensure-Dir([string]$p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function Normalize-Rel([string]$rel) {
  return ($rel -replace '\\', '/').TrimStart('/')
}

function Resolve-RelPath([string]$baseDir, [string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return '' }
  if ([System.IO.Path]::IsPathRooted($p)) { return $p }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir ($p -replace '/', '\')))
}

# ---------- 1. 加载与校验配置 ----------
if ([string]::IsNullOrWhiteSpace($Config)) {
  $Config = Join-Path $PSScriptRoot 'identity.config.json'
}
if (-not (Test-Path $Config)) {
  Write-Host ("!! 配置文件不存在：{0}" -f $Config)
  exit 2
}

$configDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($Config))
try {
  $rawCfg = [System.IO.File]::ReadAllText($Config, [System.Text.Encoding]::UTF8)
  $cfg = $rawCfg | ConvertFrom-Json
} catch {
  Write-Host ("!! 配置文件 JSON 非法：{0}" -f $_.Exception.Message)
  exit 2
}

if (-not $cfg -or [string]::IsNullOrWhiteSpace([string]$cfg.root)) {
  Write-Host '!! 配置缺少 root 字段'
  exit 2
}

$rootDir = Resolve-RelPath $configDir ([string]$cfg.root)
if (-not (Test-Path $rootDir -PathType Container)) {
  Write-Host ("!! 根目录不存在：{0}" -f $rootDir)
  exit 2
}
$rootDir = ([System.IO.Path]::GetFullPath($rootDir)).TrimEnd('\', '/')

$snapRel = if ($cfg.PSObject.Properties.Name -contains 'snapshotDir' -and $cfg.snapshotDir) { [string]$cfg.snapshotDir } else { './snapshots' }
$snapRoot = Resolve-RelPath $configDir $snapRel
$stateDir = Split-Path -Parent $snapRoot
$latestFile = Join-Path $stateDir 'latest.txt'
$alertFile  = Join-Path $stateDir 'ALERT.txt'

$coreFiles = @()
if ($cfg.PSObject.Properties.Name -contains 'coreFiles' -and $cfg.coreFiles) {
  foreach ($cf in $cfg.coreFiles) {
    $n = Normalize-Rel ([string]$cf)
    if ($n) { $coreFiles += $n }
  }
}

$watchPatterns = @()
if ($cfg.PSObject.Properties.Name -contains 'watchPatterns' -and $cfg.watchPatterns) {
  foreach ($wp in $cfg.watchPatterns) {
    if ($wp -and $wp.glob) {
      $watchPatterns += [pscustomobject]@{
        glob     = Normalize-Rel ([string]$wp.glob)
        contains = if ($wp.PSObject.Properties.Name -contains 'contains') { [string]$wp.contains } else { '' }
      }
    }
  }
}

$retainSnapshots = 20
if ($cfg.PSObject.Properties.Name -contains 'retainSnapshots' -and $null -ne $cfg.retainSnapshots) {
  $retainSnapshots = [int]$cfg.retainSnapshots
}

function Get-FileMeta([string]$rel) {
  $norm = Normalize-Rel $rel
  $abs = Join-Path $rootDir ($norm -replace '/', '\')
  if (-not (Test-Path $abs -PathType Leaf)) {
    return [pscustomobject]@{ rel = $norm; exists = $false; size = 0; sha256 = '' }
  }
  $h = (Get-FileHash -Path $abs -Algorithm SHA256).Hash.ToLower()
  $sz = (Get-Item $abs).Length
  return [pscustomobject]@{ rel = $norm; exists = $true; size = $sz; sha256 = $h }
}

function Get-HostVersion {
  if (-not ($cfg.PSObject.Properties.Name -contains 'hostMeta') -or -not $cfg.hostMeta) { return '未知' }
  if (-not ($cfg.hostMeta.PSObject.Properties.Name -contains 'packageJson') -or -not $cfg.hostMeta.packageJson) { return '未知' }
  $p = Resolve-RelPath $rootDir ([string]$cfg.hostMeta.packageJson)
  if (-not (Test-Path $p -PathType Leaf)) { return '未知' }
  try {
    $j = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($j.version) { return [string]$j.version }
    return '未知'
  } catch { return '未知' }
}

function Get-ModelInfo {
  if (-not ($cfg.PSObject.Properties.Name -contains 'hostMeta') -or -not $cfg.hostMeta) { return [pscustomobject]@{ model = ''; effort = '' } }
  if (-not ($cfg.hostMeta.PSObject.Properties.Name -contains 'modelYaml') -or -not $cfg.hostMeta.modelYaml) { return [pscustomobject]@{ model = ''; effort = '' } }
  $p = Resolve-RelPath $rootDir ([string]$cfg.hostMeta.modelYaml)
  if (-not (Test-Path $p -PathType Leaf)) { return [pscustomobject]@{ model = ''; effort = '' } }
  try {
    $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($t, 'model:\s*([^\s#]+)')
    $e = [regex]::Match($t, 'reasoningEffort:\s*([^\s#]+)')
    return [pscustomobject]@{
      model  = if ($m.Success) { $m.Groups[1].Value } else { '' }
      effort = if ($e.Success) { $e.Groups[1].Value } else { '' }
    }
  } catch {
    return [pscustomobject]@{ model = ''; effort = '' }
  }
}

function Glob-ToRegex([string]$glob) {
  $g = Normalize-Rel $glob
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.Append('^')
  $i = 0
  while ($i -lt $g.Length) {
    if ($i + 2 -lt $g.Length -and $g.Substring($i, 3) -eq '**/') {
      $null = $sb.Append('(?:.*/)?')
      $i += 3
    } elseif ($i + 1 -lt $g.Length -and $g.Substring($i, 2) -eq '**') {
      $null = $sb.Append('.*')
      $i += 2
    } elseif ($g[$i] -eq '*') {
      $null = $sb.Append('[^/]*')
      $i++
    } elseif ($g[$i] -eq '?') {
      $null = $sb.Append('[^/]')
      $i++
    } else {
      $null = $sb.Append([regex]::Escape($g[$i]))
      $i++
    }
  }
  $null = $sb.Append('$')
  return $sb.ToString()
}

function Get-SkipDirs {
  $d = @()
  if ($cfg.PSObject.Properties.Name -contains 'excludeDirs' -and $cfg.excludeDirs) {
    $d = @($cfg.excludeDirs)
  } else {
    $d = @('node_modules', '.git', '.cache', 'cache', 'storages', 'sessions', 'logs', 'snapshots', 'attachments')
  }
  return @($d | ForEach-Object { ([string]$_).ToLower() })
}

# 带剪枝的枚举：跳过 excludeDirs 整棵树，避免在 node_modules 这类目录里白扫几万个文件
function Enumerate-FilesPruned([string]$dir, [string[]]$skip, [int]$maxFiles) {
  $out = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push($dir)
  while ($stack.Count -gt 0) {
    $cur = [string]$stack.Pop()
    try { $di = New-Object System.IO.DirectoryInfo $cur } catch { continue }
    try { $subs = $di.GetDirectories() } catch { $subs = @() }
    foreach ($s in $subs) {
      if ($skip -contains $s.Name.ToLower()) { continue }
      $stack.Push($s.FullName)
    }
    try { $fs = $di.GetFiles() } catch { $fs = @() }
    foreach ($f in $fs) {
      if ($out.Count -ge $maxFiles) { return $out }
      [void]$out.Add($f)
    }
  }
  return $out
}

function Scan-WatchHits {
  $hits = @()
  if ($watchPatterns.Count -eq 0) { return $hits }
  $skip = Get-SkipDirs
  $maxScan = 20000
  if ($cfg.PSObject.Properties.Name -contains 'maxScanFiles' -and $cfg.maxScanFiles) { $maxScan = [int]$cfg.maxScanFiles }
  $allFiles = @(Enumerate-FilesPruned $rootDir $skip $maxScan) |
    Where-Object {
      $_.FullName -notlike "$snapRoot*" -and
      $_.FullName -notlike "*\restore-bak-*" -and
      $_.Length -lt 4194304
    }
  if ($allFiles.Count -ge $maxScan) {
    Write-Warning "扫描达到上限 $maxScan 个文件（root=$rootDir）。给配置加 excludeDirs 或调 maxScanFiles，否则 [ADDED] 检测可能漏。"
  }
  $seen = @{}
  foreach ($wp in $watchPatterns) {
    $rx = Glob-ToRegex $wp.glob
    foreach ($f in $allFiles) {
      $rel = Normalize-Rel ($f.FullName.Substring($rootDir.Length))
      if ($rel -notmatch $rx) { continue }
      $matched = $true
      if (-not [string]::IsNullOrEmpty($wp.contains)) {
        $matched = Select-String -Path $f.FullName -Pattern ([regex]::Escape($wp.contains)) -Quiet -ErrorAction SilentlyContinue
      }
      if ($matched -and -not $seen.ContainsKey($rel)) {
        $seen[$rel] = $true
        $h = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
        $hits += [pscustomobject]@{
          rel      = $rel
          contains = $wp.contains
          size     = $f.Length
          sha256   = $h
        }
      }
    }
  }
  return $hits
}

function Get-LatestSnap {
  if (Test-Path $latestFile -PathType Leaf) {
    $p = ([System.IO.File]::ReadAllText($latestFile, [System.Text.Encoding]::UTF8)).Trim()
    if ($p -and (Test-Path $p -PathType Container)) { return $p }
  }
  if (Test-Path $snapRoot -PathType Container) {
    $newest = Get-ChildItem -Path $snapRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($newest) { return $newest.FullName }
  }
  return $null
}

function Prune-Snapshots {
  if ($retainSnapshots -le 0) { return }
  if (-not (Test-Path $snapRoot -PathType Container)) { return }
  $dirs = @(Get-ChildItem -Path $snapRoot -Directory | Sort-Object Name -Descending)
  if ($dirs.Count -le $retainSnapshots) { return }
  for ($i = $retainSnapshots; $i -lt $dirs.Count; $i++) {
    Remove-Item -Path $dirs[$i].FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Do-Snapshot {
  Ensure-Dir $snapRoot
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $dir = Join-Path $snapRoot $stamp
  # 同一秒内连拍时加毫秒后缀防覆盖
  if (Test-Path $dir) {
    $dir = Join-Path $snapRoot ((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
  }
  Ensure-Dir $dir

  $files = @()
  foreach ($rel in $coreFiles) {
    $meta = Get-FileMeta $rel
    $files += $meta
    if ($meta.exists) {
      $src = Join-Path $rootDir ($rel -replace '/', '\')
      $dest = Join-Path $dir ($rel -replace '/', '\')
      Ensure-Dir (Split-Path -Parent $dest)
      Copy-Item -Path $src -Destination $dest -Force
    }
  }

  $watchHits = @(Scan-WatchHits)
  $modelInfo = Get-ModelInfo
  $metaObj = [ordered]@{
    takenAt     = (Get-Date).ToString('o')
    root        = $rootDir
    hostVersion = Get-HostVersion
    model       = $modelInfo.model
    effort      = $modelInfo.effort
    files       = $files
    watchHits   = $watchHits
  }

  $metaJson = $metaObj | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText((Join-Path $dir 'meta.json'), $metaJson, $utf8Bom)
  [System.IO.File]::WriteAllText($latestFile, $dir, $utf8Bom)

  Prune-Snapshots

  if (-not $Quiet) {
    $existCount = @($files | Where-Object { $_.exists }).Count
    Write-Host ("快照已生成：{0}" -f $dir)
    Write-Host ("  核心文件 {0} 个，扩展监控 {1} 个，宿主 {2}，模型 {3}" -f $existCount, $watchHits.Count, $metaObj.hostVersion, $metaObj.model)
  }
  return 0
}

function Do-Check {
  $snap = Get-LatestSnap
  if (-not $snap -or -not (Test-Path (Join-Path $snap 'meta.json'))) {
    Write-Host '!! 还没有任何有效快照。先跑一次 -Snapshot 建立基线。'
    return 2
  }

  try {
    $meta = ([System.IO.File]::ReadAllText((Join-Path $snap 'meta.json'), [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
  } catch {
    Write-Host ("!! 快照 meta.json 读取失败：{0}" -f $_.Exception.Message)
    return 2
  }

  $reportLines = New-Object System.Collections.ArrayList
  $drift = 0
  $coreSet = @{}
  $coreOkCount = 0

  foreach ($f in @($meta.files)) {
    $rel = Normalize-Rel ([string]$f.rel)
    $coreSet[$rel] = $true
    $now = Get-FileMeta $rel
    if ($f.exists -and -not $now.exists) {
      [void]$reportLines.Add(("[MISSING ] {0,-34} 快照里有，现在没了" -f $rel))
      $drift++
    } elseif (-not $f.exists -and $now.exists) {
      [void]$reportLines.Add(("[ADDED   ] {0,-34} 快照里没有，现在出现了" -f $rel))
      $drift++
    } elseif ($now.exists -and $now.sha256 -ne $f.sha256) {
      $oldH = ([string]$f.sha256).Substring(0, [Math]::Min(4, ([string]$f.sha256).Length))
      $newH = $now.sha256.Substring(0, [Math]::Min(4, $now.sha256.Length))
      [void]$reportLines.Add(("[MODIFIED] {0,-34} sha256 {1}.. → {2}..   (size {3} → {4})" -f $rel, $oldH, $newH, $f.size, $now.size))
      $drift++
    } elseif ($now.exists) {
      $coreOkCount++
    }
  }

  # watchPatterns 比对（含 [ADDED] 检测）
  $baseWatch = @{}
  if ($meta.PSObject.Properties.Name -contains 'watchHits' -and $meta.watchHits) {
    foreach ($wh in @($meta.watchHits)) {
      $baseWatch[(Normalize-Rel ([string]$wh.rel))] = $wh
    }
  }

  $nowWatch = @(Scan-WatchHits)
  $nowWatchMap = @{}
  $watchOkCount = 0

  foreach ($nh in $nowWatch) {
    $nowWatchMap[$nh.rel] = $nh
    if (-not $baseWatch.ContainsKey($nh.rel) -and -not $coreSet.ContainsKey($nh.rel)) {
      $markInfo = if ($nh.contains) { "但含标记 $($nh.contains)" } else { "匹配监控规则" }
      [void]$reportLines.Add(("[ADDED   ] {0,-34} 不在清单里{1}" -f $nh.rel, $markInfo))
      $drift++
    } elseif ($baseWatch.ContainsKey($nh.rel) -and -not $coreSet.ContainsKey($nh.rel)) {
      $bh = $baseWatch[$nh.rel]
      if ($nh.sha256 -ne $bh.sha256) {
        $oldH = ([string]$bh.sha256).Substring(0, [Math]::Min(4, ([string]$bh.sha256).Length))
        $newH = $nh.sha256.Substring(0, [Math]::Min(4, $nh.sha256.Length))
        [void]$reportLines.Add(("[MODIFIED] {0,-34} sha256 {1}.. → {2}..   (size {3} → {4})" -f $nh.rel, $oldH, $newH, $bh.size, $nh.size))
        $drift++
      } else {
        $watchOkCount++
      }
    } elseif ($coreSet.ContainsKey($nh.rel)) {
      $watchOkCount++
    }
  }

  foreach ($bRel in $baseWatch.Keys) {
    if (-not $nowWatchMap.ContainsKey($bRel) -and -not $coreSet.ContainsKey($bRel)) {
      [void]$reportLines.Add(("[MISSING ] {0,-34} 原监控命中文件缺失或标记被移除" -f $bRel))
      $drift++
    }
  }

  $okLine = "[OK      ] {0} 个核心文件一致，{1} 个扩展文件一致" -f $coreOkCount, $watchOkCount

  if ($Quiet) {
    if ($drift -eq 0) {
      Write-Host $okLine
    } else {
      Write-Host ("[DRIFT   ] 发现 {0} 处漂移（详见非静默输出）" -f $drift)
    }
  } else {
    Write-Host ("基线快照：{0}" -f $snap)
    foreach ($ln in $reportLines) { Write-Host $ln }
    if ($drift -eq 0) {
      Write-Host $okLine
    } else {
      Write-Host ("结论：发现 {0} 处漂移。" -f $drift)
    }
  }

  if ($drift -gt 0) {
    $alertBody = @("检查时间：" + (Get-Date).ToString('o'), "基线快照：$snap", "漂移数：$drift") + $reportLines
    [System.IO.File]::WriteAllText($alertFile, ($alertBody -join "`r`n"), $utf8Bom)
    return 1
  }
  return 0
}

function Do-Restore {
  $snap = ''
  if (-not [string]::IsNullOrWhiteSpace($From)) {
    if (Test-Path $From -PathType Container) {
      $snap = [System.IO.Path]::GetFullPath($From)
    } elseif (Test-Path (Join-Path $snapRoot $From) -PathType Container) {
      $snap = Join-Path $snapRoot $From
    }
  } else {
    $snap = Get-LatestSnap
  }

  if (-not $snap -or -not (Test-Path (Join-Path $snap 'meta.json'))) {
    Write-Host '!! 找不到可用快照。'
    return 2
  }

  $meta = ([System.IO.File]::ReadAllText((Join-Path $snap 'meta.json'), [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
  $bakDir = Join-Path $stateDir ('restore-bak-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
  if (Test-Path $bakDir) {
    $bakDir = Join-Path $stateDir ('restore-bak-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
  }
  Ensure-Dir $bakDir

  $restored = 0
  foreach ($f in @($meta.files)) {
    if (-not $f.exists) { continue }
    $rel = Normalize-Rel ([string]$f.rel)
    $src = Join-Path $snap ($rel -replace '/', '\')
    if (-not (Test-Path $src -PathType Leaf)) { continue }
    $dst = Join-Path $rootDir ($rel -replace '/', '\')
    if (Test-Path $dst -PathType Leaf) {
      $bakTarget = Join-Path $bakDir ($rel -replace '/', '\')
      Ensure-Dir (Split-Path -Parent $bakTarget)
      Copy-Item -Path $dst -Destination $bakTarget -Force
    }
    Ensure-Dir (Split-Path -Parent $dst)
    Copy-Item -Path $src -Destination $dst -Force
    $restored++
  }

  Write-Host ("已从 {0} 还原 {1} 个文件；还原前现场已备份至：{2}" -f $snap, $restored, $bakDir)
  Write-Host '正在执行还原后自检...'
  $chkCode = Do-Check
  return $chkCode
}

function Do-List {
  if (-not (Test-Path $snapRoot -PathType Container)) {
    Write-Host '（暂无快照目录）'
    return 0
  }
  $latest = ''
  if (Test-Path $latestFile -PathType Leaf) {
    $latest = ([System.IO.File]::ReadAllText($latestFile, [System.Text.Encoding]::UTF8)).Trim()
  }
  $dirs = @(Get-ChildItem -Path $snapRoot -Directory | Sort-Object Name -Descending)
  if ($dirs.Count -eq 0) {
    Write-Host '（暂无快照）'
    return 0
  }
  foreach ($d in $dirs) {
    $tag = if ($latest -and ($d.FullName -eq $latest)) { ' [latest]' } else { '' }
    $metaPath = Join-Path $d.FullName 'meta.json'
    if (Test-Path $metaPath) {
      try {
        $m = ([System.IO.File]::ReadAllText($metaPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
        $fc = @($m.files | Where-Object { $_.exists }).Count
        $wc = if ($m.PSObject.Properties.Name -contains 'watchHits') { @($m.watchHits).Count } else { 0 }
        Write-Host ("{0}{1}  (takenAt={2}, core={3}, watch={4})" -f $d.Name, $tag, $m.takenAt, $fc, $wc)
        continue
      } catch {}
    }
    Write-Host ("{0}{1}" -f $d.Name, $tag)
  }
  return 0
}

$code = 0
if ($Snapshot)    { $code = Do-Snapshot }
elseif ($Restore) { $code = Do-Restore }
elseif ($List)    { $code = Do-List }
else              { $code = Do-Check }

exit $code
