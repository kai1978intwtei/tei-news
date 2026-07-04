#Requires -Version 5.1
<#
sysclean/quick-tune.ps1 — 一鍵安全保養（只做零風險動作，可全自動）

做什麼：
  1. 跑一次 scan.ps1 完整健檢（產生 JSON + HTML 報告）
  2. 自動清理 config.json 允許範圍內的暫存／快取（零風險，使用中檔案自動略過）
  3. 清 DNS 快取
  它「不會」動：開機自啟、服務、排程任務、資源回收筒、任何軟體 ——
  這些屬於要人核准的動作，交給 AI Agent 走 plan.json 流程。

用法：
  一鍵保養：powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\quick-tune.ps1
  連回收筒一起清：加 -IncludeRecycleBin
  註冊每週日 12:10 自動保養：加 -RegisterWeekly（移除排程：-Unregister）
#>
[CmdletBinding()]
param(
    [switch]$IncludeRecycleBin,
    [switch]$SkipScan,
    [switch]$RegisterWeekly,
    [switch]$Unregister
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName  = 'TEi-系統健檢-每週自動保養'

# ---------- 排程註冊／移除 ----------
if ($Unregister) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "已移除排程：$taskName" -ForegroundColor Green
    } else { Write-Host "沒有找到排程：$taskName" -ForegroundColor Yellow }
    exit 0
}
if ($RegisterWeekly) {
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" `
            -WorkingDirectory $scriptDir
        $trigger  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '12:10'
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'TEi sysclean 每週自動掃描＋零風險清理' | Out-Null
        Write-Host "已註冊排程：$taskName（每週日 12:10，僅零風險清理）" -ForegroundColor Green
    } catch {
        Write-Host "排程註冊失敗（可能需要系統管理員權限）：$($_.Exception.Message)" -ForegroundColor Red
    }
    exit 0
}

Write-Host '================ TEi 一鍵安全保養 ================' -ForegroundColor Cyan

# ---------- 1. 健檢掃描 ----------
if (-not $SkipScan) {
    & (Join-Path $scriptDir 'scan.ps1')
}

# ---------- 2. 產生零風險自動計畫 ----------
$config = Get-Content (Join-Path $scriptDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$actions = @()
foreach ($p in $config.allowedCleanPaths) {
    $expanded = [Environment]::ExpandEnvironmentVariables($p)
    if (Test-Path -LiteralPath $expanded) {
        $actions += [pscustomobject]@{ type = 'cleanTemp'; path = $p; reason = '每週自動保養：零風險暫存／快取' }
    }
}
$actions += [pscustomobject]@{ type = 'flushDns'; reason = '每週自動保養' }
if ($IncludeRecycleBin) {
    $actions += [pscustomobject]@{ type = 'emptyRecycleBin'; reason = '使用者指定連回收筒一起清' }
}

$autoPlanPath = Join-Path $scriptDir 'plan-auto.json'
[pscustomobject]@{
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    createdBy = 'quick-tune.ps1（僅零風險動作）'
    actions   = $actions
} | ConvertTo-Json -Depth 5 | Out-File -FilePath $autoPlanPath -Encoding utf8

# ---------- 3. 執行 ----------
& (Join-Path $scriptDir 'clean.ps1') -Plan $autoPlanPath -Apply

Write-Host ''
Write-Host '一鍵保養完成。深度優化（停自啟／服務／排程）請叫 AI Agent：' -ForegroundColor Cyan
Write-Host '「幫我健檢電腦並優化」→ 它會分析報告、列出計畫、經你同意後執行且可還原。' -ForegroundColor DarkGray
