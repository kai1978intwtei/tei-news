#Requires -Version 5.1
<#
sysclean/clean.ps1 — 個人電腦系統清理執行器（預設乾跑，加 -Apply 才會真的動作）

設計原則：
  1. 只執行 plan.json 裡明列的動作 —— 本腳本自己不做任何判斷或猜測
  2. 預設是「乾跑」（Dry-Run）：只顯示會做什麼，不會更動系統
  3. 白名單保護：config.json 裡的 protectedProcesses / protectedServices 絕對不碰
  4. 刪檔只限 config.json 的 allowedCleanPaths 範圍內（暫存／快取），其他一律拒絕
  5. 可逆動作（停用自啟、停用排程、服務改手動）全部先備份到 backups\，
     隨時可用 -Undo <備份檔> 一鍵還原

用法：
  預覽：powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\clean.ps1
  執行：powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\clean.ps1 -Apply
  還原：powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\clean.ps1 -Undo sysclean\backups\backup-XXXX.json

plan.json 支援的動作（見 plan.sample.json）：
  cleanTemp / cleanBrowserCache / emptyRecycleBin / disableStartupRegistry /
  disableStartupFolder / disableTask / setServiceManual / stopProcess / flushDns
#>
[CmdletBinding()]
param(
    [string]$Plan,
    [switch]$Apply,
    [string]$Undo
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$backupsDir = Join-Path $scriptDir 'backups'
$logsDir    = Join-Path $scriptDir 'logs'
foreach ($d in @($backupsDir, $logsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
if (-not $Plan) { $Plan = Join-Path $scriptDir 'plan.json' }

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logsDir "clean-$stamp.log"

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

# ---------- 讀設定 ----------
$config = $null
$configPath = Join-Path $scriptDir 'config.json'
if (Test-Path $configPath) {
    try { $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
if (-not $config) {
    Write-Log '致命錯誤：讀不到 config.json（白名單保護來源），為安全起見中止。' 'Red'
    exit 1
}
$protectedProcesses = @($config.protectedProcesses | ForEach-Object { $_.ToLowerInvariant() })
$protectedServices  = @($config.protectedServices  | ForEach-Object { $_.ToLowerInvariant() })
$allowedCleanPaths  = @($config.allowedCleanPaths | ForEach-Object {
    [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
})
$browserProfileRoots = @($config.browserProfileRoots | ForEach-Object {
    [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
})
$browserCacheSubdirs = @($config.browserCacheSubdirs)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { $sum = 0 }
        return [math]::Round($sum / 1MB, 1)
    } catch { return 0 }
}

function Test-AllowedCleanPath {
    param([string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path).TrimEnd('\')
    if ($expanded -match '\.\.') { return $null }   # 禁止路徑跳脫
    foreach ($allowed in $allowedCleanPaths) {
        if ($allowed.Contains('*')) {
            if ($expanded -like $allowed) { return $expanded }
            if ($expanded -like ($allowed + '\*')) { return $expanded }
        } else {
            if ($expanded.Equals($allowed, [System.StringComparison]::OrdinalIgnoreCase)) { return $expanded }
            if ($expanded.StartsWith($allowed + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $expanded }
        }
    }
    return $null
}

# =====================================================================
#  還原模式
# =====================================================================
if ($Undo) {
    if (-not (Test-Path $Undo)) { Write-Log "找不到備份檔：$Undo" 'Red'; exit 1 }
    $backup = Get-Content $Undo -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Log "=== 還原模式：$Undo（共 $(@($backup.entries).Count) 筆）===" 'Cyan'
    foreach ($e in $backup.entries) {
        switch ($e.type) {
            'registry' {
                try {
                    New-ItemProperty -Path $e.key -Name $e.name -Value $e.value -PropertyType String -Force | Out-Null
                    Write-Log "已還原登錄自啟項：$($e.name) → $($e.key)" 'Green'
                } catch { Write-Log "還原失敗（registry $($e.name)）：$($_.Exception.Message)" 'Red' }
            }
            'startupFolder' {
                try {
                    Move-Item -LiteralPath $e.backupPath -Destination $e.originalPath -Force
                    Write-Log "已還原啟動資料夾捷徑：$($e.originalPath)" 'Green'
                } catch { Write-Log "還原失敗（捷徑 $($e.originalPath)）：$($_.Exception.Message)" 'Red' }
            }
            'task' {
                try {
                    Enable-ScheduledTask -TaskPath $e.taskPath -TaskName $e.taskName | Out-Null
                    Write-Log "已重新啟用排程任務：$($e.taskPath)$($e.taskName)" 'Green'
                } catch { Write-Log "還原失敗（排程 $($e.taskName)）：$($_.Exception.Message)" 'Red' }
            }
            'service' {
                try {
                    $mode = switch ($e.oldStartMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { 'Automatic' } }
                    Set-Service -Name $e.name -StartupType $mode
                    if ($e.wasRunning -eq $true) { Start-Service -Name $e.name -ErrorAction SilentlyContinue }
                    Write-Log "已還原服務啟動模式：$($e.name) → $mode" 'Green'
                } catch { Write-Log "還原失敗（服務 $($e.name)）：$($_.Exception.Message)" 'Red' }
            }
            default { Write-Log "未知備份類型：$($e.type)，略過" 'Yellow' }
        }
    }
    Write-Log '=== 還原完成 ===' 'Cyan'
    exit 0
}

# =====================================================================
#  執行模式（預設乾跑）
# =====================================================================
if (-not (Test-Path $Plan)) {
    Write-Log "找不到計畫檔：$Plan" 'Red'
    Write-Log '請先執行 scan.ps1，讓 AI Agent 依 reports\latest.json 產生 plan.json（格式見 plan.sample.json）。' 'Yellow'
    exit 1
}
$planObj = $null
try { $planObj = Get-Content $Plan -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
    Write-Log "plan.json 解析失敗：$($_.Exception.Message)" 'Red'; exit 1
}
$actions = @($planObj.actions)
if ($actions.Count -eq 0) { Write-Log 'plan.json 裡沒有任何動作。' 'Yellow'; exit 0 }

$mode = if ($Apply) { '實際執行' } else { '乾跑預覽（不會更動系統）' }
Write-Log "=== 個人電腦系統清理執行器 · 模式：$mode ===" 'Cyan'
Write-Log "計畫檔：$Plan（$($actions.Count) 個動作）"
if (-not $isAdmin) { Write-Log '注意：目前非系統管理員權限，系統暫存／服務／HKLM 相關動作可能失敗。' 'Yellow' }

$backupEntries = @()
$freedMB = 0.0
$done = 0; $skipped = 0; $failed = 0

foreach ($a in $actions) {
    $reason = if ($a.reason) { "（原因：$($a.reason)）" } else { '' }
    switch ($a.type) {

        'cleanTemp' {
            $target = Test-AllowedCleanPath -Path $a.path
            if (-not $target) {
                Write-Log "拒絕：$($a.path) 不在 config.json 允許清理範圍內" 'Red'; $skipped++; break
            }
            $before = Get-FolderSizeMB -Path $target
            if (-not $Apply) {
                Write-Log "[乾跑] 會清空暫存：$target（目前約 $before MB）$reason" 'Yellow'; break
            }
            Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $after = Get-FolderSizeMB -Path $target
            $freed = [math]::Round($before - $after, 1)
            $freedMB += [math]::Max($freed, 0)
            Write-Log "已清理：$target（釋放約 $freed MB，使用中檔案自動略過）" 'Green'; $done++
        }

        'cleanBrowserCache' {
            $profPath = [Environment]::ExpandEnvironmentVariables([string]$a.path).TrimEnd('\')
            $okRoot = $false
            if ($profPath -notmatch '\.\.') {
                foreach ($r in $browserProfileRoots) {
                    if ($profPath -like $r -or $profPath.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)) { $okRoot = $true; break }
                }
            }
            if (-not $okRoot) {
                Write-Log "拒絕：$($a.path) 不是 config.json 允許的瀏覽器設定檔路徑" 'Red'; $skipped++; break
            }
            $before = 0.0
            foreach ($sub in $browserCacheSubdirs) { $before += Get-FolderSizeMB -Path (Join-Path $profPath $sub) }
            if (-not $Apply) {
                Write-Log "[乾跑] 會清瀏覽器快取（只清快取子目錄，不碰書籤/密碼/歷史/擴充功能）：$profPath（目前約 $([math]::Round($before,1)) MB）$reason" 'Yellow'; break
            }
            $browserProcs = Get-Process -Name chrome, msedge, brave, vivaldi, opera -ErrorAction SilentlyContinue
            if ($browserProcs) {
                Write-Log '提醒：瀏覽器仍開啟中，使用中的快取檔會自動略過（先關閉瀏覽器可清得更乾淨）' 'Yellow'
            }
            foreach ($sub in $browserCacheSubdirs) {
                $dir = Join-Path $profPath $sub
                if (Test-Path -LiteralPath $dir) {
                    Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            $after = 0.0
            foreach ($sub in $browserCacheSubdirs) { $after += Get-FolderSizeMB -Path (Join-Path $profPath $sub) }
            $freed = [math]::Round($before - $after, 1)
            $freedMB += [math]::Max($freed, 0)
            Write-Log "已清瀏覽器快取：$profPath（釋放約 $freed MB）" 'Green'; $done++
        }

        'emptyRecycleBin' {
            if (-not $Apply) { Write-Log "[乾跑] 會清空資源回收筒 $reason" 'Yellow'; break }
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                Write-Log '已清空資源回收筒' 'Green'; $done++
            } catch { Write-Log "清空資源回收筒失敗：$($_.Exception.Message)" 'Red'; $failed++ }
        }

        'disableStartupRegistry' {
            if ($a.key -notmatch '(?i)\\CurrentVersion\\Run$') {
                Write-Log "拒絕：$($a.key) 不是標準自啟 Run 機碼" 'Red'; $skipped++; break
            }
            $current = $null
            try { $current = (Get-ItemProperty -Path $a.key -Name $a.name -ErrorAction Stop).($a.name) } catch { }
            if ($null -eq $current) {
                Write-Log "略過：$($a.key) 裡找不到「$($a.name)」" 'Yellow'; $skipped++; break
            }
            if (-not $Apply) {
                Write-Log "[乾跑] 會停用開機自啟：$($a.name)（$current）$reason" 'Yellow'; break
            }
            try {
                Remove-ItemProperty -Path $a.key -Name $a.name -ErrorAction Stop
                $backupEntries += [pscustomobject]@{ type = 'registry'; key = $a.key; name = $a.name; value = [string]$current }
                Write-Log "已停用開機自啟：$($a.name)（已備份，可還原）" 'Green'; $done++
            } catch { Write-Log "停用失敗（$($a.name)）：$($_.Exception.Message)" 'Red'; $failed++ }
        }

        'disableStartupFolder' {
            if (-not (Test-Path -LiteralPath $a.path)) {
                Write-Log "略過：找不到捷徑 $($a.path)" 'Yellow'; $skipped++; break
            }
            if (-not $Apply) {
                Write-Log "[乾跑] 會移出啟動資料夾捷徑：$($a.path) $reason" 'Yellow'; break
            }
            try {
                $dest = Join-Path $backupsDir ("startup-folder-$stamp")
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                $backupPath = Join-Path $dest (Split-Path -Leaf $a.path)
                Move-Item -LiteralPath $a.path -Destination $backupPath -Force
                $backupEntries += [pscustomobject]@{ type = 'startupFolder'; originalPath = $a.path; backupPath = $backupPath }
                Write-Log "已移出啟動捷徑：$($a.path)（已備份，可還原）" 'Green'; $done++
            } catch { Write-Log "移出失敗（$($a.path)）：$($_.Exception.Message)" 'Red'; $failed++ }
        }

        'disableTask' {
            if ($a.taskPath -like '\Microsoft\*') {
                Write-Log "拒絕：不停用 Microsoft 系統排程（$($a.taskPath)$($a.taskName)）" 'Red'; $skipped++; break
            }
            if (-not $Apply) {
                Write-Log "[乾跑] 會停用排程任務：$($a.taskPath)$($a.taskName) $reason" 'Yellow'; break
            }
            try {
                Disable-ScheduledTask -TaskPath $a.taskPath -TaskName $a.taskName -ErrorAction Stop | Out-Null
                $backupEntries += [pscustomobject]@{ type = 'task'; taskPath = $a.taskPath; taskName = $a.taskName }
                Write-Log "已停用排程任務：$($a.taskPath)$($a.taskName)（可還原）" 'Green'; $done++
            } catch { Write-Log "停用排程失敗（$($a.taskName)）：$($_.Exception.Message)" 'Red'; $failed++ }
        }

        'setServiceManual' {
            if ($protectedServices -contains ([string]$a.name).ToLowerInvariant()) {
                Write-Log "拒絕：$($a.name) 在受保護服務白名單內，不得更動" 'Red'; $skipped++; break
            }
            $svc = Get-CimInstance Win32_Service -Filter "Name='$($a.name -replace "'","''")'" -ErrorAction SilentlyContinue
            if (-not $svc) { Write-Log "略過：找不到服務 $($a.name)" 'Yellow'; $skipped++; break }
            if (-not $Apply) {
                Write-Log "[乾跑] 會把服務改為手動啟動：$($a.name)（目前 $($svc.StartMode)/$($svc.State)）$reason" 'Yellow'; break
            }
            try {
                Set-Service -Name $a.name -StartupType Manual -ErrorAction Stop
                $wasRunning = ($svc.State -eq 'Running')
                if ($a.stop -eq $true -and $wasRunning) {
                    Stop-Service -Name $a.name -ErrorAction SilentlyContinue
                }
                $backupEntries += [pscustomobject]@{ type = 'service'; name = $a.name; oldStartMode = $svc.StartMode; wasRunning = $wasRunning }
                Write-Log "服務已改手動：$($a.name)（原 $($svc.StartMode)，可還原）" 'Green'; $done++
            } catch { Write-Log "服務更動失敗（$($a.name)）：$($_.Exception.Message)" 'Red'; $failed++ }
        }

        'stopProcess' {
            if ($protectedProcesses -contains ([string]$a.name).ToLowerInvariant()) {
                Write-Log "拒絕：$($a.name) 在受保護程序白名單內，不得結束" 'Red'; $skipped++; break
            }
            $procs = Get-Process -Name $a.name -ErrorAction SilentlyContinue
            if (-not $procs) { Write-Log "略過：$($a.name) 目前沒有在執行" 'Yellow'; $skipped++; break }
            if (-not $Apply) {
                Write-Log "[乾跑] 會結束程序：$($a.name)（$(@($procs).Count) 個，本次開機有效，重開機後不影響）$reason" 'Yellow'; break
            }
            try {
                $procs | Stop-Process -Force -ErrorAction Stop
                Write-Log "已結束程序：$($a.name)（僅本次，不影響下次開機）" 'Green'; $done++
            } catch { Write-Log "結束程序失敗（$($a.name)）：$($_.Exception.Message)" 'Red'; $failed++ }
        }

        'flushDns' {
            if (-not $Apply) { Write-Log "[乾跑] 會清除 DNS 快取 $reason" 'Yellow'; break }
            ipconfig /flushdns | Out-Null
            Write-Log '已清除 DNS 快取' 'Green'; $done++
        }

        default {
            Write-Log "未知動作類型：$($a.type)，略過" 'Yellow'; $skipped++
        }
    }
}

# ---------- 備份與摘要 ----------
$backupPath = $null
if ($Apply -and $backupEntries.Count -gt 0) {
    $backupPath = Join-Path $backupsDir "backup-$stamp.json"
    [pscustomobject]@{
        createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        plan      = $Plan
        entries   = $backupEntries
    } | ConvertTo-Json -Depth 6 | Out-File -FilePath $backupPath -Encoding utf8
}

Write-Log '=== 完成 ===' 'Cyan'
if ($Apply) {
    Write-Log ("結果：成功 {0}／略過 {1}／失敗 {2}；釋放空間約 {3} MB" -f $done, $skipped, $failed, [math]::Round($freedMB, 1))
    if ($backupPath) {
        Write-Log "備份檔：$backupPath" 'Green'
        Write-Log "如要全部還原：clean.ps1 -Undo `"$backupPath`"" 'Green'
    }
} else {
    Write-Log '以上是乾跑預覽。確認無誤後加上 -Apply 才會實際執行。' 'Yellow'
}
Write-Log "完整記錄：$logPath"
