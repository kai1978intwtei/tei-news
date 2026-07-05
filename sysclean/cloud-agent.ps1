#Requires -Version 5.1
<#
sysclean/cloud-agent.ps1 — 雲端輪詢器：讓 kai-bridge（雲端網頁）能遙控本機清潔

架構（雲端信箱模式）：
  手機開 kai-bridge 網頁 → 按鈕 → 指令存進 kai-bridge 後端佇列
                                        ↕（本程式輪詢）
  本機 cloud-agent 每 N 秒 → GET 取指令 → 執行清潔 → POST 回傳結果 → 網頁顯示

接口契約（kai-bridge 後端需提供這兩個端點，詳見 HANDOFF-kai-bridge.md）：
  GET  {baseUrl}/api/next?token={token}
       → 有指令：200 {"id":"<唯一碼>","command":"保養|健檢|深度預覽|深度清理"}
       → 沒指令：200 {"id":null}  或 204
  POST {baseUrl}/api/result   （JSON）
       body {"id":"<同上>","token":"<token>","status":"done|error","title":"...","log":"..."}

設定檔 cloud-agent.config.json（與本腳本同資料夾）：
  { "baseUrl": "https://kai-bridge.vercel.app", "token": "你的密鑰", "pollSeconds": 15 }

用法：
  設定：cloud-agent.ps1 -Setup -BaseUrl https://kai-bridge.vercel.app -Token 你的密鑰
  測試連線：cloud-agent.ps1 -TestOnce
  常駐輪詢：cloud-agent.ps1 -Watch
  開機自動常駐：cloud-agent.ps1 -RegisterStartup（移除：-UnregisterStartup）
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [string]$BaseUrl,
    [string]$Token,
    [int]$PollSeconds = 15,
    [switch]$Watch,
    [switch]$TestOnce,
    [switch]$RegisterStartup,
    [switch]$UnregisterStartup
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir 'cloud-agent.config.json'
$taskName   = 'Sysclean-CloudAgent'
$scanScript = Join-Path $scriptDir 'scan.ps1'
$tuneScript = Join-Path $scriptDir 'quick-tune.ps1'
$planScript = Join-Path $scriptDir 'make-plan.ps1'
$cleanScript= Join-Path $scriptDir 'clean.ps1'

# 手機/網頁指令 → 動作（中英別名皆收）
$remoteCommands = @{
    '保養' = 'tune'; 'tune' = 'tune'; 'clean' = 'tune'
    '健檢' = 'scan'; 'scan' = 'scan'; 'check' = 'scan'
    '深度預覽' = 'preview'; 'preview' = 'preview'
    '深度清理' = 'deep'; 'deep' = 'deep'; 'deepclean' = 'deep'
}

# ---------- 設定 ----------
if ($Setup) {
    if (-not $BaseUrl) { Write-Host '請加 -BaseUrl，例如 -BaseUrl https://kai-bridge.vercel.app' -ForegroundColor Red; exit 1 }
    [pscustomobject]@{
        baseUrl     = $BaseUrl.TrimEnd('/')
        token       = $Token
        pollSeconds = $PollSeconds
    } | ConvertTo-Json | Out-File -FilePath $configPath -Encoding utf8
    Write-Host "已寫入設定：$configPath" -ForegroundColor Green
    Write-Host '下一步：先測試連線 cloud-agent.ps1 -TestOnce，成功後 -RegisterStartup 開機常駐。' -ForegroundColor DarkGray
    exit 0
}

# ---------- 開機常駐 ----------
if ($UnregisterStartup) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "已移除雲端輪詢常駐：$taskName" -ForegroundColor Green
    } else { Write-Host '沒有找到雲端輪詢常駐排程' -ForegroundColor Yellow }
    exit 0
}
if ($RegisterStartup) {
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Watch" `
            -WorkingDirectory $scriptDir
        $trigger  = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'sysclean 雲端輪詢器：登入後常駐，收 kai-bridge 遙控指令' | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host '雲端輪詢器已設為開機常駐並立即在背景啟動。' -ForegroundColor Green
    } catch { Write-Host "常駐註冊失敗：$($_.Exception.Message)" -ForegroundColor Red }
    exit 0
}

