# install-task.ps1 —— 注册 / 卸载 / 查询 Windows 计划任务（默认 AgentIdentityCheck）
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-task.ps1 -Mode on [-TaskName AgentIdentityCheck] [-Time 22:30] [-Config .\identity.config.json]
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-task.ps1 -Mode off [-TaskName AgentIdentityCheck]
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-task.ps1 -Mode status [-TaskName AgentIdentityCheck]

[CmdletBinding()]
param(
  [ValidateSet('on', 'off', 'status')][string]$Mode = 'status',
  [string]$TaskName = 'AgentIdentityCheck',
  [string]$Time = '22:30',
  [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$guardPs1 = Join-Path $PSScriptRoot 'identity-guard.ps1'
$tplXml   = Join-Path $PSScriptRoot 'task.xml'

if ($Mode -eq 'status') {
  $q = & schtasks.exe /Query /TN $TaskName /V /FO LIST 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("计划任务未注册：{0}" -f $TaskName)
    exit 1
  }
  $q | Out-String | Write-Host
  exit 0
}

if ($Mode -eq 'off') {
  $del = & schtasks.exe /Delete /TN $TaskName /F 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("卸载失败或任务不存在：{0}" -f $TaskName)
    exit 1
  }
  Write-Host ("已卸载计划任务：{0}" -f $TaskName)
  exit 0
}

# Mode = on
if (-not (Test-Path $guardPs1)) { Write-Host "!! 找不到 $guardPs1"; exit 2 }
if (-not (Test-Path $tplXml))   { Write-Host "!! 找不到 $tplXml"; exit 2 }

if ([string]::IsNullOrWhiteSpace($Config)) {
  $Config = Join-Path $PSScriptRoot 'identity.config.json'
}
$Config = [System.IO.Path]::GetFullPath($Config)

if ($Time -notmatch '^\d{2}:\d{2}$') {
  Write-Host "!! -Time 格式必须为 HH:mm（例如 22:30）"
  exit 2
}

$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$startBoundary = (Get-Date).ToString('yyyy-MM-dd') + "T${Time}:00"
$psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guardPs1`" -Check -Quiet -Config `"$Config`""

$esc = {
  param([string]$s)
  $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

$xmlContent = [System.IO.File]::ReadAllText($tplXml, [System.Text.Encoding]::Unicode)
$xmlContent = $xmlContent.Replace('{{USER_ID}}', (& $esc $userId))
$xmlContent = $xmlContent.Replace('{{START_BOUNDARY}}', (& $esc $startBoundary))
$xmlContent = $xmlContent.Replace('{{COMMAND}}', (& $esc $psExe))
$xmlContent = $xmlContent.Replace('{{ARGUMENTS}}', (& $esc $psArgs))

$tmpXml = Join-Path $env:TEMP ("amem-task-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8) + ".xml")
try {
  [System.IO.File]::WriteAllText($tmpXml, $xmlContent, [System.Text.Encoding]::Unicode)
  $res = & schtasks.exe /Create /TN $TaskName /XML $tmpXml /F 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("!! 注册失败：{0}" -f ($res -join "`n"))
    exit 2
  }
  Write-Host ("已注册计划任务：{0}（每天 {1} + 登录后 5 分钟，StartWhenAvailable=true）" -f $TaskName, $Time)
} finally {
  Remove-Item -Path $tmpXml -Force -ErrorAction SilentlyContinue
}
exit 0
