# sysclean 面板修復醫生 —— 貼一行自動診斷＋修復：
#   irm https://raw.githubusercontent.com/kai1978intwtei/tei-news/main/sysclean/doctor.ps1 | iex

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Test-Panel {
    param([int]$Port)
    try { return ((Invoke-WebRequest -Uri "http://localhost:$Port/ping" -UseBasicParsing -TimeoutSec 3).Content -eq 'ok') }
    catch { return $false }
}

Write-Host '=============== 面板修復醫生 ===============' -ForegroundColor Cyan

# ---------- 0. 找到工具位置（找不到就自動下載安裝） ----------
$candidates = @(
    (Join-Path (Get-Location).Path 'sysclean'),
    (Get-Location).Path,
    (Join-Path $env:USERPROFILE 'tei-tools\sysclean')
)
$sys = $candidates | Where-Object { Test-Path (Join-Path $_ 'control-panel.ps1') } | Select-Object -First 1
if (-not $sys) {
    Write-Host '[診斷] 這台電腦還沒有工具，先自動下載安裝…' -ForegroundColor Yellow
    Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/kai1978intwtei/tei-news/main/sysclean/get.ps1' | Invoke-Expression
    $sys = $candidates | Where-Object { Test-Path (Join-Path $_ 'control-panel.ps1') } | Select-Object -First 1
    if (-not $sys) { Write-Host '[失敗] 安裝後仍找不到工具，請把整個畫面訊息貼給 AI。' -ForegroundColor Red; return }
}
$panel = Join-Path $sys 'control-panel.ps1'
Write-Host "[診斷] 工具位置：$sys" -ForegroundColor DarkGray

# ---------- 1. 面板是不是其實活著 ----------
$port = 8377
if (Test-Panel -Port $port) {
    Write-Host '[結果] 面板本來就在跑！直接幫你打開。' -ForegroundColor Green
    Start-Process "http://localhost:$port/"
    return
}
Write-Host "[診斷] localhost:$port 目前沒有回應，開始修復…" -ForegroundColor Yellow

# ---------- 2. 埠是不是被別的程式占走 ----------
try {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        $pname = (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Write-Host "[診斷] 埠 $port 被「$pname」占用但不是面板 → 自動改用 8378" -ForegroundColor Yellow
        $port = 8378
    }
} catch { }

# ---------- 3. 測試能不能綁埠（找出權限問題） ----------
$canBind = $false
try {
    $t = New-Object System.Net.HttpListener
    $t.Prefixes.Add("http://localhost:$port/")
    $t.Start(); $t.Stop()
    $canBind = $true
} catch {
    $bindErr = $_.Exception.Message
    Write-Host "[診斷] 綁定埠失敗：$bindErr" -ForegroundColor Yellow
    if ($bindErr -match '(?i)access|denied|拒絕') {
        Write-Host '[修復] 權限被擋 → 跳出系統管理員視窗幫你開通（請按「是」）…' -ForegroundColor Yellow
        try {
            Start-Process netsh -Verb RunAs -Wait -ArgumentList "http add urlacl url=http://localhost:$port/ sddl=D:(A;;GX;;;WD)"
            $canBind = $true
        } catch { Write-Host '[修復] 你取消了授權，稍後可重跑本指令再試。' -ForegroundColor Red }
    }
}

# ---------- 4. 重新掛上開機常駐並立即啟動 ----------
Write-Host '[修復] 重新註冊面板常駐並在背景啟動…' -ForegroundColor Yellow
& $panel -RegisterStartup -Port $port
Start-Sleep -Seconds 6
if (Test-Panel -Port $port) {
    Write-Host "[結果] 修好了！網址：http://localhost:$port/（已設開機常駐，以後隨時打得開）" -ForegroundColor Green
    Start-Process "http://localhost:$port/"
    return
}

# ---------- 5. 常駐沒成功 → 改開看得見的視窗版 ----------
Write-Host '[修復] 背景常駐沒成功，改用視窗版啟動…' -ForegroundColor Yellow
Start-Process powershell -WindowStyle Minimized -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$panel`" -NoBrowser -Port $port"
Start-Sleep -Seconds 6
if (Test-Panel -Port $port) {
    Write-Host "[結果] 修好了（視窗版，最小化的 PowerShell 視窗不要關）。網址：http://localhost:$port/" -ForegroundColor Green
    Start-Process "http://localhost:$port/"
    return
}

# ---------- 6. 還是不行 → 把真正病因印出來 ----------
Write-Host '[失敗] 自動修復沒成功。現在直接在這個視窗跑面板，把出現的錯誤訊息整段複製貼給 AI：' -ForegroundColor Red
& $panel -NoBrowser -Port $port
