# Run the public relay at Windows logon, and restart it if it exits.
# Usage: powershell -ExecutionPolicy Bypass -File .\service.ps1 install | uninstall | start | stop | status | logs
# `watch` is started by the logon task. It relaunches Cursor with the debugging port when Cursor is running without one (for example right after an update).
param([Parameter(Position = 0)][string]$Command = 'help')
$ErrorActionPreference = 'Stop'

$TaskName = 'CursorRemoteLite'
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $HOME '.cursor-remote-lite'
$Log = Join-Path $DataDir 'server.log'
$Launcher = Join-Path $DataDir 'run-public.ps1'
$Port = if ($env:PORT) { $env:PORT } else { 3939 }
$CdpPort = if ($env:CDP_PORT) { $env:CDP_PORT } else { 9222 }

function Find-Exe([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $null
}

function Get-RelayProcesses {
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'server\.mjs' }
}

function Get-WatcherProcesses {
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'service\.ps1' -and $_.CommandLine -match '\bwatch\b' }
}

function Test-CdpPort {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', [int]$CdpPort)
    $c.Close()
    $true
  } catch { $false }
}

function Test-RelayPort {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', [int]$Port)
    $c.Close()
    $true
  } catch { $false }
}

function Install-Relay {
  $node = Find-Exe 'node'
  $cloudflared = Find-Exe 'cloudflared'
  if (-not $node) { Write-Host '找不到 node。请先安装 Node.js 22+。'; exit 1 }
  if (-not $cloudflared) { Write-Host '找不到 cloudflared。请先安装：https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/'; exit 1 }

  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  $nodeDir = Split-Path -Parent $node
  $cloudflaredDir = Split-Path -Parent $cloudflared
  $dirLit = $Dir.Replace("'", "''")
  $logLit = $Log.Replace("'", "''")
  $nodeLit = $node.Replace("'", "''")
  $nodeDirLit = $nodeDir.Replace("'", "''")
  $cfDirLit = $cloudflaredDir.Replace("'", "''")
  $svcLit = $PSCommandPath.Replace("'", "''")

  @"
`$ErrorActionPreference = 'Continue'
`$env:PATH = '$nodeDirLit;$cfDirLit;' + `$env:PATH
Set-Location -LiteralPath '$dirLit'
`$watching = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { `$_.CommandLine -and `$_.CommandLine -match 'service\.ps1' -and `$_.CommandLine -match '\bwatch\b' }
if (-not `$watching) {
  Start-Process -WindowStyle Hidden powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$svcLit','watch'
}
& '$nodeLit' '$dirLit\server.mjs' --tunnel *>> '$logLit'
"@ | Set-Content -LiteralPath $Launcher -Encoding UTF8

  $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $user = "$env:USERDOMAIN\$env:USERNAME"
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

  if ($env:CR_INSTALL_NO_START -eq '1') {
    Write-Host '已更新登录自启（含调试端口检测）。这次没有启动。'
  } elseif (Test-RelayPort) {
    Write-Host "已设为登录后自动启动。当前端口 $Port 已有服务在跑，这次没有重启它。"
    Write-Host '下次登录会自动拉起。若要马上改由开机任务接管：先 stop，再 start。'
  } else {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host '已设为登录后自动启动，并已在后台启动。'
  }
  Write-Host "日志：$Log"
  Write-Host '查看状态：powershell -ExecutionPolicy Bypass -File .\service.ps1 status'
}

function Uninstall-Relay {
  Stop-Relay
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Launcher -Force -ErrorAction SilentlyContinue
  Write-Host '已停止，并移除登录自启。'
}

function Start-Relay {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $task) { Write-Host '还没安装。先运行：powershell -ExecutionPolicy Bypass -File .\service.ps1 install'; exit 1 }
  if (Test-RelayPort) { Write-Host "端口 $Port 已在监听，不用再启动。"; return }
  Start-ScheduledTask -TaskName $TaskName
  Write-Host "已启动。日志：$Log"
}

function Stop-Relay {
  $procs = @(Get-RelayProcesses)
  foreach ($p in $procs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
  # cloudflared is a child; stopping node should take it down. Sweep leftovers bound to this relay.
  Get-CimInstance Win32_Process -Filter "Name = 'cloudflared.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match '127\.0\.0\.1:' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  foreach ($w in @(Get-WatcherProcesses)) {
    Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue
  }
  if ($procs.Count) { Write-Host "已停止 $($procs.Count) 个中继进程。" } else { Write-Host '当前没有在跑的中继。' }
}

function Write-WatchLog([string]$msg) {
  $path = Join-Path $DataDir 'watch.log'
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg`r`n"
  try {
    $fs = [System.IO.File]::Open($path, 'Append', 'Write', 'ReadWrite')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $fs.Write($bytes, 0, $bytes.Length)
    $fs.Close()
  } catch {}
}

# Cursor updates relaunch the app without --remote-debugging-port. If Cursor is already open and the port stays down, quit and reopen it with the port.
function Watch-Cursor {
  $ErrorActionPreference = 'Continue'
  $others = @(Get-WatcherProcesses | Where-Object { $_.ProcessId -ne $PID })
  if ($others.Count) { exit 0 }
  $startScript = Join-Path $Dir 'start-cursor.ps1'
  $lastRestart = [datetime]::MinValue
  Write-WatchLog '调试端口检测已启动'
  while ($true) {
    Start-Sleep -Seconds 15
    if (Test-CdpPort) { continue }
    $procs = @(Get-Process -Name Cursor -ErrorAction SilentlyContinue)
    if (-not $procs.Count) { continue }
    $oldest = $procs | Where-Object { $_.StartTime } | Sort-Object StartTime | Select-Object -First 1
    if ($oldest -and ((Get-Date) - $oldest.StartTime).TotalSeconds -lt 30) { continue }
    if (((Get-Date) - $lastRestart).TotalSeconds -lt 90) { continue }
    $lastRestart = Get-Date
    Write-WatchLog 'Cursor 在运行但没有调试端口，正在重新打开'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript
  }
}

function Show-Status {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) { Write-Host "登录自启：已安装（$($task.State)）" } else { Write-Host '登录自启：未安装' }
  $procs = @(Get-RelayProcesses)
  if ($procs.Count) {
    Write-Host ("运行中：pid " + (($procs | ForEach-Object { $_.ProcessId }) -join ', '))
  } elseif (Test-RelayPort) {
    Write-Host "端口 $Port 在监听，但不是本脚本启动的 node server.mjs。"
  } else {
    Write-Host '运行中：否'
  }
  $watchers = @(Get-WatcherProcesses)
  if ($watchers.Count) { Write-Host '调试端口检测：开' } else { Write-Host '调试端口检测：关' }
  if (Test-CdpPort) { Write-Host "Cursor 调试端口 ${CdpPort}：开" } else { Write-Host "Cursor 调试端口 ${CdpPort}：关" }
}

switch ($Command) {
  'install' { Install-Relay }
  'uninstall' { Uninstall-Relay }
  'start' { Start-Relay }
  'stop' { Stop-Relay }
  'status' { Show-Status }
  'watch' { Watch-Cursor }
  'logs' {
    if (-not (Test-Path -LiteralPath $Log)) { Write-Host "还没有日志：$Log"; exit 0 }
    Get-Content -LiteralPath $Log -Tail 50 -Wait
  }
  default {
    Write-Host '用法：powershell -ExecutionPolicy Bypass -File .\service.ps1 install | uninstall | start | stop | status | logs'
    exit 1
  }
}
