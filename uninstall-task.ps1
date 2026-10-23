# 停止并卸载登录自启任务。安装包的卸载程序也会调用本脚本。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-task.ps1 [-StopOnly]
#   -StopOnly  只停止任务和机器人进程，保留计划任务（用于升级重装前释放文件）。
param(
    [switch]$StopOnly
)
# 停止进程属于尽力而为：任何一步失败都不要让卸载程序卡住。
$ErrorActionPreference = 'Continue'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$TaskName = 'FeishuDocClarifier'
$StopFlag = Join-Path $Root '.stop-runner'

# 0. 给 run.ps1 留停止标记：手动在前台跑起来的 run.ps1 的父进程命令行里
#    没有 run.ps1，靠命令行匹配抓不到它，它会在机器人被杀后重新拉起。
New-Item -ItemType File -Force -Path $StopFlag -ErrorAction SilentlyContinue | Out-Null

# 1. 先停计划任务，阻止 run.ps1 再拉起新进程。
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}

# 只匹配本安装目录下的进程：结尾必须紧跟分隔符，避免误杀
# FeishuDocClarifier-test 这类同前缀的副本。
$rootPattern = [regex]::Escape($Root) + '\\'

# 2. 结束机器人进程（只匹配本安装目录下的 python/pythonw + bot.py）。
function Get-BotProcesses {
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match $rootPattern -and
            $_.CommandLine -match 'bot\.py'
        }
}

Get-BotProcesses | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# 等进程真正退出再返回：安装程序随后会删除被这些进程占用的文件。
$waited = 0
while ((Get-BotProcesses | Measure-Object).Count -gt 0 -and $waited -lt 50) {
    Start-Sleep -Milliseconds 100
    $waited++
}

# 3. 结束 run.ps1 守护进程（否则它会重新拉起机器人）。
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine -match $rootPattern -and
        $_.CommandLine -match 'run\.ps1'
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

if ($StopOnly) {
    Write-Host "已停止 $TaskName 及其机器人进程"
    return
}

# 4. 注销计划任务，并如实报告结果。这一步失败必须让用户知道：
#    残留的任务会在每次登录时指向已删除的 run.ps1。
if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
    Write-Host "计划任务 $TaskName 不存在，无需卸载"
    return
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "未能删除计划任务 $TaskName，请在任务计划程序中手动删除。"
    Write-Error "卸载计划任务失败：$TaskName"
    exit 1
}
Write-Host "已卸载计划任务 $TaskName"
