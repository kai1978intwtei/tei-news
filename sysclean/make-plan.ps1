#Requires -Version 5.1
<#
sysclean/make-plan.ps1 — 依健檢報告自動產生「安全的」深度清理計畫 plan.json

這是「不用開 AI」的版本：讀 reports/latest.json，用保守規則挑出可還原、
低風險的動作寫成 plan.json，讓使用者接著在面板上乾跑預覽→核准執行。
（更聰明的判斷仍可交給 AI Agent 走 /pc-clean，本腳本是面板自助版。）

規則（全部可還原或零風險）：
  ● junk 全部 → cleanTemp / cleanBrowserCache / emptyRecycleBin（suggestedAction=manual 的跳過）
  ● hints 命中 knownHogs：
      suggest=disableStartup   → 找出「啟用中」的對應開機自啟項，停用（可還原）
      suggest=setServiceManual → 對應的第三方自動服務改手動（可還原）
  ● 不碰：結束程序、停排程、解除安裝（這些交給 AI 判斷或使用者手動）

用法：make-plan.ps1        （產生 plan.json）
      make-plan.ps1 -Quiet （安靜模式，給面板呼叫）
#>
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$reportPath = Join-Path $scriptDir 'reports\latest.json'
$planPath   = Join-Path $scriptDir 'plan.json'

function Say { param($m, $c = 'Gray') if (-not $Quiet) { Write-Host $m -ForegroundColor $c } }

if (-not (Test-Path $reportPath)) {
    Write-Host '找不到健檢報告，請先按「一鍵健檢」再產生計畫。' -ForegroundColor Red
    exit 1
}
$report = Get-Content $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json

$actions = @()

# ---------- 1. 垃圾檔案（零風險） ----------
foreach ($j in @($report.junk)) {
    switch ($j.suggestedAction) {
        'cleanTemp'         { $actions += [pscustomobject]@{ type = 'cleanTemp';         path = $j.path; reason = "清理 $($j.name)（約 $($j.sizeMB) MB）" } }
        'cleanBrowserCache' { $actions += [pscustomobject]@{ type = 'cleanBrowserCache'; path = $j.path; reason = "清理 $($j.name)（約 $($j.sizeMB) MB）" } }
        'emptyRecycleBin'   { $actions += [pscustomobject]@{ type = 'emptyRecycleBin';   reason = "清空資源回收筒（約 $($j.sizeMB) MB）" } }
        # manual（Windows.old / MEMORY.DMP）不自動處理
    }
}

# ---------- 2. 依 hints 停用開機自啟／服務改手動（可還原） ----------
foreach ($h in @($report.hints)) {
    if ($h.suggest -eq 'disableStartup') {
        # 找出對應且「啟用中」的自啟項
        $pat = [regex]::Escape($h.target)
        foreach ($s in @($report.startupItems)) {
            if ($s.state -ne 'enabled') { continue }
            if ("$($s.name) $($s.command)" -notmatch "(?i)$pat") { continue }
            if ($s.source -eq 'registry') {
                $actions += [pscustomobject]@{ type = 'disableStartupRegistry'; key = $s.key; name = $s.name; reason = "$($h.note)" }
            } elseif ($s.source -eq 'startupFolder') {
                $actions += [pscustomobject]@{ type = 'disableStartupFolder'; path = $s.command; reason = "$($h.note)" }
            }
        }
    }
    elseif ($h.suggest -eq 'setServiceManual') {
        $pat = [regex]::Escape($h.target)
        foreach ($svc in @($report.autoServices)) {
            if (-not $svc.thirdParty) { continue }
            if ("$($svc.name) $($svc.displayName)" -notmatch "(?i)$pat") { continue }
            $actions += [pscustomobject]@{ type = 'setServiceManual'; name = $svc.name; stop = $false; reason = "$($h.note)" }
        }
    }
}

# 去重（同 type + 關鍵欄位只留一筆）
$seen = @{}
$uniq = @()
foreach ($a in $actions) {
    $k = "$($a.type)|$($a.path)|$($a.name)|$($a.key)"
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = $true
    $uniq += $a
}

[pscustomobject]@{
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    createdBy = 'make-plan.ps1（面板自助版：只挑零風險與可還原動作）'
    actions   = $uniq
} | ConvertTo-Json -Depth 6 | Out-File -FilePath $planPath -Encoding utf8

$cleanCnt   = @($uniq | Where-Object { $_.type -in 'cleanTemp','cleanBrowserCache','emptyRecycleBin' }).Count
$startupCnt = @($uniq | Where-Object { $_.type -like 'disableStartup*' }).Count
$svcCnt     = @($uniq | Where-Object { $_.type -eq 'setServiceManual' }).Count

Say '=== 已產生清理計畫 plan.json ===' 'Cyan'
Say ("垃圾清理 {0} 項、停用開機自啟 {1} 項、服務改手動 {2} 項，共 {3} 個動作" -f $cleanCnt, $startupCnt, $svcCnt, $uniq.Count) 'Green'
if ($uniq.Count -eq 0) {
    Say '（沒有找到需要處理的項目 —— 你的電腦很乾淨，或健檢沒發現可自動處理的東西）' 'Yellow'
} else {
    Say '下一步：按「乾跑預覽 plan.json」看會做什麼，確認後再按「核准執行」。' 'DarkGray'
    Say '所有動作都可還原（clean.ps1 -Undo）。' 'DarkGray'
}
