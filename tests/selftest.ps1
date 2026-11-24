# tests/selftest.ps1 —— identity-guard 零依赖自测脚本（覆盖 1~9 全部漂移/还原/保留/静默场景）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\selftest.ps1

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$guardDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$guardPs1 = Join-Path $guardDir 'identity-guard.ps1'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0

function Assert-True([bool]$Cond, [string]$Desc) {
  if ($Cond) {
    Write-Host "  PASS: $Desc" -ForegroundColor Green
    $script:Pass++
  } else {
    Write-Host "  FAIL: $Desc" -ForegroundColor Red
    $script:Fail++
  }
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Desc) {
  if ($Text.Contains($Needle)) {
    Write-Host "  PASS: $Desc" -ForegroundColor Green
    $script:Pass++
  } else {
    Write-Host "  FAIL: $Desc (未找到: $Needle)" -ForegroundColor Red
    $script:Fail++
  }
}

function Assert-Eq($Actual, $Expected, [string]$Desc) {
  if ($Actual -eq $Expected) {
    Write-Host "  PASS: $Desc" -ForegroundColor Green
    $script:Pass++
  } else {
    Write-Host "  FAIL: $Desc (期望: '$Expected', 实际: '$Actual')" -ForegroundColor Red
    $script:Fail++
  }
}

function Run-Guard([string[]]$ScriptArgs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guardPs1) + $ScriptArgs
  $psi.Arguments = ($argList | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
  }) -join ' '
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{
    ExitCode = $p.ExitCode
    Out      = ($stdout + "`n" + $stderr).Trim()
  }
}

$rand = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
$sandbox = Join-Path $env:TEMP "idguard-test-$rand"
$fakeRoot = Join-Path $sandbox 'fake-dsh'
$snapDir  = Join-Path $sandbox 'snapshots'
$cfgPath  = Join-Path $sandbox 'identity.config.json'

New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'rules') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'memory') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'profiles\desktop') -Force | Out-Null

