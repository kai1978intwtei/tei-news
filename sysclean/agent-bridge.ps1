#Requires -Version 5.1
<#
sysclean/agent-bridge.ps1 — 代理橋接器：讓「不能在本機執行命令」的 AI 也能執行清理

原理：
  在本機看守 bridge\inbox 資料夾。遠端 AI（ProjFlow 等）只要能把 plan JSON
  檔案送進這個資料夾（例如把 bridge\ 放在 OneDrive／Google Drive 同步資料夾，
  或任何它有權寫入的路徑），橋接器就會代為執行，並把結果寫回 bridge\outbox
  讓遠端 AI 讀取。

安全分級：
  ● 零風險動作（cleanTemp / cleanBrowserCache / emptyRecycleBin / flushDns）
    → 直接自動執行
  ● 深度動作（停自啟／停排程／服務改手動／結束程序）
    → 先乾跑產生預覽，檔案移到 bridge\pending 等你核准；
      你看過沒問題，把檔名改成 xxx.approved.json 丟回 inbox 才會執行
  ● 無論哪一級，clean.ps1 的白名單／允許路徑／備份還原全部照常把關，
    遠端 AI 寫出違規動作一律被拒絕。

用法：
  處理一輪就結束（給排程用）：agent-bridge.ps1 -Once
  常駐看守（每 30 秒檢查）  ：agent-bridge.ps1 -Watch
  註冊每 10 分鐘自動處理    ：agent-bridge.ps1 -RegisterTask（移除：-Unregister）
  自訂交件資料夾（例如放到 OneDrive）：-BridgeDir "C:\Users\你\OneDrive\sysclean-bridge"
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Watch,
    [int]$IntervalSeconds = 30,
    [int]$IntervalMinutes = 2,
    [string]$BridgeDir,
    [switch]$RegisterTask,
    [switch]$Unregister
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BridgeDir) { $BridgeDir = Join-Path $scriptDir 'bridge' }
$inbox     = Join-Path $BridgeDir 'inbox'
$outbox    = Join-Path $BridgeDir 'outbox'
$pending   = Join-Path $BridgeDir 'pending'
$processed = Join-Path $BridgeDir 'processed'
foreach ($d in @($BridgeDir, $inbox, $outbox, $pending, $processed)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$cleanScript = Join-Path $scriptDir 'clean.ps1'
$scanScript  = Join-Path $scriptDir 'scan.ps1'
$tuneScript  = Join-Path $scriptDir 'quick-tune.ps1'
$planScript  = Join-Path $scriptDir 'make-plan.ps1'
$taskName    = 'Sysclean-AgentBridge'

# 這些動作零風險，橋接器可自動放行；其他動作一律要人核准
$safeAutoTypes = @('cleanTemp', 'cleanBrowserCache', 'emptyRecycleBin', 'flushDns')

# 手機遙控指令：檔名（去副檔名、去「 (數字)」）對應動作。內容不用管，放進 inbox 就觸發。
# 中英別名都收，方便手機打字。
$remoteCommands = @{
    '保養'       = 'tune';    'tune'    = 'tune';    'clean'   = 'tune'
    '健檢'       = 'scan';    'scan'    = 'scan';    'check'   = 'scan'
    '深度預覽'   = 'preview'; 'preview' = 'preview'
    '深度清理'   = 'deep';    'deep'    = 'deep';    'deepclean' = 'deep'
}

# ---------- 排程註冊／移除 ----------
if ($Unregister) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "已移除排程：$taskName" -ForegroundColor Green
    } else { Write-Host "沒有找到排程：$taskName" -ForegroundColor Yellow }
    exit 0
}
if ($RegisterTask) {
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Once -BridgeDir `"$BridgeDir`"" `
            -WorkingDirectory $scriptDir
        # 確保遙控指令說明檔存在（手機端看得到怎麼用）
        $howto = Join-Path $BridgeDir '__手機遙控說明.txt'
        if (-not (Test-Path $howto)) {
            @(
                '【手機遙控電腦清潔】怎麼用：',
                '在手機的 OneDrive App 打開 inbox 資料夾，新增（或上傳）一個檔案，',
                '檔名決定要做什麼（副檔名 .txt 或 .cmd 都可，內容不用寫）：',
                '',
                '  保養.txt      → 一鍵保養（清暫存＋全瀏覽器快取＋DNS，零風險）',
                '  健檢.txt      → 系統健檢掃描（產生報告）',
                '  深度預覽.txt  → 依報告產生清理計畫並乾跑預覽（不會真的動）',
                '  深度清理.txt  → 執行深度清理（可還原）',
                '',
                '幾分鐘後，結果會出現在 outbox 資料夾，手機打開就能看。',
                '（電腦要開著、且已登入。深度清理的所有動作都可在電腦上還原。）'
            ) | Out-File -FilePath $howto -Encoding utf8
        }
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Description "sysclean 代理橋接器：每 $IntervalMinutes 分鐘處理手機遙控指令與 AI 清理計畫" | Out-Null
        Write-Host "已註冊排程：$taskName（每 $IntervalMinutes 分鐘檢查 $inbox）" -ForegroundColor Green
    } catch {
        Write-Host "排程註冊失敗（可能需要系統管理員權限）：$($_.Exception.Message)" -ForegroundColor Red
    }
    exit 0
}

function Write-BridgeResult {
    param([string]$PlanName, [string]$Status, [string]$Message, [string[]]$Log)
    $resultName = ($PlanName -replace '\.json$', '') + '.result.json'
    [pscustomobject]@{
        plan        = $PlanName
        processedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        status      = $Status
        message     = $Message
        log         = $Log
    } | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $outbox $resultName) -Encoding utf8
}

function Write-CmdResult {
    param([string]$CmdName, [string]$Title, [string[]]$Log)
    $safe = ($CmdName -replace '[^\w一-鿿\-]', '_')
    $stampNow = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $body = @("【$Title】", "完成時間：$stampNow", '', '------ 執行內容 ------') + $Log
    $body | Out-File -FilePath (Join-Path $outbox "$safe-結果.txt") -Encoding utf8
}

# 手機遙控指令檔（*.cmd / *.txt）：檔名對應動作，內容不用管
function Invoke-CommandFiles {
    $cmdFiles = @(Get-ChildItem -Path $inbox -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.cmd', '.txt' -and $_.Name -ne '__手機遙控說明.txt' })
    foreach ($f in $cmdFiles) {
        if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt 10) { continue }  # 等雲端同步完成
        # 檔名去副檔名、去 OneDrive 衝突後綴「 (1)」、去空白
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $base = ($base -replace '\s*\(\d+\)\s*$', '').Trim()
        $cmd  = $remoteCommands[$base]
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        if (-not $cmd) {
            Write-CmdResult -CmdName $base -Title "無法辨識的指令：$base" `
                -Log @("可用指令：保養／健檢／深度預覽／深度清理", "請把檔名改成上面其中一個。")
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $processed "$stamp-$($f.Name)") -Force
            Write-Host "[遙控] 無法辨識的指令檔：$($f.Name)" -ForegroundColor Yellow
            continue
        }
        Write-Host "[遙控] 收到手機指令：$base → $cmd" -ForegroundColor Cyan
        $log = @()
        switch ($cmd) {
            'tune' {
                $log = @(& $tuneScript *>&1 | ForEach-Object { $_.ToString() })
                Write-CmdResult -CmdName $base -Title '一鍵保養（零風險清理）' -Log $log
            }
            'scan' {
                $log = @(& $scanScript -NoHtml *>&1 | ForEach-Object { $_.ToString() })
                Write-CmdResult -CmdName $base -Title '系統健檢掃描' -Log $log
            }
            'preview' {
                $log  = @(& $scanScript -NoHtml *>&1 | ForEach-Object { $_.ToString() })
                $log += @(& $planScript *>&1 | ForEach-Object { $_.ToString() })
                $log += '------ 乾跑預覽（不會真的動）------'
                $log += @(& $cleanScript *>&1 | ForEach-Object { $_.ToString() })
                Write-CmdResult -CmdName $base -Title '深度清理預覽（未執行）' -Log $log
            }
            'deep' {
                $log  = @(& $scanScript -NoHtml *>&1 | ForEach-Object { $_.ToString() })
                $log += @(& $planScript *>&1 | ForEach-Object { $_.ToString() })
                $log += '------ 實際執行（可還原）------'
                $log += @(& $cleanScript -Apply *>&1 | ForEach-Object { $_.ToString() })
                Write-CmdResult -CmdName $base -Title '深度清理（已執行，可還原）' -Log $log
            }
        }
        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $processed "$stamp-$($f.Name)") -Force
        Write-Host "[遙控] 完成：$base（結果已寫到 outbox）" -ForegroundColor Green
    }
}

