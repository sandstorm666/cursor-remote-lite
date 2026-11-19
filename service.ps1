# Run the public relay at Windows logon, and restart it if it exits.
# Usage: powershell -ExecutionPolicy Bypass -File .\service.ps1 install | uninstall | start | stop | status | logs
param([Parameter(Position = 0)][string]$Command = 'help')
$ErrorActionPreference = 'Stop'

$TaskName = 'CursorRemoteLite'
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $HOME '.cursor-remote-lite'
$Log = Join-Path $DataDir 'server.log'
$Launcher = Join-Path $DataDir 'run-public.ps1'
$Port = if ($env:PORT) { $env:PORT } else { 3939 }

function Find-Exe([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $null
}

function Get-RelayProcesses {
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'server\.mjs' }
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

  @"
`$ErrorActionPreference = 'Continue'
`$env:PATH = '$nodeDirLit;$cfDirLit;' + `$env:PATH
Set-Location -LiteralPath '$dirLit'
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

  if (Test-RelayPort) {
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
  if ($procs.Count) { Write-Host "已停止 $($procs.Count) 个中继进程。" } else { Write-Host '当前没有在跑的中继。' }
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
}

switch ($Command) {
  'install' { Install-Relay }
  'uninstall' { Uninstall-Relay }
  'start' { Start-Relay }
  'stop' { Stop-Relay }
  'status' { Show-Status }
  'logs' {
    if (-not (Test-Path -LiteralPath $Log)) { Write-Host "还没有日志：$Log"; exit 0 }
    Get-Content -LiteralPath $Log -Tail 50 -Wait
  }
  default {
    Write-Host '用法：powershell -ExecutionPolicy Bypass -File .\service.ps1 install | uninstall | start | stop | status | logs'
    exit 1
  }
}
