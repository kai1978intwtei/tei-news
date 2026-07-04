#Requires -Version 5.1
<#
sysclean/install.ps1 — 一鍵安裝器（在你的電腦上跑一次，全部裝好）

會做的事：
  1. 桌面建立三顆按鈕捷徑：一鍵健檢／一鍵保養／一鍵面板
  2. 註冊每週日 12:10 自動保養排程（quick-tune）
  3. 註冊代理橋接器排程（每 10 分鐘處理 AI 交來的清理計畫）
  4. 檢查 Claude Code 是否已安裝，沒有就問你要不要現在裝
     （裝了它，AI Agent 才能「真的」在這台電腦執行工作）
  5. 立刻跑第一次健檢並打開報告

用法（在專案資料夾）：
  powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\install.ps1
  參數：-NoBridge 不裝橋接排程  -NoWeekly 不裝每週保養  -NoShortcuts 不建捷徑
        -NoScan 不跑第一次健檢  -Uninstall 移除排程與桌面捷徑
#>
[CmdletBinding()]
param(
    [switch]$NoBridge,
    [switch]$NoWeekly,
    [switch]$NoShortcuts,
    [switch]$NoScan,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop   = [Environment]::GetFolderPath('Desktop')
$buttons   = @('一鍵健檢', '一鍵保養', '一鍵面板')

# ---------- 移除模式 ----------
if ($Uninstall) {
    Write-Host '=== 移除 sysclean 排程與桌面捷徑 ===' -ForegroundColor Cyan
    & (Join-Path $scriptDir 'quick-tune.ps1') -Unregister
    & (Join-Path $scriptDir 'agent-bridge.ps1') -Unregister
    foreach ($b in $buttons) {
        $lnk = Join-Path $desktop "$b.lnk"
        if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "已移除捷徑：$b" -ForegroundColor Green }
    }
    Write-Host '移除完成（腳本檔案本身保留，資料夾直接刪掉即可完全清除）。' -ForegroundColor Cyan
    exit 0
}

Write-Host '=============== sysclean 一鍵安裝器 ===============' -ForegroundColor Cyan

# ---------- 1. 桌面按鈕 ----------
if (-not $NoShortcuts) {
    Write-Host '[1/5] 建立桌面按鈕…' -ForegroundColor Green
    try {
        $ws = New-Object -ComObject WScript.Shell
        foreach ($b in $buttons) {
            $bat = Join-Path $scriptDir "$b.bat"
            if (-not (Test-Path $bat)) { Write-Host "  找不到 $b.bat，略過" -ForegroundColor Yellow; continue }
            $sc = $ws.CreateShortcut((Join-Path $desktop "$b.lnk"))
            $sc.TargetPath = $bat
            $sc.WorkingDirectory = $scriptDir
            $sc.Description = "sysclean $b"
            $sc.Save()
            Write-Host "  桌面按鈕完成：$b" -ForegroundColor Green
        }
    } catch { Write-Host "  建立捷徑失敗：$($_.Exception.Message)" -ForegroundColor Red }
} else { Write-Host '[1/5] 略過桌面按鈕（-NoShortcuts）' -ForegroundColor DarkGray }

# ---------- 2. 每週自動保養 ----------
if (-not $NoWeekly) {
    Write-Host '[2/5] 註冊每週自動保養排程…' -ForegroundColor Green
    & (Join-Path $scriptDir 'quick-tune.ps1') -RegisterWeekly
} else { Write-Host '[2/5] 略過每週保養（-NoWeekly）' -ForegroundColor DarkGray }

# ---------- 3. 代理橋接器 ----------
if (-not $NoBridge) {
    Write-Host '[3/5] 註冊代理橋接器排程（每 10 分鐘處理 AI 交件）…' -ForegroundColor Green
    & (Join-Path $scriptDir 'agent-bridge.ps1') -RegisterTask
    Write-Host "  交件資料夾：$(Join-Path $scriptDir 'bridge\inbox')" -ForegroundColor DarkGray
    Write-Host '  （想讓雲端 AI 交件，之後可用 -BridgeDir 改指到 OneDrive 資料夾重新註冊）' -ForegroundColor DarkGray
} else { Write-Host '[3/5] 略過橋接器（-NoBridge）' -ForegroundColor DarkGray }

# ---------- 4. Claude Code（讓 AI 真的能在這台電腦執行） ----------
Write-Host '[4/5] 檢查 Claude Code…' -ForegroundColor Green
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host '  Claude Code 已安裝 ✓ 之後在本資料夾開它、輸入 /pc-clean 就是一鍵優化' -ForegroundColor Green
} else {
    Write-Host '  尚未安裝 Claude Code —— 裝了它，AI Agent 才能真的在這台電腦執行工作。' -ForegroundColor Yellow
    $ans = Read-Host '  現在安裝嗎？（從 claude.ai 官方安裝器下載）[Y/n]'
    if ($ans -eq '' -or $ans -match '^[Yy]') {
        try {
            Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' | Invoke-Expression
            Write-Host '  Claude Code 安裝完成。第一次使用請執行 claude 並登入你的帳號。' -ForegroundColor Green
        } catch {
            Write-Host "  安裝失敗：$($_.Exception.Message)" -ForegroundColor Red
            Write-Host '  可稍後手動安裝：以系統管理員開 PowerShell 執行 irm https://claude.ai/install.ps1 | iex' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  已略過。之後想裝：irm https://claude.ai/install.ps1 | iex' -ForegroundColor DarkGray
    }
}

# ---------- 5. 第一次健檢 ----------
if (-not $NoScan) {
    Write-Host '[5/5] 執行第一次健檢（唯讀，跑完自動打開報告）…' -ForegroundColor Green
    & (Join-Path $scriptDir 'scan.ps1') -OpenReport
} else { Write-Host '[5/5] 略過第一次健檢（-NoScan）' -ForegroundColor DarkGray }

Write-Host ''
Write-Host '=============== 安裝完成 ===============' -ForegroundColor Cyan
Write-Host '桌面按鈕：一鍵健檢／一鍵保養／一鍵面板（面板網址 http://localhost:8377）'
Write-Host '每週日 12:10 自動保養；橋接器每 10 分鐘收 AI 交件（深度動作仍需你核准）'
Write-Host 'AI 一鍵指令：在本資料夾開 Claude Code，輸入 /pc-clean'
Write-Host '全部移除：install.ps1 -Uninstall' -ForegroundColor DarkGray