try {
  Write-Host "=== 1. 造 3 个核心文件 + 配置 -> -Snapshot ==="
  $f1 = Join-Path $fakeRoot 'prompt-inject.md'
  $f2 = Join-Path $fakeRoot 'rules\daily.md'
  $f3 = Join-Path $fakeRoot 'memory\MEMORY.md'
  [System.IO.File]::WriteAllText($f1, "# prompt`nline1`n", $utf8NoBom)
  [System.IO.File]::WriteAllText($f2, "# daily rules`nallow: true`n", $utf8NoBom)
  [System.IO.File]::WriteAllText($f3, "# memory`n- fact 1`n", $utf8NoBom)

  $cfgObj = [ordered]@{
    root            = $fakeRoot
    snapshotDir     = $snapDir
    coreFiles       = @('prompt-inject.md', 'rules/daily.md', 'memory/MEMORY.md')
    watchPatterns   = @(@{ glob = 'profiles/**/cordis.patch.yml'; contains = '[dsh-purge]' })
    hostMeta        = @{ packageJson = 'nonexistent/package.json'; modelYaml = 'profiles/desktop/cordis.patch.yml' }
    retainSnapshots = 3
  }
  [System.IO.File]::WriteAllText($cfgPath, ($cfgObj | ConvertTo-Json -Depth 6), $utf8NoBom)

  $rSnap = Run-Guard @('-Snapshot', '-Config', $cfgPath)
  Assert-Eq $rSnap.ExitCode 0 '1a: -Snapshot 退出码为 0'
  $snapDirs = @(Get-ChildItem -Path $snapDir -Directory)
  Assert-Eq $snapDirs.Count 1 '1b: 生成 1 个快照目录'
  $metaFile = Join-Path $snapDirs[0].FullName 'meta.json'
  Assert-True (Test-Path $metaFile) '1c: meta.json 存在'
  $meta = ([System.IO.File]::ReadAllText($metaFile, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert-Eq @($meta.files).Count 3 '1d: meta.json 含 3 条文件记录'
  Assert-True (@($meta.files | Where-Object { $_.sha256.Length -eq 64 }).Count -eq 3) '1e: 3 条均含有效 sha256'
  $origHash2 = (Get-FileHash $f2 -Algorithm SHA256).Hash.ToLower()

  Write-Host "`n=== 2. 修改 1 个字节 -> -Check ==="
  [System.IO.File]::WriteAllText($f2, "# daily rules`nallow: fals`n", $utf8NoBom)
  $rMod = Run-Guard @('-Check', '-Config', $cfgPath)
  Assert-Eq $rMod.ExitCode 1 '2a: 改 1 字节后 -Check 退出码为 1'
  Assert-Contains $rMod.Out '[MODIFIED]' '2b: 输出包含 [MODIFIED]'
  Assert-Contains $rMod.Out 'rules/daily.md' '2c: 输出包含被改文件名 rules/daily.md'

  Write-Host "`n=== 3. 删除另一个文件 -> -Check ==="
  Remove-Item -Path $f3 -Force
  $rMiss = Run-Guard @('-Check', '-Config', $cfgPath)
  Assert-Eq $rMiss.ExitCode 1 '3a: 删文件后 -Check 退出码为 1'
  Assert-Contains $rMiss.Out '[MISSING ]' '3b: 输出包含 [MISSING ]'
  Assert-Contains $rMiss.Out 'memory/MEMORY.md' '3c: 输出包含缺失文件名 memory/MEMORY.md'

  Write-Host "`n=== 5 & 6. -Restore 还原 + 备份改坏版本 + 自动 -Check ==="
  $rRest = Run-Guard @('-Restore', '-Config', $cfgPath)
  Assert-Eq $rRest.ExitCode 0 '6: -Restore 后自动 -Check 退出码为 0'
  $restoredHash2 = (Get-FileHash $f2 -Algorithm SHA256).Hash.ToLower()
  Assert-Eq $restoredHash2 $origHash2 '5a: 被改文件 sha256 已恢复与快照一致'
  Assert-True (Test-Path $f3) '5b: 被删文件已还原'
  $bakDirs = @(Get-ChildItem -Path $sandbox -Directory -Filter 'restore-bak-*')
  Assert-Eq $bakDirs.Count 1 '5c: 生成 restore-bak-* 备份目录'
  $bakF2 = Join-Path $bakDirs[0].FullName 'rules\daily.md'
  Assert-True (Test-Path $bakF2) '5d: restore-bak-* 内保存了改坏的现场文件'
  Assert-Contains ([System.IO.File]::ReadAllText($bakF2, [System.Text.Encoding]::UTF8)) 'allow: fals' '5e: restore-bak-* 内容确为改坏那一版'

  Write-Host "`n=== 4. 新增匹配 watchPatterns 且含标记的文件 -> -Check ==="
  $addedFile = Join-Path $fakeRoot 'profiles\desktop\cordis.patch.yml'
  [System.IO.File]::WriteAllText($addedFile, "# [dsh-purge]`nmodel: test`n", $utf8NoBom)
  $rAdd = Run-Guard @('-Check', '-Config', $cfgPath)
  Assert-Eq $rAdd.ExitCode 1 '4a: 新增含标记文件后 -Check 退出码为 1'
  Assert-Contains $rAdd.Out '[ADDED   ]' '4b: 输出包含 [ADDED   ]'
  Assert-Contains $rAdd.Out 'profiles/desktop/cordis.patch.yml' '4c: 输出包含新增文件路径'

  # 清理掉新增文件，恢复一致态供后续测试
  Remove-Item -Path $addedFile -Force

  Write-Host "`n=== 9. -Quiet 模式只输出一行结论 ==="
  $rQuietOk = Run-Guard @('-Check', '-Quiet', '-Config', $cfgPath)
  Assert-Eq $rQuietOk.ExitCode 0 '9a: -Quiet 一致态退出码为 0'
  $qLines = @($rQuietOk.Out -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
  Assert-Eq $qLines.Count 1 '9b: -Quiet 模式只输出一行'
  Assert-Contains $rQuietOk.Out '[OK      ]' '9c: -Quiet 一致态包含 [OK      ]'

  Write-Host "`n=== 8. -List 与 retainSnapshots 清理 ==="
  # 已有 1 份，再连拍 5 份（共 6 份），retainSnapshots = 3 应只剩 3 份
  for ($i = 1; $i -le 5; $i++) {
    Start-Sleep -Milliseconds 50
    $null = Run-Guard @('-Snapshot', '-Quiet', '-Config', $cfgPath)
  }
  $afterPruneDirs = @(Get-ChildItem -Path $snapDir -Directory)
  Assert-Eq $afterPruneDirs.Count 3 '8a: 超过 retainSnapshots(3) 的旧快照已自动清理，仅留 3 份'
  $rList = Run-Guard @('-List', '-Config', $cfgPath)
  Assert-Eq $rList.ExitCode 0 '8b: -List 退出码为 0'
  Assert-Contains $rList.Out '[latest]' '8c: -List 标出 [latest]'

  Write-Host "`n=== 7. 配置 JSON 写坏 -> 退出码 2 且不误删 ==="
  $badCfg = Join-Path $sandbox 'bad.config.json'
  [System.IO.File]::WriteAllText($badCfg, '{ invalid json !!!', $utf8NoBom)
  $rBad = Run-Guard @('-Check', '-Config', $badCfg)
  Assert-Eq $rBad.ExitCode 2 '7a: JSON 非法时退出码为 2'
  Assert-Eq @(Get-ChildItem -Path $snapDir -Directory).Count 3 '7b: 配置报错后未误删任何快照'
}
finally {
  Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==============================="
Write-Host ("自测完成：PASS={0}, FAIL={1}" -f $script:Pass, $script:Fail)
echo "===============================" | Out-Null
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
