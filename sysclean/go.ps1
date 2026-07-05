# ★ sysclean 統一入口 ★ —— 只要記這一行，全部功能都在裡面：
#   irm https://raw.githubusercontent.com/kai1978intwtei/tei-news/main/sysclean/go.ps1 | iex

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------- 確保工具存在並更新到最新版 ----------
$sys  = Join-Path $env:USERPROFILE 'tei-tools\sysclean'
# 若是從本機工具資料夾直接執行（例如桌面「清潔管家」按鈕），就地使用、不重新下載
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'control-panel.ps1'))) {
    $sys = $PSScriptRoot
}
$root = Split-Path -Parent $sys
$fromLocal = ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'control-panel.ps1')))
if ($fromLocal) {
    Write-Host '（本機模式，跳過下載）' -ForegroundColor DarkGray
} else {
Write-Host '正在取得最新版工具…' -ForegroundColor DarkGray
try {
    $tmp = Join-Path $env:TEMP ('sysclean-go-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'repo.zip'
    Invoke-WebRequest -Uri 'https://github.com/kai1978intwtei/tei-news/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $srcRoot = (Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'tei-news-*' } | Select-Object -First 1).FullName
    New-Item -ItemType Directory -Path $sys -Force | Out-Null
    Copy-Item -Path (Join-Path $srcRoot 'sysclean\*') -Destination $sys -Recurse -Force
    if (Test-Path (Join-Path $srcRoot '.claude')) {
        New-Item -ItemType Directory -Path (Join-Path $root '.claude') -Force | Out-Null
        Copy-Item -Path (Join-Path $srcRoot '.claude\*') -Destination (Join-Path $root '.claude') -Recurse -Force
    }
    if (Test-Path (Join-Path $srcRoot 'CLAUDE.md')) { Copy-Item (Join-Path $srcRoot 'CLAUDE.md') (Join-Path $root 'CLAUDE.md') -Force }
    Write-Host '工具已是最新版 ✓' -ForegroundColor Green
} catch {
    Write-Host "下載失敗（$($_.Exception.Message)），改用現有版本。" -ForegroundColor Yellow
}
}
if (-not (Test-Path (Join-Path $sys 'control-panel.ps1'))) {
    Write-Host '找不到工具且無法下載，請檢查網路後再試一次。' -ForegroundColor Red; return
}

function Run-Tool { param([string]$File, [string[]]$Args)
    & (Join-Path $sys $File) @Args
}

# ---------- 選單 ----------
:menu while ($true) {
    Write-Host ''
    Write-Host '===================================================' -ForegroundColor Cyan
    Write-Host '        🧹 電腦清潔管家 · 統一控制台' -ForegroundColor Cyan
    Write-Host '===================================================' -ForegroundColor Cyan
    Write-Host '  [1] 立即保養        清暫存＋瀏覽器快取＋DNS（零風險，最常用）'
    Write-Host '  [2] 打開清潔面板    網頁按鈕介面 http://localhost:8377'
    Write-Host '  [3] 系統健檢        掃描並打開報告（看電腦狀況）'
    Write-Host '  [4] 深度清理        健檢→產生計畫→乾跑預覽→問你要不要執行'
    Write-Host '  [5] 一鍵安裝/更新   桌面按鈕＋面板常駐＋每週保養＋AI 檢查'
    Write-Host '  [6] 手機遙控設定    把遙控器搬到 OneDrive，手機就能按'
    Write-Host '  [7] 修復面板        localhost 打不開時用這個'
    Write-Host '  [8] 打開 AI 管家    用中文對 AI 下令（需 Claude Code）'
    Write-Host '  [9] 全部移除        移除排程與桌面按鈕'
    Write-Host '  [0] 離開'
    Write-Host '---------------------------------------------------' -ForegroundColor DarkGray
    $c = Read-Host '請輸入數字後按 Enter'

    switch ($c) {
        '1' { Run-Tool 'quick-tune.ps1' }
        '2' { Run-Tool 'control-panel.ps1' -Args @('-RegisterStartup'); Start-Sleep 3; Start-Process 'http://localhost:8377/' }
        '3' { Run-Tool 'scan.ps1' -Args @('-OpenReport') }
        '4' {
            Run-Tool 'scan.ps1' -Args @('-NoHtml')
            Run-Tool 'make-plan.ps1'
            Write-Host ''
            Write-Host '--- 乾跑預覽（還沒真的動）---' -ForegroundColor Yellow
            Run-Tool 'clean.ps1'
            Write-Host ''
            $yes = Read-Host '以上是預覽。要真的執行嗎？（全部可還原）輸入 Y 執行，其他離開'
            if ($yes -match '^[Yy]') {
                Run-Tool 'clean.ps1' -Args @('-Apply')
                Write-Host '深度清理完成。若要還原，備份檔路徑在上方訊息中。' -ForegroundColor Green
            } else { Write-Host '已取消，沒有更動任何東西。' -ForegroundColor DarkGray }
        }
        '5' { Run-Tool 'install.ps1' }
        '6' { Run-Tool 'remote-setup.ps1' }
        '7' { Run-Tool 'control-panel.ps1' -Args @('-RegisterStartup'); Start-Sleep 3; Start-Process 'http://localhost:8377/' }
        '8' {
            if (Get-Command claude -ErrorAction SilentlyContinue) {
                Write-Host "在新視窗打開 AI 管家（工作目錄：$root）…" -ForegroundColor Green
                Start-Process powershell -ArgumentList "-NoExit -Command `"Set-Location '$root'; claude`""
            } else {
                Write-Host 'AI 管家需要 Claude Code。先跑選項 [5] 一鍵安裝會幫你裝。' -ForegroundColor Yellow
            }
        }
        '9' { Run-Tool 'install.ps1' -Args @('-Uninstall') }
        '0' { Write-Host '再見！' -ForegroundColor Cyan; break menu }
        default { Write-Host '請輸入 0～9 的數字。' -ForegroundColor Yellow }
    }
    if ($c -ne '0') { Write-Host ''; Read-Host '按 Enter 回選單' | Out-Null }
}
