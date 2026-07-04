#Requires -Version 5.1
<#
sysclean/remote-setup.ps1 — 手機遙控設定（把清潔遙控器搬到雲端，手機就能按）

做什麼：
  1. 找到你的 OneDrive 資料夾，在裡面建立 SyscleanRemote\inbox / outbox
  2. 在手機看得到的地方放好「現成指令檔範本」與說明
  3. 把橋接器重新指到這個雲端資料夾，並改成每 2 分鐘檢查一次
  之後：手機用 OneDrive App 把範本檔複製一份到 inbox，電腦幾分鐘內就會執行，
        結果寫回 outbox，手機打開就看得到。

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\remote-setup.ps1
  參數：-CloudDir "D:\我的雲端硬碟\SyscleanRemote"（自訂雲端資料夾，預設自動找 OneDrive）
        -Uninstall（把橋接器改回本機資料夾，並移除每 2 分鐘排程）
#>
[CmdletBinding()]
param(
    [string]$CloudDir,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridge = Join-Path $scriptDir 'agent-bridge.ps1'

if ($Uninstall) {
    Write-Host '把橋接器改回本機資料夾…' -ForegroundColor Cyan
    & $bridge -RegisterTask -IntervalMinutes 10
    Write-Host '已還原（手機遙控停用，本機 AI 交件仍可用）。' -ForegroundColor Green
    exit 0
}

# ---------- 1. 找雲端資料夾 ----------
if (-not $CloudDir) {
    $oneDrive = $env:OneDrive
    if (-not $oneDrive) { $oneDrive = $env:OneDriveConsumer }
    if (-not $oneDrive) { $oneDrive = $env:OneDriveCommercial }
    if (-not $oneDrive -or -not (Test-Path $oneDrive)) {
        Write-Host '找不到 OneDrive 資料夾。' -ForegroundColor Red
        Write-Host '請改用 -CloudDir 指定你的雲端同步資料夾，例如：' -ForegroundColor Yellow
        Write-Host '  remote-setup.ps1 -CloudDir "C:\Users\你\OneDrive\SyscleanRemote"' -ForegroundColor Yellow
        Write-Host '（Google Drive 桌面版也可以，指到你的雲端硬碟資料夾即可）' -ForegroundColor DarkGray
        exit 1
    }
    $CloudDir = Join-Path $oneDrive 'SyscleanRemote'
}

$inbox  = Join-Path $CloudDir 'inbox'
$outbox = Join-Path $CloudDir 'outbox'
$tpl    = Join-Path $CloudDir '指令範本_複製到inbox'
foreach ($d in @($CloudDir, $inbox, $outbox, $tpl)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------- 2. 放現成指令範本（手機複製即用） ----------
$commands = @(
    @{ file = '保養.txt';     desc = '一鍵保養：清暫存＋全瀏覽器快取＋DNS（零風險）' },
    @{ file = '健檢.txt';     desc = '系統健檢掃描，產生報告' },
    @{ file = '深度預覽.txt'; desc = '產生清理計畫並乾跑預覽（不會真的動）' },
    @{ file = '深度清理.txt'; desc = '執行深度清理（所有動作可在電腦上還原）' }
)
foreach ($c in $commands) {
    "這是遙控指令範本：$($c.desc)`r`n用法：把這個檔案「複製」一份到隔壁的 inbox 資料夾，電腦幾分鐘內就會執行。" |
        Out-File -FilePath (Join-Path $tpl $c.file) -Encoding utf8
}

@(
    '【手機遙控電腦清潔 · 使用說明】',
    '',
    '前提：家裡（或公司）那台電腦要開著、已登入 Windows、OneDrive 有在同步。',
    '',
    '步驟：',
    '1. 手機打開 OneDrive App → 進入 SyscleanRemote\指令範本_複製到inbox',
    '2. 長按你要的指令（例如「保養.txt」）→ 選「複製」→ 貼到 SyscleanRemote\inbox',
    '   （或直接在 inbox 裡「新增文字檔」，檔名打「保養」也可以）',
    '3. 等 2～5 分鐘，打開 SyscleanRemote\outbox 看「保養-結果.txt」就是執行結果',
    '',
    '四個指令：',
    '  保養     → 零風險清理（最常用，隨時可按）',
    '  健檢     → 只掃描看狀況，不清理',
    '  深度預覽 → 列出深度清理會做什麼（不執行）',
    '  深度清理 → 真的做深度清理（可還原）',
    '',
    '安全：電腦端白名單與備份還原照常把關；inbox 等於遙控權，別把這個',
    '資料夾分享給別人。'
) | Out-File -FilePath (Join-Path $CloudDir '★手機看我★_使用說明.txt') -Encoding utf8

# ---------- 3. 橋接器重新指向雲端、每 2 分鐘檢查 ----------
Write-Host '把橋接器指向雲端資料夾並設為每 2 分鐘檢查…' -ForegroundColor Cyan
& $bridge -RegisterTask -BridgeDir $CloudDir -IntervalMinutes 2

Write-Host ''
Write-Host '=============== 手機遙控已設定完成 ===============' -ForegroundColor Cyan
Write-Host "雲端遙控資料夾：$CloudDir" -ForegroundColor Green
Write-Host '手機打開 OneDrive App → SyscleanRemote，先看「★手機看我★_使用說明.txt」' -ForegroundColor Green
Write-Host '要清潔時：把「指令範本」裡的檔案複製到 inbox，2～5 分鐘後 outbox 看結果。' -ForegroundColor Green
Write-Host '停用手機遙控：remote-setup.ps1 -Uninstall' -ForegroundColor DarkGray