function Invoke-BridgeOnce {
    Invoke-CommandFiles   # 先處理手機遙控指令檔

    $files = @(Get-ChildItem -Path $inbox -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Host "[橋接] inbox 沒有新的 JSON 計畫（$inbox）" -ForegroundColor DarkGray; return }

    foreach ($f in $files) {
        # 雲端同步可能還沒傳完，剛寫入 10 秒內的檔先跳過、下一輪再處理
        if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt 10) {
            Write-Host "[橋接] $($f.Name) 剛寫入，等同步完成後再處理" -ForegroundColor Yellow
            continue
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Write-Host "[橋接] 處理計畫：$($f.Name)" -ForegroundColor Cyan

        $planObj = $null
        try { $planObj = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if (-not $planObj -or -not $planObj.actions) {
            Write-BridgeResult -PlanName $f.Name -Status 'invalid' `
                -Message 'JSON 解析失敗或缺少 actions 欄位，格式見 plan.sample.json' -Log @()
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $processed "$stamp-$($f.Name)") -Force
            Write-Host "[橋接] 格式不合法，已退回結果說明" -ForegroundColor Red
            continue
        }

        $types      = @($planObj.actions | ForEach-Object { [string]$_.type })
        $deepTypes  = @($types | Where-Object { $safeAutoTypes -notcontains $_ } | Sort-Object -Unique)
        $isApproved = $f.Name -like '*.approved.json'

        if ($deepTypes.Count -gt 0 -and -not $isApproved) {
            # 含深度動作且尚未核准：乾跑產生預覽，移到 pending 等使用者
            $log = @(& $cleanScript -Plan $f.FullName *>&1 | ForEach-Object { $_.ToString() })
            $approveName = ($f.Name -replace '\.json$', '') + '.approved.json'
            Write-BridgeResult -PlanName $f.Name -Status 'pending_approval' `
                -Message ("計畫含深度動作（{0}），已乾跑預覽（見 log）。使用者核准方式：把 pending\{1} 改名為 {2} 後移回 inbox。" -f ($deepTypes -join ', '), $f.Name, $approveName) `
                -Log $log
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $pending $f.Name) -Force
            Write-Host "[橋接] 含深度動作（$($deepTypes -join ', ')），已移到 pending 等使用者核准" -ForegroundColor Yellow
            continue
        }

        # 零風險（或已核准）：實際執行；白名單／路徑／備份由 clean.ps1 強制把關
        $log = @(& $cleanScript -Plan $f.FullName -Apply *>&1 | ForEach-Object { $_.ToString() })
        $status = if (($log -join "`n") -match '失敗|致命錯誤') { 'done_with_errors' } else { 'done' }
        $msg = if ($isApproved) { '已依使用者核准執行（詳見 log；可還原動作的備份檔路徑在 log 內）' }
               else { '零風險動作已自動執行（詳見 log）' }
        Write-BridgeResult -PlanName $f.Name -Status $status -Message $msg -Log $log
        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $processed "$stamp-$($f.Name)") -Force
        Write-Host "[橋接] 執行完成：$($f.Name)（結果已寫到 outbox）" -ForegroundColor Green
    }
}

# ---------- 主流程 ----------
Write-Host "=============== sysclean 代理橋接器 ===============" -ForegroundColor Cyan
Write-Host "交件資料夾：$inbox" -ForegroundColor DarkGray
Write-Host "（把這個 bridge 資料夾放進 OneDrive/Google Drive 同步，遠端 AI 就能交件）" -ForegroundColor DarkGray

if ($Watch) {
    Write-Host "常駐看守中，每 $IntervalSeconds 秒檢查一次（Ctrl+C 結束）…" -ForegroundColor Cyan
    while ($true) {
        Invoke-BridgeOnce
        Start-Sleep -Seconds $IntervalSeconds
    }
} else {
    Invoke-BridgeOnce
}