# ---------- 讀設定 ----------
if (-not (Test-Path $configPath)) {
    Write-Host '尚未設定。請先執行：' -ForegroundColor Red
    Write-Host '  cloud-agent.ps1 -Setup -BaseUrl https://kai-bridge.vercel.app -Token 你的密鑰' -ForegroundColor Yellow
    exit 1
}
$cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$baseUrl = $cfg.baseUrl.TrimEnd('/')
$token   = $cfg.token
if ($cfg.pollSeconds) { $PollSeconds = [int]$cfg.pollSeconds }

function Invoke-Command-ByKey {
    param([string]$Key)
    $cmd = $remoteCommands[$Key]
    if (-not $cmd) { return @{ status = 'error'; title = "無法辨識的指令：$Key"; log = '可用：保養／健檢／深度預覽／深度清理' } }
    $log = @()
    $title = ''
    switch ($cmd) {
        'tune'    { $title = '一鍵保養（零風險清理）'; $log = @(& $tuneScript *>&1 | ForEach-Object { $_.ToString() }) }
        'scan'    { $title = '系統健檢掃描';           $log = @(& $scanScript -NoHtml *>&1 | ForEach-Object { $_.ToString() }) }
        'preview' {
            $title = '深度清理預覽（未執行）'
            $log  = @(& $scanScript -NoHtml *>&1 | ForEach-Object { $_.ToString() })
            $log += @(& $planScript *>&1 | ForEach-Object { $_.ToString() })
            $log += '------ 乾跑預覽（不會真的動）------'
            $log += @(& $cleanScript *>&1 | ForEach-Object { $_.ToString() })
        }
        'deep' {
            $title = '深度清理（已執行，可還原）'
            $log  = @(& $scanScript -NoHtml *>&1 | ForEach-Object { $_.ToString() })
            $log += @(& $planScript *>&1 | ForEach-Object { $_.ToString() })
            $log += '------ 實際執行（可還原）------'
            $log += @(& $cleanScript -Apply *>&1 | ForEach-Object { $_.ToString() })
        }
    }
    $status = if (($log -join "`n") -match '失敗|致命錯誤') { 'error' } else { 'done' }
    return @{ status = $status; title = $title; log = ($log -join "`n") }
}

function Poll-Once {
    $next = $null
    try {
        $uri = "$baseUrl/api/next"
        if ($token) { $uri += "?token=$([uri]::EscapeDataString($token))" }
        $next = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20 -Headers @{ 'X-Bridge-Token' = $token }
    } catch {
        Write-Host "[雲端] 取指令失敗：$($_.Exception.Message)" -ForegroundColor DarkGray
        return
    }
    if (-not $next -or -not $next.id -or -not $next.command) { return }  # 沒有待辦

    Write-Host "[雲端] 收到遙控指令：$($next.command)（id=$($next.id)）" -ForegroundColor Cyan
    $result = Invoke-Command-ByKey -Key ([string]$next.command).Trim()

    $body = @{ id = $next.id; token = $token; status = $result.status; title = $result.title; log = $result.log } | ConvertTo-Json -Depth 4
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/result" -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 | Out-Null
        Write-Host "[雲端] 已回傳結果：$($result.title)" -ForegroundColor Green
    } catch {
        Write-Host "[雲端] 回傳結果失敗：$($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------- 測試 / 常駐 ----------
Write-Host "=============== sysclean 雲端輪詢器 ===============" -ForegroundColor Cyan
Write-Host "kai-bridge：$baseUrl（每 $PollSeconds 秒檢查一次）" -ForegroundColor DarkGray

if ($TestOnce) {
    Write-Host '[測試] 嘗試連線並取一次指令…' -ForegroundColor Yellow
    try {
        $uri = "$baseUrl/api/next"; if ($token) { $uri += "?token=$([uri]::EscapeDataString($token))" }
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20 -Headers @{ 'X-Bridge-Token' = $token }
        Write-Host "[測試] 連線成功。回傳：$(($r | ConvertTo-Json -Compress))" -ForegroundColor Green
    } catch {
        Write-Host "[測試] 連線失敗：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host '請確認 kai-bridge 已提供 /api/next 端點，且 baseUrl／token 正確。' -ForegroundColor Yellow
    }
    exit 0
}

# 預設 -Watch 常駐
while ($true) {
    Poll-Once
    Start-Sleep -Seconds $PollSeconds
}
