# 手动启动机器人（前台，便于 Ctrl+C 停止）。
#
# 计划任务不经过本脚本：它直接用 runtime\pythonw.exe supervisor.py 启动，
# 由 supervisor.py 负责单实例、重启退避和日志。前台运行时日志会同时打印到控制台。
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

& $Python (Join-Path $Root 'supervisor.py')
