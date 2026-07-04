#Requires -Version 5.1
<#
sysclean/scan.ps1 — 個人電腦系統健檢掃描器（唯讀，絕不更動系統）

掃描項目：
  1. 記憶體／CPU／磁碟總覽（含即時 CPU 取樣，找出發熱元兇）
  2. 吃記憶體、吃 CPU 的前 N 名程序（同名程序合併統計，例如 chrome 全家桶）
  3. 開機自啟項（登錄檔 Run、啟動資料夾，含已停用狀態）
  4. 非 Microsoft 排程任務
  5. 自動啟動的服務（標記第三方）
  6. 藏在各處的垃圾檔案：暫存、Windows Update 快取、瀏覽器快取、
     當機傾印、資源回收筒、Windows.old
  7. 已安裝軟體依大小排序（找出暫時用不到的大型軟體）

輸出：
  reports\scan-<時間>.json + reports\latest.json  （給 AI Agent 分析）
  reports\latest.html                              （給人看的報告）

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\scan.ps1 -OpenReport
  參數：-TopN 15  -CpuSampleSeconds 3  -DeepDisk（加掃使用者大檔案，較慢）
#>
[CmdletBinding()]
param(
    [int]$TopN = 15,
    [int]$CpuSampleSeconds = 3,
    [switch]$DeepDisk,
    [switch]$NoHtml,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$reportsDir = Join-Path $scriptDir 'reports'
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }

$config = @{ knownHogs = @{} }
$configPath = Join-Path $scriptDir 'config.json'
if (Test-Path $configPath) {
    try { $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        Write-Host "[警告] config.json 讀取失敗：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { $sum = 0 }
        return [math]::Round($sum / 1MB, 1)
    } catch { return $null }
}

Write-Host '=============== 個人電腦系統健檢掃描器 ===============' -ForegroundColor Cyan
Write-Host '（唯讀掃描，不會更動任何系統設定或刪除任何檔案）' -ForegroundColor DarkGray

# ---------- 1. 系統總覽 ----------
Write-Host '[1/7] 系統總覽…' -ForegroundColor Green
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$uptime = (Get-Date) - $os.LastBootUpTime
$totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
$freeMB  = [math]::Round($os.FreePhysicalMemory / 1KB, 0)

$system = [ordered]@{
    computerName   = $cs.Name
    osName         = $os.Caption
    osVersion      = $os.Version
    uptimeHours    = [math]::Round($uptime.TotalHours, 1)
    uptimeNote     = if ($uptime.TotalDays -gt 7) { '已超過 7 天未重開機，建議重開一次釋放記憶體' } else { $null }
    memoryTotalMB  = $totalMB
    memoryUsedMB   = $totalMB - $freeMB
    memoryFreeMB   = $freeMB
    memoryUsedPct  = [math]::Round(($totalMB - $freeMB) / $totalMB * 100, 1)
}

$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $freePct = if ($_.Size -gt 0) { [math]::Round($_.FreeSpace / $_.Size * 100, 1) } else { 0 }
    [ordered]@{
        drive      = $_.DeviceID
        totalGB    = [math]::Round($_.Size / 1GB, 1)
        freeGB     = [math]::Round($_.FreeSpace / 1GB, 1)
        freePct    = $freePct
        warning    = if ($freePct -lt 15) { '剩餘空間低於 15%，會拖慢系統與增加 SSD 損耗' } else { $null }
    }
})

# ---------- 2. CPU 取樣 + 記憶體排行 ----------
Write-Host "[2/7] CPU 取樣 $CpuSampleSeconds 秒（找發熱元兇）…" -ForegroundColor Green
$cores = [Environment]::ProcessorCount
$snap1 = @{}
Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    try { $snap1[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds } catch { }
}
Start-Sleep -Seconds $CpuSampleSeconds

$procs = Get-Process -ErrorAction SilentlyContinue
$cpuRows = foreach ($p in $procs) {
    $cpuPct = $null
    try {
        if ($snap1.ContainsKey($p.Id)) {
            $deltaMs = $p.TotalProcessorTime.TotalMilliseconds - $snap1[$p.Id]
            $cpuPct  = [math]::Round($deltaMs / ($CpuSampleSeconds * 10 * $cores), 1)
        }
    } catch { }
    [pscustomobject]@{
        name     = $p.ProcessName
        pid      = $p.Id
        cpuPct   = $cpuPct
        memoryMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
    }
}

