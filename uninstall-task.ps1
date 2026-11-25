# 停止并卸载登录自启任务。安装包的卸载程序也会调用本脚本。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-task.ps1 [-StopOnly | -UnregisterOnly]
#   -StopOnly  只停止任务和机器人进程，保留计划任务（用于升级重装前释放文件）。
[CmdletBinding(DefaultParameterSetName = 'Uninstall')]
param(
    [Parameter(ParameterSetName = 'StopOnly')][switch]$StopOnly,
    [Parameter(ParameterSetName = 'UnregisterOnly')][switch]$UnregisterOnly
)
# 停止进程属于尽力而为：任何一步失败都不要让卸载程序卡住。
$ErrorActionPreference = 'Continue'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$TaskName = 'MarginReply'
$StopFlag = Join-Path $Root '.stop-runner'

function Unregister-LogonTask {
    $task = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -InputObject $task -Confirm:$false -ErrorAction Stop
    }
}

# 取消登录自启只改计划任务，手动启动由用户决定。
if ($UnregisterOnly) {
    Unregister-LogonTask
    return
}

# 只匹配本安装目录下的进程：结尾必须紧跟分隔符，避免误杀
# MarginReply-test 这类同前缀的副本。
$rootPattern = [regex]::Escape($Root) + '\\'

function Get-RootProcesses([string]$CommandPattern) {
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match $rootPattern -and
            $_.CommandLine -match $CommandPattern
        }
}

function Wait-BotExit {
    for ($i = 0; $i -lt 50; $i++) {
        if (-not (Get-RootProcesses '(supervisor|bot)\.py')) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return (-not (Get-RootProcesses '(supervisor|bot)\.py'))
}

# 0. 给 supervisor.py 留停止标记：它会在下一轮检查时结束机器人并退出。
#    手动前台启动的 supervisor 没有计划任务可停，靠这个标记才能优雅退出。
New-Item -ItemType File -Force -Path $StopFlag -ErrorAction SilentlyContinue | Out-Null

# 1. 先停计划任务，阻止 supervisor 再拉起新进程。
$task = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -InputObject $task -ErrorAction Stop
}

# 2. 给 supervisor 一点时间看到停止标记并自行退出（机器人也会随 Job 一起结束）。
if (-not (Wait-BotExit)) {
    # 先停守护进程，再停子进程，避免清理过程中重新拉起。
    foreach ($pattern in @('supervisor\.py', 'bot\.py')) {
        Get-RootProcesses $pattern | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Wait-BotExit)) { throw '机器人仍在运行，无法释放安装文件。' }
}

if ($StopOnly) {
    Write-Host "已停止 $TaskName 及其机器人进程"
    return
}

Unregister-LogonTask
Write-Host "已卸载计划任务 $TaskName"
