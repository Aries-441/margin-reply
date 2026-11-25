# 构建 Windows 安装包：下载 Python 嵌入式运行时、安装依赖、调用 Inno Setup 编译。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build-installer.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build-installer.ps1 -AppVersion 0.2.0
#
# 产物：installer\Output\MarginReply-Setup-<版本>.exe
#
# 首次构建需要联网下载 Python 和 PyPI 依赖；本机没有 Inno Setup 时会尝试用 winget 安装。
[CmdletBinding()]
param(
    [string]$AppVersion = '0.1.0',
    [string]$PythonVersion = '3.12.10',
    [string]$InnoSetupCompiler,
    [switch]$SkipRuntime,
    [switch]$NoInnoInstall
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$InstallerDir = Join-Path $Root 'installer'
$IssFile = Join-Path $InstallerDir 'MarginReply.iss'
$BuildDir = Join-Path $InstallerDir 'build'
$AppDir = Join-Path $BuildDir 'app'
$RuntimeDir = Join-Path $BuildDir 'runtime'
$DownloadDir = Join-Path $BuildDir 'downloads'
$OutputDir = Join-Path $InstallerDir 'Output'

$parts = $PythonVersion.Split('.')
if ($parts.Length -lt 2) { throw "PythonVersion 格式不对：$PythonVersion" }
$pythonShort = "python$($parts[0])$($parts[1])"
$pythonExe = Join-Path $RuntimeDir 'python.exe'

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-Download([string]$Url, [string]$Path) {
    if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 1024) {
        Write-Host "已存在，跳过下载：$Path"
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    Write-Host "下载：$Url"
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    # 先写 .part 再改名：下载中断时不会留下一个看似完整的半截文件。
    $partial = "$Path.part"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
        Move-Item -LiteralPath $partial -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        $ProgressPreference = $previous
    }
}