$topCpu = @($cpuRows | Where-Object { $_.cpuPct -gt 0 } |
    Sort-Object cpuPct -Descending | Select-Object -First $TopN)

# 同名程序合併（chrome / msedge 這類多程序軟體看總量才準）
$topMemGrouped = @($cpuRows | Group-Object name | ForEach-Object {
    [pscustomobject]@{
        name      = $_.Name
        count     = $_.Count
        memoryMB  = [math]::Round(($_.Group | Measure-Object memoryMB -Sum).Sum, 1)
        cpuPct    = [math]::Round(($_.Group | Measure-Object cpuPct -Sum).Sum, 1)
    }
} | Sort-Object memoryMB -Descending | Select-Object -First $TopN)

$totalCpuPct = [math]::Round((($cpuRows | Measure-Object cpuPct -Sum).Sum), 1)
$system['cpuSampledPct'] = $totalCpuPct
$system['cpuCores'] = $cores

# ---------- 3. 開機自啟項 ----------
Write-Host '[3/7] 開機自啟項…' -ForegroundColor Green

# StartupApproved：Windows 記錄哪些自啟項已被「工作管理員」停用（首位元組偶數=啟用）
$approvedState = @{}
$approvedKeys = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
)
foreach ($k in $approvedKeys) {
    $item = Get-Item -Path $k -ErrorAction SilentlyContinue
    if ($item) {
        foreach ($vn in $item.GetValueNames()) {
            $bytes = $item.GetValue($vn)
            if ($bytes -is [byte[]] -and $bytes.Length -gt 0) {
                $approvedState[$vn] = if ($bytes[0] % 2 -eq 0) { 'enabled' } else { 'disabled' }
            }
        }
    }
}

$runKeys = @(
    @{ hive = 'HKLM'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' },
    @{ hive = 'HKLM'; path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' },
    @{ hive = 'HKCU'; path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
)
$startupItems = @()
foreach ($rk in $runKeys) {
    $props = Get-ItemProperty -Path $rk.path -ErrorAction SilentlyContinue
    if ($props) {
        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -match '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { continue }
            $state = if ($approvedState.ContainsKey($prop.Name)) { $approvedState[$prop.Name] } else { 'enabled' }
            $startupItems += [pscustomobject]@{
                source  = 'registry'
                hive    = $rk.hive
                key     = $rk.path
                name    = $prop.Name
                command = [string]$prop.Value
                state   = $state
            }
        }
    }
}
foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
    if ($folder -and (Test-Path $folder)) {
        Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | ForEach-Object {
            $state = if ($approvedState.ContainsKey($_.Name)) { $approvedState[$_.Name] } else { 'enabled' }
            $startupItems += [pscustomobject]@{
                source  = 'startupFolder'
                hive    = ''
                key     = $folder
                name    = $_.Name
                command = $_.FullName
                state   = $state
            }
        }
    }
}

# ---------- 4. 非 Microsoft 排程任務 ----------
Write-Host '[4/7] 排程任務…' -ForegroundColor Green
$tasks = @()
try {
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
            $info = $null
            try { $info = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue } catch { }
            $lastRun = $null
            if ($info -and $info.LastRunTime) { $lastRun = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') }
            $exec = $null
            try { $exec = ($_.Actions | Select-Object -First 1).Execute } catch { }
            [pscustomobject]@{
                taskPath    = $_.TaskPath
                taskName    = $_.TaskName
                state       = [string]$_.State
                lastRunTime = $lastRun
                action      = $exec
            }
        })
} catch { Write-Host "[警告] 排程任務讀取失敗：$($_.Exception.Message)" -ForegroundColor Yellow }

# ---------- 5. 自動啟動服務 ----------
Write-Host '[5/7] 自動啟動服務…' -ForegroundColor Green
$services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.StartMode -eq 'Auto' } | ForEach-Object {
        $path = [string]$_.PathName
        $thirdParty = ($path -and $path -notmatch '(?i)\\Windows\\(system32|SysWOW64|servicing)')
        [pscustomobject]@{
            name        = $_.Name
            displayName = $_.DisplayName
            state       = $_.State
            startMode   = $_.StartMode
            path        = $path
            thirdParty  = $thirdParty
        }
    })

