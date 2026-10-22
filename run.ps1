# 飞书文档评论机器人常驻启动脚本
# 由任务计划程序在登录时调用，也可手动运行；进程异常退出后自动重试。
# 机器人自身的日志在 logs\bot.log（由 bot.py 写），本脚本只写 logs\runner.log。
$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location $Root

$Python = Join-Path $Root '.venv\Scripts\python.exe'
if (-not (Test-Path $Python)) {
    throw "找不到 $Python；请先执行：uv venv --python 3.12 .venv 然后 uv pip install --python .venv\Scripts\python.exe -r requirements.txt"
}
$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$RunnerLog = Join-Path $LogDir 'runner.log'

# 单实例：任务计划重复触发时后一个直接退出，避免两个进程抢同一个飞书长连接。
$mutex = New-Object System.Threading.Mutex($false, 'Local\feishu-doc-clarifier')
if (-not $mutex.WaitOne(0)) { return }

$env:PYTHONUTF8 = '1'

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message`r`n"
    [IO.File]::AppendAllText($RunnerLog, $line, [Text.UTF8Encoding]::new($false))
}

$delay = 15
while ($true) {
    $started = Get-Date
    Write-Log '[run] starting bot'
    # 不重定向输出：中文路径经 cmd 重定向会失败，日志由 bot.py 直接写文件。
    $proc = Start-Process -FilePath $Python -ArgumentList '-u', 'bot.py' `
        -WorkingDirectory $Root -WindowStyle Hidden -PassThru -Wait
    $ran = ((Get-Date) - $started).TotalSeconds
    Write-Log ('[run] bot exited code={0} after {1:N0}s' -f $proc.ExitCode, $ran)

    # 稳定跑过 10 分钟再挂，说明是偶发问题，重试间隔回到最短；否则指数退避到 5 分钟。
    if ($ran -gt 600) { $delay = 15 }
    Start-Sleep -Seconds $delay
    $delay = [Math]::Min($delay * 2, 300)
}
