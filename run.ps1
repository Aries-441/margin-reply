# 飞书文档评论机器人常驻启动脚本
# 由任务计划程序在登录时调用，也可手动运行；进程异常退出后自动重试。
# 机器人自身的日志在 logs\bot.log（由 bot.py 写），本脚本只写 logs\runner.log。
$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location $Root

# 安装包内置 runtime\python.exe；从源码运行时退回 .venv。
$Python = @(
    (Join-Path $Root 'runtime\python.exe'),
    (Join-Path $Root '.venv\Scripts\python.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Python) {
    throw "找不到 Python 运行时。若通过安装包安装，请重新运行安装程序；若从源码运行，请先创建 .venv（见 README）。"
}
$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$RunnerLog = Join-Path $LogDir 'runner.log'
$StartupLog = Join-Path $LogDir 'bot.startup.log'
$StopFlag = Join-Path $Root '.stop-runner'

# 单实例：任务计划重复触发时后一个直接退出，避免两个进程抢同一个飞书长连接。
$mutex = New-Object System.Threading.Mutex($false, 'Local\feishu-doc-clarifier')
if (-not $mutex.WaitOne(0)) { return }

$env:PYTHONUTF8 = '1'
# 不写 __pycache__：安装目录保持干净，卸载时不会留下未跟踪的 .pyc。
$env:PYTHONDONTWRITEBYTECODE = '1'

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message`r`n"
    [IO.File]::AppendAllText($RunnerLog, $line, [Text.UTF8Encoding]::new($false))
}

$delay = 15
while ($true) {
    # 卸载/升级前置的停止标记：手动启动的 run.ps1 无法靠命令行匹配找到。
    if (Test-Path $StopFlag) {
        Remove-Item $StopFlag -Force -ErrorAction SilentlyContinue
        Write-Log '[run] stop requested, exiting'
        return
    }

    $started = Get-Date
    Write-Log '[run] starting bot'
    # 错误重定向到文件：bot.py 在 setup_logging() 之前崩溃时，bot.log 还不会存在，
    # 这些 traceback 是唯一的线索。Start-Process 走文件句柄，不受中文路径影响。
    $proc = Start-Process -FilePath $Python -ArgumentList '-u', 'bot.py' `
        -WorkingDirectory $Root -WindowStyle Hidden -PassThru -Wait `
        -RedirectStandardError $StartupLog
    $ran = ((Get-Date) - $started).TotalSeconds
    Write-Log ('[run] bot exited code={0} after {1:N0}s' -f $proc.ExitCode, $ran)

    # 稳定跑过 10 分钟再挂，说明是偶发问题，重试间隔回到最短；否则指数退避到 5 分钟。
    if ($ran -gt 600) { $delay = 15 }
    Start-Sleep -Seconds $delay
    $delay = [Math]::Min($delay * 2, 300)
}
