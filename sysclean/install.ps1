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
$buttons   = @(
    @{ name = '一鍵健檢'; script = 'scan.ps1';          extra = ' -OpenReport' },
    @{ name = '一鍵保養'; script = 'quick-tune.ps1';    extra = '' },
    @{ name = '一鍵面板'; script = 'control-panel.ps1'; extra = '' }
)

# ---------- 移除模式 ----------
if ($Uninstall) {
    Write-Host '=== 移除 sysclean 排程與桌面捷徑 ===' -ForegroundColor Cyan
    & (Join-Path $scriptDir 'quick-tune.ps1') -Unregister
    & (Join-Path $scriptDir 'agent-bridge.ps1') -Unregister
    & (Join-Path $scriptDir 'control-panel.ps1') -UnregisterStartup
    foreach ($n in (@($buttons | ForEach-Object { $_.name }) + 'AI管家')) {
        foreach ($ext in @('lnk', 'bat')) {
            $item = Join-Path $desktop "$n.$ext"
            if (Test-Path $item) { Remove-Item $item -Force; Write-Host "已移除桌面按鈕：$n.$ext" -ForegroundColor Green }
        }
    }
    Write-Host '移除完成（腳本檔案本身保留，資料夾直接刪掉即可完全清除）。' -ForegroundColor Cyan
    exit 0
}

Write-Host '=============== sysclean 一鍵安裝器 ===============' -ForegroundColor Cyan

# ---------- 1. 桌面按鈕 ----------
if (-not $NoShortcuts) {
    Write-Host '[1/6] 建立桌面按鈕…' -ForegroundColor Green
    $ws = $null
    try { $ws = New-Object -ComObject WScript.Shell } catch { }
    foreach ($b in $buttons) {
        $ps1 = Join-Path $scriptDir $b.script
        if (-not (Test-Path $ps1)) { Write-Host "  找不到 $($b.script)，略過" -ForegroundColor Yellow; continue }
        $done = $false
        # 方法一：標準 .lnk 捷徑
        if ($ws) {
            try {
                $sc = $ws.CreateShortcut((Join-Path $desktop "$($b.name).lnk"))
                $sc.TargetPath = 'powershell.exe'
                $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"$($b.extra)"
                $sc.WorkingDirectory = $scriptDir
                $sc.Description = "sysclean $($b.name)"
                $sc.Save()
                $done = $true
                Write-Host "  桌面按鈕完成：$($b.name)" -ForegroundColor Green
            } catch { }
        }
        # 方法二：OneDrive 桌面／中文路徑造成 .lnk 失敗時，改放啟動用 .bat（雙擊效果相同）
        if (-not $done) {
            try {
                $lines = @(
                    '@echo off',
                    "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ps1`"$($b.extra)",
                    'pause'
                )
                Set-Content -Path (Join-Path $desktop "$($b.name).bat") -Value $lines -Encoding Default
                $done = $true
                Write-Host "  桌面按鈕完成：$($b.name)（bat 版，雙擊一樣可用）" -ForegroundColor Green
            } catch { }
        }
        if (-not $done) {
            Write-Host "  無法放到桌面：$($b.name) —— 可直接雙擊 $scriptDir\$($b.name).bat 使用" -ForegroundColor Yellow
        }
    }

    # 第四顆：AI管家 —— 打開就是「能溝通、能下令、會動手」的本機 AI（Claude Code）
    $root = Split-Path -Parent $scriptDir
    $done = $false
    if ($ws) {
        try {
            $sc = $ws.CreateShortcut((Join-Path $desktop 'AI管家.lnk'))
            $sc.TargetPath = 'powershell.exe'
            $sc.Arguments = "-NoProfile -NoExit -Command `"Set-Location '$root'; claude`""
            $sc.WorkingDirectory = $root
            $sc.Description = '打開本機 AI 管家（用中文下令，它會真的執行）'
            $sc.Save()
            $done = $true
            Write-Host '  桌面按鈕完成：AI管家（雙擊開啟，直接用中文下令）' -ForegroundColor Green
        } catch { }
    }
    if (-not $done) {
        try {
            $lines = @('@echo off', "cd /d `"$root`"", 'claude')
            Set-Content -Path (Join-Path $desktop 'AI管家.bat') -Value $lines -Encoding Default
            Write-Host '  桌面按鈕完成：AI管家（bat 版，雙擊一樣可用）' -ForegroundColor Green
        } catch { Write-Host "  無法建立 AI管家 按鈕 —— 手動開法：PowerShell 輸入 cd `"$root`" 再輸入 claude" -ForegroundColor Yellow }
    }
} else { Write-Host '[1/6] 略過桌面按鈕（-NoShortcuts）' -ForegroundColor DarkGray }

# ---------- 2. 每週自動保養 ----------
if (-not $NoWeekly) {
    Write-Host '[2/6] 註冊每週自動保養排程…' -ForegroundColor Green
    & (Join-Path $scriptDir 'quick-tune.ps1') -RegisterWeekly
} else { Write-Host '[2/6] 略過每週保養（-NoWeekly）' -ForegroundColor DarkGray }

# ---------- 3. 代理橋接器 ----------
if (-not $NoBridge) {
    Write-Host '[3/6] 註冊代理橋接器排程（每 10 分鐘處理 AI 交件）…' -ForegroundColor Green
    & (Join-Path $scriptDir 'agent-bridge.ps1') -RegisterTask
    Write-Host "  交件資料夾：$(Join-Path $scriptDir 'bridge\inbox')" -ForegroundColor DarkGray
    Write-Host '  （想讓雲端 AI 交件，之後可用 -BridgeDir 改指到 OneDrive 資料夾重新註冊）' -ForegroundColor DarkGray
} else { Write-Host '[3/6] 略過橋接器（-NoBridge）' -ForegroundColor DarkGray }

# ---------- 4. 面板開機常駐（localhost:8377 隨時打得開） ----------
Write-Host '[4/6] 設定一鍵面板開機常駐（背景隱藏執行，網址隨時可開）…' -ForegroundColor Green
& (Join-Path $scriptDir 'control-panel.ps1') -RegisterStartup

# ---------- 5. Claude Code（讓 AI 真的能在這台電腦執行） ----------
Write-Host '[5/6] 檢查 Claude Code…' -ForegroundColor Green
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

# ---------- 6. 第一次健檢 ----------
if (-not $NoScan) {
    Write-Host '[6/6] 執行第一次健檢（唯讀，跑完自動打開報告）…' -ForegroundColor Green
    & (Join-Path $scriptDir 'scan.ps1') -OpenReport
} else { Write-Host '[6/6] 略過第一次健檢（-NoScan）' -ForegroundColor DarkGray }

Write-Host ''
Write-Host '=============== 安裝完成 ===============' -ForegroundColor Cyan
Write-Host '桌面按鈕：一鍵健檢／一鍵保養／一鍵面板（面板網址 http://localhost:8377）'
Write-Host '每週日 12:10 自動保養；橋接器每 2 分鐘收手機遙控指令與 AI 交件'
Write-Host 'AI 一鍵指令：在本資料夾開 Claude Code，輸入 /pc-clean'
Write-Host '手機遙控：跑 remote-setup.ps1 把遙控器搬到 OneDrive，手機就能按' -ForegroundColor Green
Write-Host '全部移除：install.ps1 -Uninstall' -ForegroundColor DarkGray