# ---------- 6. 垃圾檔案掃描 ----------
Write-Host '[6/7] 垃圾檔案掃描（暫存／快取／傾印檔）…' -ForegroundColor Green
$junkTargets = @(
    @{ name = '使用者暫存 (%TEMP%)';            path = $env:TEMP;                                                          action = 'cleanTemp' },
    @{ name = '系統暫存 (Windows\Temp)';        path = "$env:SystemRoot\Temp";                                             action = 'cleanTemp' },
    @{ name = 'Windows Update 下載快取';        path = "$env:SystemRoot\SoftwareDistribution\Download";                    action = 'cleanTemp' },
    @{ name = 'Chrome 快取';                    path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache";          action = 'cleanTemp' },
    @{ name = 'Chrome Code Cache';              path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache";     action = 'cleanTemp' },
    @{ name = 'Edge 快取';                      path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache";         action = 'cleanTemp' },
    @{ name = 'Edge Code Cache';                path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache";    action = 'cleanTemp' },
    @{ name = '應用程式當機傾印 (CrashDumps)';  path = "$env:LOCALAPPDATA\CrashDumps";                                     action = 'cleanTemp' },
    @{ name = '系統當機小型傾印 (Minidump)';    path = "$env:SystemRoot\Minidump";                                         action = 'cleanTemp' },
    @{ name = 'DirectX 著色器快取';             path = "$env:LOCALAPPDATA\D3DSCache";                                      action = 'cleanTemp' },
    @{ name = 'NVIDIA 著色器快取';              path = "$env:LOCALAPPDATA\NVIDIA\DXCache";                                 action = 'cleanTemp' }
)
$junk = @()
foreach ($t in $junkTargets) {
    $size = Get-FolderSizeMB -Path $t.path
    if ($null -ne $size) {
        $junk += [pscustomobject]@{ name = $t.name; path = $t.path; sizeMB = $size; suggestedAction = $t.action }
    }
}

# 完整記憶體傾印檔（單一大檔）
$memDmp = "$env:SystemRoot\MEMORY.DMP"
if (Test-Path $memDmp) {
    $junk += [pscustomobject]@{
        name = '系統完整記憶體傾印 (MEMORY.DMP)'; path = $memDmp
        sizeMB = [math]::Round((Get-Item $memDmp -Force).Length / 1MB, 1); suggestedAction = 'manual'
    }
}
# Windows.old（要用「磁碟清理」刪，不能直接刪資料夾）
if (Test-Path "$env:SystemDrive\Windows.old") {
    $junk += [pscustomobject]@{
        name = '舊版 Windows (Windows.old)'; path = "$env:SystemDrive\Windows.old"
        sizeMB = Get-FolderSizeMB -Path "$env:SystemDrive\Windows.old"; suggestedAction = 'manual'
    }
}
# 資源回收筒
try {
    $shell = New-Object -ComObject Shell.Application
    $rbSize = 0
    foreach ($item in @($shell.Namespace(0xA).Items())) { $rbSize += [int64]$item.Size }
    $junk += [pscustomobject]@{
        name = '資源回收筒'; path = '(RecycleBin)'
        sizeMB = [math]::Round($rbSize / 1MB, 1); suggestedAction = 'emptyRecycleBin'
    }
} catch { }

$junkTotalMB = [math]::Round((($junk | Where-Object { $_.sizeMB } | Measure-Object sizeMB -Sum).Sum), 1)

# ---------- 7. 已安裝軟體（依大小） ----------
Write-Host '[7/7] 已安裝軟體清單…' -ForegroundColor Green
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installedApps = @(Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and -not $_.SystemComponent } | ForEach-Object {
        [pscustomobject]@{
            name        = $_.DisplayName
            version     = $_.DisplayVersion
            sizeMB      = if ($_.EstimatedSize) { [math]::Round($_.EstimatedSize / 1KB, 1) } else { $null }
            installDate = $_.InstallDate
            publisher   = $_.Publisher
        }
    } | Sort-Object { if ($_.sizeMB) { $_.sizeMB } else { 0 } } -Descending |
    Select-Object -First 40)

# ---------- 選配：大檔案深掃 ----------
$largeFiles = @()
if ($DeepDisk) {
    Write-Host '[選配] 使用者資料夾大檔案深掃（可能需要幾分鐘）…' -ForegroundColor Green
    $largeFiles = @(Get-ChildItem -Path $env:USERPROFILE -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 200MB } |
        Sort-Object Length -Descending | Select-Object -First 25 | ForEach-Object {
            [pscustomobject]@{
                path   = $_.FullName
                sizeMB = [math]::Round($_.Length / 1MB, 1)
                lastWrite = $_.LastWriteTime.ToString('yyyy-MM-dd')
            }
        })
}

# ---------- 建議產生（比對 knownHogs 知識庫） ----------
$hints = @()
$hogProps = @()
if ($config.knownHogs) { $hogProps = @($config.knownHogs.PSObject.Properties) }
$seen = @{}
function Add-Hint {
    param($target, $where, $hog)
    $key = "$target|$where"
    if ($script:seen.ContainsKey($key)) { return }
    $script:seen[$key] = $true
    $script:hints += [pscustomobject]@{
        target   = $target
        where    = $where
        category = $hog.Value.category
        note     = $hog.Value.note
        suggest  = $hog.Value.suggest
    }
}
foreach ($hog in $hogProps) {
    $pattern = [regex]::Escape($hog.Name)
    foreach ($p in $topMemGrouped) { if ($p.name -match "(?i)$pattern") { Add-Hint $p.name '執行中程序' $hog } }
    foreach ($s in $startupItems)  { if ("$($s.name) $($s.command)" -match "(?i)$pattern" -and $s.state -eq 'enabled') { Add-Hint $s.name '開機自啟' $hog } }
    foreach ($s in $services)      { if ("$($s.name) $($s.displayName)" -match "(?i)$pattern") { Add-Hint $s.name '自動服務' $hog } }
    foreach ($t in $tasks)         { if ("$($t.taskName) $($t.action)" -match "(?i)$pattern") { Add-Hint $t.taskName '排程任務' $hog } }
}

# ---------- 組裝輸出 ----------
$report = [ordered]@{
    generatedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    tool          = 'sysclean/scan.ps1'
    system        = $system
    disks         = $disks
    topCpu        = $topCpu
    topMemory     = $topMemGrouped
    startupItems  = $startupItems
    scheduledTasks = $tasks
    autoServices  = $services
    junk          = $junk
    junkTotalMB   = $junkTotalMB
    installedApps = $installedApps
    largeFiles    = $largeFiles
    hints         = $hints
}

$stamp    = Get-Date -Format 'yyyyMMdd-HHmm'
$jsonPath = Join-Path $reportsDir "scan-$stamp.json"
$json     = $report | ConvertTo-Json -Depth 8
$json | Out-File -FilePath $jsonPath -Encoding utf8
$json | Out-File -FilePath (Join-Path $reportsDir 'latest.json') -Encoding utf8

# ---------- HTML 報告 ----------
if (-not $NoHtml) {
    $template = Get-Content (Join-Path $scriptDir 'report-template.html') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($template) {
        $safeJson = $json -replace '</', '<\/'
        $html = $template.Replace('__SYSCLEAN_DATA__', $safeJson)
        $htmlPath = Join-Path $reportsDir 'latest.html'
        $html | Out-File -FilePath $htmlPath -Encoding utf8
        if ($OpenReport) { Start-Process $htmlPath }
    } else {
        Write-Host '[警告] 找不到 report-template.html，略過 HTML 報告' -ForegroundColor Yellow
    }
}

# ---------- 摘要 ----------
Write-Host ''
Write-Host '================ 掃描完成 ================' -ForegroundColor Cyan
Write-Host ("記憶體使用：{0}% （{1} / {2} MB）" -f $system.memoryUsedPct, $system.memoryUsedMB, $system.memoryTotalMB)
Write-Host ("CPU 取樣：{0}%（{1} 核心）" -f $totalCpuPct, $cores)
Write-Host ("可清理垃圾檔案合計：約 {0} MB" -f $junkTotalMB) -ForegroundColor Yellow
Write-Host ("開機自啟項：{0} 個（啟用中 {1} 個）" -f $startupItems.Count, @($startupItems | Where-Object { $_.state -eq 'enabled' }).Count)
Write-Host ("知識庫命中建議：{0} 筆" -f $hints.Count) -ForegroundColor Yellow
Write-Host ''
Write-Host "JSON 報告：$jsonPath"
Write-Host "HTML 報告：$(Join-Path $reportsDir 'latest.html')"
Write-Host ''
Write-Host '下一步：讓 AI Agent 讀 reports\latest.json 產生 plan.json，' -ForegroundColor DarkGray
Write-Host '再執行 clean.ps1 預覽（預設乾跑），確認後加 -Apply 才會真的動作。' -ForegroundColor DarkGray
