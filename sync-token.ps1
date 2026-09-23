# ============================================================================
#  sync-token.ps1  —— 把本机最新登录态推送到 GitHub Secrets
# ============================================================================
#
#  作用：
#    从本机 WorkBuddy / Trae 桌面客户端的登录态文件里读出 token，
#    写入 GitHub 仓库的 Secrets，供云端 Actions 定时任务使用。
#
#  为什么需要它：
#    云端只存一份静态 token，会过期（WorkBuddy 约 55 天，Trae 约 2 周）。
#    你每天用电脑时它自动刷新一遍，云端就永远有有效令牌，
#    你完全不用手动复制粘贴。
#
#  ┌─ 前置准备（二选一，推荐方式 A）──────────────────────────────────────┐
#  │                                                                     │
#  │  方式 A：安装 GitHub CLI（最简单，强烈推荐）                          │
#  │    winget install --id GitHub.cli                                   │
#  │    安装后执行一次：gh auth login                                     │
#  │    之后本脚本会自动调用 gh secret set，无需任何加密代码。              │
#  │                                                                     │
#  │  方式 B：用 Personal Access Token + Python                          │
#  │    1) 建一个细粒度 PAT，只勾 Actions Secrets 的 Read and write 权限   │
#  │    2) pip install pynacl                                            │
#  │    3) setx GH_PAT "你的PAT"                                          │
#  │       setx GH_REPO "用户名/仓库名"                                    │
#  │                                                                     │
#  └─────────────────────────────────────────────────────────────────────┘
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File sync-token.ps1
#    加 -Quiet 静默运行（适合开机自启 / 计划任务）
# ============================================================================

