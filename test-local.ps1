# ============================================================================
#  test-local.ps1  —— 本地验证签到逻辑（部署前先跑通）
# ============================================================================
#
#  在上传 GitHub 之前，先用本机真实 token 跑一遍 checkin.py，
#  确认两个平台都能正常签到，再去配 Actions。
#  这样能避免「上传了才发现令牌有问题」。
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File test-local.ps1
#    powershell -ExecutionPolicy Bypass -File test-local.ps1 -Only wb
# ============================================================================

param(
    [ValidateSet('all', 'wb', 'trae')]
    [string]$Only = 'all'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

Write-Host ""
Write-Host "========== 本地验证 DailyCheckin ==========" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
#  1. 找 Python
#  ⚠️ 注意：Windows 上 `Get-Command python` 可能命中 Microsoft Store 的
#     应用执行别名（WindowsApps\python.exe 占位符），它只会打印
#     "Python was not found" 并返回非零退出码。
#     因此必须实际执行一次验证，而不能只看命令是否存在。
# ---------------------------------------------------------------------------
function Get-Python {
    $candidates = @()

    # 1) 显式已知安装路径（优先级最高，绕开 WindowsApps 占位符）
    foreach ($guess in @(
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python313\python.exe",
        "$env:ProgramFiles\Python313\python.exe",
        "$env:ProgramFiles\Python312\python.exe"
    )) {
        if (Test-Path $guess) { $candidates += $guess }
    }

    # 2) 通配匹配 Python3xx 目录
    foreach ($root in @(
        "$env:LOCALAPPDATA\Programs\Python",
        "C:\Users\$env:USERNAME\AppData\Local\Programs\Python"
    )) {
        Get-ChildItem -Path $root -Filter 'Python3*' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $exe = Join-Path $_.FullName 'python.exe'
                if (Test-Path $exe) { $candidates += $exe }
            }
    }

    # 3) PATH 中的 python（可能命中 WindowsApps 占位符，稍后过滤）
    foreach ($cmd in @('python', 'python3', 'py')) {
        $p = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($p) { $candidates += $p.Source }
    }

    foreach ($exe in ($candidates | Select-Object -Unique)) {
        # 排除 Microsoft Store 占位符
        if ($exe -like '*WindowsApps*') { continue }
        if (-not (Test-Path $exe)) { continue }
        try {
            $ver = & $exe --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $ver -match 'Python\s+3') {
                return $exe
            }
        }
        catch { continue }
    }
    return $null
}

$python = Get-Python
if (-not $python) {
    Write-Host "[错误] 未找到可用的 Python 3。" -ForegroundColor Red
    Write-Host ""
    Write-Host "  如果你已经装了 Python，可能是 Windows 的'应用执行别名'干扰：" -ForegroundColor Yellow
    Write-Host "    设置 → 应用 → 高级应用设置 → 应用执行别名" -ForegroundColor Yellow
    Write-Host "    关闭 python.exe / python3.exe 这两项" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  或安装 Python: https://www.python.org/downloads/" -ForegroundColor Yellow
    Write-Host "    安装时务必勾选 Add Python to PATH" -ForegroundColor Yellow
    exit 1
}
Write-Host "Python: $python" -ForegroundColor Gray
$pyVer = & $python --version 2>&1
Write-Host "  版本: $pyVer" -ForegroundColor Gray

# 确保 requests 可用
& $python -c "import requests" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[提示] 缺少 requests 依赖，正在安装..." -ForegroundColor Yellow
    & $python -m pip install -q requests
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[错误] 安装 requests 失败，请手动执行: pip install requests" -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
#  2. 读取本机 token
# ---------------------------------------------------------------------------
function Get-WorkBuddyToken {
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    $path = Join-Path $base 'CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info'
    if (-not (Test-Path $path)) { return $null }
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return $json.auth.accessToken
}

function Get-TraeToken {
    $roaming = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($roaming)) { $roaming = Join-Path $env:USERPROFILE 'AppData\Roaming' }

    foreach ($profile in @('TRAE SOLO CN', 'Trae CN')) {
        $file = Join-Path $roaming "$profile\User\globalStorage\storage.json"
        if (-not (Test-Path $file)) { continue }

        $json = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $encB64 = $null; $deviceId = ''
        foreach ($prop in $json.PSObject.Properties) {
            if ($prop.Name -eq 'iCubeAuthInfo://icube.cloudide') { $encB64 = $prop.Value }
            elseif ($prop.Name -like 'iCubeAuthInfo://icube-dc:*') {
                $deviceId = $prop.Name.Substring($prop.Name.LastIndexOf(':') + 1)
            }
        }
        if ([string]::IsNullOrWhiteSpace($encB64)) { continue }

        # 复用 decrypt-trae.py 解密（走 --file 避免命令行长度限制）
        $decryptPy = Join-Path $here 'decrypt-trae.py'
        $decrypted = & $python $decryptPy --file $file 2>&1
        if ($LASTEXITCODE -ne 0) { continue }

        $info = $decrypted | ConvertFrom-Json
        if ($info.token) {
            return [PSCustomObject]@{ Token = $info.token; DeviceId = $deviceId; Profile = $profile }
        }
    }
    return $null
}

$env:ONLY = if ($Only -eq 'all') { '' } else { $Only }

if ($Only -ne 'trae') {
    Write-Host ""
    Write-Host "读取 WorkBuddy 登录态..." -ForegroundColor Gray
    $wb = Get-WorkBuddyToken
    if ($wb) {
        $env:WB_TOKEN = $wb
        Write-Host "  已获取 accessToken（长度 $($wb.Length)）" -ForegroundColor Green
    }
    else {
        Write-Host "  未找到 WorkBuddy 登录态" -ForegroundColor Yellow
    }
}

if ($Only -ne 'wb') {
    Write-Host ""
    Write-Host "读取 Trae 登录态..." -ForegroundColor Gray
    $trae = Get-TraeToken
    if ($trae) {
        $env:TRAE_TOKEN = $trae.Token
        $env:TRAE_DEVICE_ID = $trae.DeviceId
        Write-Host "  已获取令牌（客户端 $($trae.Profile)，设备号 $($trae.DeviceId)）" -ForegroundColor Green
    }
    else {
        Write-Host "  未找到 Trae 登录态" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
#  3. 执行签到
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========== 开始执行 ==========" -ForegroundColor Cyan
Write-Host ""

& $python (Join-Path $here 'checkin.py')
$code = $LASTEXITCODE

Write-Host ""
if ($code -eq 0) {
    Write-Host "========== 验证通过：两个平台都正常 ==========" -ForegroundColor Green
}
else {
    Write-Host "========== 验证未通过：请查看上方日志 ==========" -ForegroundColor Red
}
exit $code
