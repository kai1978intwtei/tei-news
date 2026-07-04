# sysclean 一行安裝引導器（不需要 git）
# 用法：開 PowerShell 貼上這一行：
#   irm https://raw.githubusercontent.com/kai1978intwtei/tei-news/main/sysclean/get.ps1 | iex
# 它會：下載最新工具 → 放到本機資料夾 → 自動啟動一鍵安裝器

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Write-Host '=============== sysclean 下載引導器 ===============' -ForegroundColor Cyan

# 1. 下載整包最新版
$zipUrl = 'https://github.com/kai1978intwtei/tei-news/archive/refs/heads/main.zip'
$tmp = Join-Path $env:TEMP ('sysclean-get-' + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'repo.zip'
Write-Host '[1/3] 下載最新工具中…' -ForegroundColor Green
Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$srcRoot = (Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'tei-news-*' } | Select-Object -First 1).FullName
if (-not $srcRoot) { Write-Host '下載內容異常，請稍後再試。' -ForegroundColor Red; return }

# 2. 決定安裝位置：若目前資料夾就是 tei-news 專案就地安裝，否則放到使用者資料夾
$cwd = (Get-Location).Path
if ((Test-Path (Join-Path $cwd 'fetch_news.ps1')) -or (Test-Path (Join-Path $cwd 'sysclean'))) {
    $target = $cwd
} else {
    $target = Join-Path $env:USERPROFILE 'tei-tools'
}
Write-Host "[2/3] 安裝到：$target" -ForegroundColor Green
$destSys = Join-Path $target 'sysclean'
New-Item -ItemType Directory -Path $destSys -Force | Out-Null
Copy-Item -Path (Join-Path $srcRoot 'sysclean\*') -Destination $destSys -Recurse -Force
if (Test-Path (Join-Path $srcRoot '.claude')) {
    $destClaude = Join-Path $target '.claude'
    New-Item -ItemType Directory -Path $destClaude -Force | Out-Null
    Copy-Item -Path (Join-Path $srcRoot '.claude\*') -Destination $destClaude -Recurse -Force
}

# 3. 交棒給一鍵安裝器（桌面按鈕＋排程＋橋接器＋Claude Code 檢查＋首次健檢）
Write-Host '[3/3] 啟動一鍵安裝器…' -ForegroundColor Green
& (Join-Path $destSys 'install.ps1')