param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Script:LogFile = Join-Path $PSScriptRoot 'sync-token.log'
$Script:FailCount = 0

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 } catch { }
    if (-not $Quiet) {
        $color = switch ($Level) {
            'ERROR' { 'Red' }
            'WARN'  { 'Yellow' }
            'OK'    { 'Green' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

# ---------------------------------------------------------------------------
#  工具：定位 gh.exe 与 python
# ---------------------------------------------------------------------------
function Get-GhPath {
    $p = Get-Command gh -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    foreach ($candidate in @(
        "$env:ProgramFiles\GitHub CLI\gh.exe",
        "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe",
        "$env:LOCALAPPDATA\GitHubCLI\gh.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Get-PythonPath {
    # ⚠️ Windows 上 `Get-Command python` 可能命中 Microsoft Store 的应用执行
    #    别名（WindowsApps\python.exe 占位符），它只打印 "Python was not found"。
    #    因此必须实际执行验证 + 排除 WindowsApps 路径。
    $candidates = @()

    foreach ($guess in @(
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python313\python.exe"
    )) {
        if (Test-Path $guess) { $candidates += $guess }
    }
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
    foreach ($cmd in @('python', 'python3', 'py')) {
        $p = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($p) { $candidates += $p.Source }
    }

    foreach ($exe in ($candidates | Select-Object -Unique)) {
        if ($exe -like '*WindowsApps*') { continue }
        if (-not (Test-Path $exe)) { continue }
        try {
            $ver = & $exe --version 2>&1
            if ($LASTEXITCODE -ne 0 -or $ver -notmatch 'Python\s+3') { continue }
            # 确认 PyNaCl 已安装
            & $exe -c 'import nacl' 2>$null
            if ($LASTEXITCODE -eq 0) { return $exe }
        }
        catch { continue }
    }
    return $null
}

# ---------------------------------------------------------------------------
#  读取 WorkBuddy 登录态
# ---------------------------------------------------------------------------
function Get-WorkBuddyToken {
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path $env:USERPROFILE 'AppData\Local'
    }
    $path = Join-Path $base 'CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info'
    if (-not (Test-Path $path)) {
        Write-Log 'WARN' "[WorkBuddy] 未找到登录态文件: $path"
        return $null
    }
    try {
        $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $token = $json.auth.accessToken
        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Log 'WARN' '[WorkBuddy] accessToken 为空'
            return $null
        }
        if ($json.auth.expiresAt) {
            $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$json.auth.expiresAt).ToLocalTime()
            $days = [math]::Round(($exp - (Get-Date)).TotalDays, 1)
            $lvl = if ($days -lt 5) { 'WARN' } else { 'INFO' }
            Write-Log $lvl ("[WorkBuddy] accessToken 有效期至 {0:yyyy-MM-dd HH:mm}（剩余 {1} 天）" -f $exp, $days)
        }
        return $token
    }
    catch {
        Write-Log 'ERROR' "[WorkBuddy] 解析登录态失败: $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------------------
#  读取并解密 Trae 登录态
# ---------------------------------------------------------------------------
#  加密格式：[6 字节头 74 63 05 10 00 00][32 字节密钥材料][AES-CBC 密文]
#  密钥派生（与 C# 版 PlatformAuth.cs 完全一致）：
#    n = SHA512(keyMaterial) || (Woe[i] ^ Voe[i])     // 128 字节
#    n[0..64] = SHA512(n)
#    aesKey = n[0..16]，iv = n[16..32]
#    明文 = SHA512(payload) || payload

$Script:Woe = @(
    82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,
    124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,
    84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,
    8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37
)
$Script:Voe = @(
    31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,
    96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,
    160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,
    23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125
)

function Get-TraeAuth {
    $roaming = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($roaming)) {
        $roaming = Join-Path $env:USERPROFILE 'AppData\Roaming'
    }

    foreach ($profile in @('TRAE SOLO CN', 'Trae CN', 'TRAE SOLO', 'Trae')) {
        $file = Join-Path $roaming "$profile\User\globalStorage\storage.json"
        if (-not (Test-Path $file)) { continue }

        try {
            $json = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json

            $encB64 = $null
            $deviceId = ''
            foreach ($prop in $json.PSObject.Properties) {
                if ($prop.Name -eq 'iCubeAuthInfo://icube.cloudide') {
                    $encB64 = $prop.Value
                }
                elseif ($prop.Name -like 'iCubeAuthInfo://icube-dc:*') {
                    $deviceId = $prop.Name.Substring($prop.Name.LastIndexOf(':') + 1)
                }
            }
            if ([string]::IsNullOrWhiteSpace($encB64)) { continue }

            $blob = [Convert]::FromBase64String($encB64.Trim())
            if ($blob.Length -le 102) { continue }

            $headerOk = ($blob[0] -eq 116 -and $blob[1] -eq 99 -and $blob[2] -eq 5 -and
                         $blob[3] -eq 16  -and $blob[4] -eq 0  -and $blob[5] -eq 0)
            if (-not $headerOk) { continue }

            $keyMaterial = New-Object byte[] 32
            [Array]::Copy($blob, 6, $keyMaterial, 0, 32)

            $sha = [System.Security.Cryptography.SHA512]::Create()
            $hashKm = $sha.ComputeHash($keyMaterial)
            $mask = New-Object byte[] 64
            for ($i = 0; $i -lt 64; $i++) { $mask[$i] = $Script:Woe[$i] -bxor $Script:Voe[$i] }

            $n = New-Object byte[] 128
            [Array]::Copy($hashKm, 0, $n, 0, 64)
            [Array]::Copy($mask, 0, $n, 64, 64)
            $derived = $sha.ComputeHash($n)

            $aesKey = New-Object byte[] 16
            $iv = New-Object byte[] 16
            [Array]::Copy($derived, 0, $aesKey, 0, 16)
            [Array]::Copy($derived, 16, $iv, 0, 16)

            $cipherLen = $blob.Length - 38
            $cipher = New-Object byte[] $cipherLen
            [Array]::Copy($blob, 38, $cipher, 0, $cipherLen)

            $aes = [System.Security.Cryptography.Aes]::Create()
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $aesKey
            $aes.IV = $iv
            $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)

            if ($plain.Length -le 64) { continue }

            # 校验和
            $payloadBytes = New-Object byte[] ($plain.Length - 64)
            [Array]::Copy($plain, 64, $payloadBytes, 0, $payloadBytes.Length)
            $expect = $sha.ComputeHash($payloadBytes)
            $valid = $true
            for ($i = 0; $i -lt 64; $i++) {
                if ($expect[$i] -ne $plain[$i]) { $valid = $false; break }
            }
            if (-not $valid) { continue }

            $info = [System.Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace($info.token)) { continue }

            if ($info.expiredAt) {
                $exp = [DateTimeOffset]::Parse($info.expiredAt).ToLocalTime()
                $days = [math]::Round(($exp - (Get-Date)).TotalDays, 1)
                $lvl = if ($days -lt 3) { 'WARN' } else { 'INFO' }
                Write-Log $lvl ("[Trae] 客户端 {0}，令牌到期 {1:yyyy-MM-dd HH:mm}（剩余 {2} 天）" -f $profile, $exp, $days)
            }

            return [PSCustomObject]@{
                Token    = $info.token
                DeviceId = $deviceId
                Profile  = $profile
            }
        }
        catch {
            Write-Log 'WARN' "[Trae] 解析 $profile 失败: $($_.Exception.Message)"
            continue
        }
    }
    Write-Log 'WARN' '[Trae] 未找到可用登录态（请先登录 Trae 桌面客户端）'
    return $null
}

# ---------------------------------------------------------------------------
#  写入 Secret —— 方式 A：GitHub CLI
# ---------------------------------------------------------------------------
function Set-SecretViaGh {
    param([string]$Gh, [string]$Repo, [string]$Name, [string]$Value)

    # gh secret set 从 stdin 读取值，避免命令行泄露
    $Value | & $Gh secret set $Name --repo $Repo 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "gh secret set 失败（退出码 $LASTEXITCODE），请确认已 gh auth login 且对仓库有权限"
    }
    Write-Log 'OK' "[GitHub] Secret $Name 已更新（via gh）"
}

# ---------------------------------------------------------------------------
#  写入 Secret —— 方式 B：PAT + Python/PyNaCl
# ---------------------------------------------------------------------------
function Set-SecretViaPat {
    param([string]$Pat, [string]$Repo, [string]$Name, [string]$Value, [string]$Python)

    $headers = @{
        'Authorization'        = "Bearer $Pat"
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'DailyCheckin-Sync'
    }

    $pubKey = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$Repo/actions/secrets/public-key" `
        -Headers $headers -Method Get
    if (-not $pubKey.key) { throw '获取仓库公钥失败（检查 PAT 权限与仓库名）' }

    $py = @'
import sys, base64
from nacl import encoding, public
pub = public.PublicKey(sys.argv[1].encode(), encoding.Base64Encoder)
print(base64.b64encode(public.SealedBox(pub).encrypt(sys.argv[2].encode())).decode())
'@
    $tmp = Join-Path $env:TEMP ("sb_" + [guid]::NewGuid().ToString('N') + ".py")
    try {
        Set-Content -Path $tmp -Value $py -Encoding UTF8
        $enc = (& $Python $tmp $pubKey.key $Value 2>&1 | Select-Object -Last 1).ToString().Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($enc)) {
            throw "加密失败: $enc"
        }
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    $body = @{ encrypted_value = $enc; key_id = $pubKey.key_id } | ConvertTo-Json
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/secrets/$Name" `
        -Headers $headers -Method Put -Body $body -ContentType 'application/json' | Out-Null
    Write-Log 'OK' "[GitHub] Secret $Name 已更新（via PAT）"
}

function Sync-Secret {
    param([string]$Name, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return }

    if ($Script:Mode -eq 'gh') {
        Set-SecretViaGh -Gh $Script:Gh -Repo $Script:Repo -Name $Name -Value $Value
    }
    else {
        Set-SecretViaPat -Pat $Script:Pat -Repo $Script:Repo -Name $Name -Value $Value -Python $Script:Python
    }
}

# ---------------------------------------------------------------------------
#  主流程
# ---------------------------------------------------------------------------
Write-Log 'INFO' '========== 同步登录态到 GitHub Secrets =========='

# 决定使用哪种模式
$Script:Gh = Get-GhPath
if ($Script:Gh) {
    # 用 gh 时需要知道目标仓库
    $Script:Repo = $env:GH_REPO
    if ([string]::IsNullOrWhiteSpace($Script:Repo)) {
        # 尝试从当前目录的 git remote 推断
        try {
            $remote = git remote get-url origin 2>$null
            if ($remote -match 'github\.com[:/](.+?)(?:\.git)?$') {
                $Script:Repo = $Matches[1]
                Write-Log 'INFO' "[GitHub] 从 git remote 推断仓库: $($Script:Repo)"
            }
        }
        catch { }
    }
    if ([string]::IsNullOrWhiteSpace($Script:Repo)) {
        Write-Log 'ERROR' '未指定仓库。请设置 GH_REPO 环境变量，例如: setx GH_REPO "用户名/仓库名"'
        Write-Log 'ERROR' '或在仓库目录下运行本脚本（自动读取 git remote origin）'
        exit 1
    }
    $Script:Mode = 'gh'
    Write-Log 'INFO' "使用 GitHub CLI 模式"
}
else {
    $Script:Pat = $env:GH_PAT
    $Script:Repo = $env:GH_REPO
    $Script:Python = Get-PythonPath

    if ([string]::IsNullOrWhiteSpace($Script:Pat) -or [string]::IsNullOrWhiteSpace($Script:Repo)) {
        Write-Log 'ERROR' '未检测到 GitHub CLI，且未配置 GH_PAT / GH_REPO。'
        Write-Log 'ERROR' ''
        Write-Log 'ERROR' '推荐做法（最简单）：'
        Write-Log 'ERROR' '  1) winget install --id GitHub.cli'
        Write-Log 'ERROR' '  2) gh auth login'
        Write-Log 'ERROR' '  3) 重新运行本脚本'
        Write-Log 'ERROR' ''
        Write-Log 'ERROR' '备选做法：'
        Write-Log 'ERROR' '  setx GH_PAT "你的细粒度PAT（Actions Secrets 读写权限）"'
        Write-Log 'ERROR' '  setx GH_REPO "用户名/仓库名"'
        Write-Log 'ERROR' '  pip install pynacl'
        exit 1
    }
    if (-not $Script:Python) {
        Write-Log 'ERROR' '未找到已安装 PyNaCl 的 Python。请执行: pip install pynacl'
        exit 1
    }
    $Script:Mode = 'pat'
    Write-Log 'INFO' '使用 PAT + PyNaCl 模式'
}

# --- 同步 WorkBuddy ---
$wbToken = Get-WorkBuddyToken
if ($wbToken) {
    try { Sync-Secret -Name 'WB_TOKEN' -Value $wbToken }
    catch {
        Write-Log 'ERROR' "[GitHub] 写入 WB_TOKEN 失败: $($_.Exception.Message)"
        $Script:FailCount++
    }
}
else { $Script:FailCount++ }

# --- 同步 Trae ---
$trae = Get-TraeAuth
if ($trae) {
    try {
        Sync-Secret -Name 'TRAE_TOKEN' -Value $trae.Token
        if ($trae.DeviceId) {
            Sync-Secret -Name 'TRAE_DEVICE_ID' -Value $trae.DeviceId
        }
    }
    catch {
        Write-Log 'ERROR' "[GitHub] 写入 Trae Secret 失败: $($_.Exception.Message)"
        $Script:FailCount++
    }
}
else { $Script:FailCount++ }

if ($Script:FailCount -gt 0) {
    Write-Log 'WARN' "========== 同步结束，$($Script:FailCount) 项失败 =========="
    exit 1
}
Write-Log 'OK' '========== 全部同步成功 =========='
exit 0
