# 注册登录自启的计划任务，并立即启动。重复执行会覆盖同名任务。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File install-task.ps1
$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$TaskName = 'FeishuDocClarifier'
$RunScript = Join-Path $Root 'run.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$user = "$env:USERDOMAIN\$env:USERNAME"

if (-not (Test-Path (Join-Path $Root '.venv\Scripts\python.exe'))) {
    throw '缺少 .venv，请先执行 uv venv --python 3.12 .venv 和 uv pip install --python .venv\Scripts\python.exe -r requirements.txt'
}

# 任务用的是绝对路径，工程目录可以整体搬走，但搬走后要重新执行本脚本。
$action = New-ScheduledTaskAction -Execute $powershell `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RunScript`"" `
    -WorkingDirectory $Root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force `
    -Description '飞书文档评论答疑机器人：登录后常驻，接收评论事件并自动回复' | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "已注册并启动计划任务 $TaskName"
Write-Host "查看状态：Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
Write-Host "停止：    Stop-ScheduledTask -TaskName $TaskName；停止后要连同 bot 进程一起结束"
Write-Host "卸载：    Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