function Find-Iscc {
    if ($InnoSetupCompiler) {
        if (-not (Test-Path $InnoSetupCompiler)) {
            throw "找不到指定的 Inno Setup 编译器：$InnoSetupCompiler"
        }
        # 编译时会切到 installer 目录，相对路径必须先解析成绝对路径。
        return (Resolve-Path -LiteralPath $InnoSetupCompiler).Path
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

New-Item -ItemType Directory -Force -Path $BuildDir, $DownloadDir, $OutputDir | Out-Null

# ---------------------------------------------------------------------------
# 1. 准备内置 Python 运行时
# ---------------------------------------------------------------------------
if ($SkipRuntime) {
    if (-not (Test-Path $pythonExe)) {
        throw "-SkipRuntime 需要 installer\build\runtime 已存在，但找不到 $pythonExe"
    }
    Write-Step "使用已有 Python 运行时：$RuntimeDir"
} else {
    Write-Step "准备 Python $PythonVersion 嵌入式运行时"

    $embedZip = Join-Path $DownloadDir "python-$PythonVersion-embed-amd64.zip"
    $embedUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
    Get-Download -Url $embedUrl -Path $embedZip

    if (Test-Path $RuntimeDir) { Remove-Item -Recurse -Force $RuntimeDir }
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    Expand-Archive -LiteralPath $embedZip -DestinationPath $RuntimeDir -Force

    # 嵌入式发行版默认禁用 site-packages，这里打开并加入 Lib\site-packages。
    $pthFile = Join-Path $RuntimeDir "$pythonShort._pth"
    if (-not (Test-Path $pthFile)) {
        throw "嵌入式 Python 中缺少 $pthFile"
    }
    $pthLines = @(
        "$pythonShort.zip"
        '.'
        'Lib\site-packages'
        'import site'
    )
    [IO.File]::WriteAllLines($pthFile, $pthLines, [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeDir 'Lib\site-packages') | Out-Null

    $getPip = Join-Path $DownloadDir 'get-pip.py'
    Get-Download -Url 'https://bootstrap.pypa.io/get-pip.py' -Path $getPip
    Write-Host "安装 pip..."
    & $pythonExe $getPip --no-warn-script-location --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw "安装 pip 失败（exit $LASTEXITCODE）" }

    Write-Host "安装项目依赖..."
    & $pythonExe -m pip install --no-warn-script-location --disable-pip-version-check `
        -r (Join-Path $Root 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw "安装依赖失败（exit $LASTEXITCODE）" }
}

# ---------------------------------------------------------------------------
# 2. 组装安装目录
# ---------------------------------------------------------------------------
Write-Step "组装应用目录"
if (Test-Path $AppDir) { Remove-Item -Recurse -Force $AppDir }
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

$files = @(
    'bot.py'
    'supervisor.py'
    'run.ps1'
    'install-task.ps1'
    'uninstall-task.ps1'
    'requirements.txt'
    '.env.example'
    'README.md'
    'README.zh-CN.md'
    'LICENSE'
    'CONTRIBUTING.md'
)
foreach ($file in $files) {
    $source = Join-Path $Root $file
    if (-not (Test-Path $source)) { throw "缺少文件：$source" }
    Copy-Item -LiteralPath $source -Destination $AppDir
}

foreach ($dir in @('docs', 'examples')) {
    $source = Join-Path $Root $dir
    if (Test-Path $source) {
        Copy-Item -LiteralPath $source -Destination $AppDir -Recurse
    }
}

Write-Host "复制 Python 运行时..."
$appRuntime = Join-Path $AppDir 'runtime'
New-Item -ItemType Directory -Force -Path $appRuntime | Out-Null
Copy-Item -Path (Join-Path $RuntimeDir '*') -Destination $appRuntime -Recurse -Force

# 去掉编译缓存，减小安装包体积。
Get-ChildItem -Path $AppDir -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Step "验证安装包中的 Python 运行时和应用"
if (-not (Test-Path -LiteralPath (Join-Path $appRuntime 'pythonw.exe') -PathType Leaf)) {
    throw "安装包缺少 runtime\pythonw.exe，无法启动后台机器人"
}
Push-Location $AppDir
try {
    & (Join-Path $appRuntime 'python.exe') -B -c "import runpy; runpy.run_path('bot.py'); runpy.run_path('supervisor.py')"
    if ($LASTEXITCODE -ne 0) { throw "安装包中的应用加载失败，请检查内置 Python 及其依赖（exit $LASTEXITCODE）" }
} finally {
    Pop-Location
}

# ---------------------------------------------------------------------------
# 3. 调用 Inno Setup
# ---------------------------------------------------------------------------
$iscc = Find-Iscc
if (-not $iscc) {
    if (-not $NoInnoInstall) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Step "未找到 Inno Setup，尝试通过 winget 安装"
            & $winget.Source install --id JRSoftware.InnoSetup -e --silent `
                --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                throw "winget 安装 Inno Setup 失败（exit $LASTEXITCODE）。请手动安装：https://jrsoftware.org/isdl.php"
            }
            $iscc = Find-Iscc
        }
    }
}
if (-not $iscc) {
    throw "找不到 ISCC.exe。请安装 Inno Setup 6（https://jrsoftware.org/isdl.php），或用 -InnoSetupCompiler 指定路径。"
}

Write-Step "编译安装包"
Push-Location $InstallerDir
try {
    & $iscc "/DMyAppVersion=$AppVersion" $IssFile
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($exitCode -ne 0) { throw "Inno Setup 编译失败（exit $exitCode）" }

$setupPath = Join-Path $OutputDir "MarginReply-Setup-$AppVersion.exe"
if (-not (Test-Path $setupPath)) {
    throw "编译完成但找不到产物：$setupPath"
}
$sizeMb = [Math]::Round((Get-Item $setupPath).Length / 1MB, 1)

Write-Host ""
Write-Host "安装包已生成：" -ForegroundColor Green
Write-Host "  $setupPath ($sizeMb MB)"
Write-Host ""
Write-Host "提示：安装包未做代码签名，首次运行可能触发 Windows SmartScreen。"
