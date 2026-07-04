#Requires -Version 5.1
<#
sysclean/control-panel.ps1 — 本機網頁控制面板（給你一個網址，一鍵清潔）

啟動後打開 http://localhost:8377 ，網頁上有按鈕：
  一鍵保養／一鍵健檢／看報告／乾跑預覽 plan.json／核准執行／處理橋接收件匣

安全設計：
  ● 只綁 localhost —— 只有這台電腦自己開得到，區網／外網都連不進來
  ● 所有 POST 要求必須帶 X-Sysclean 自訂標頭 —— 惡意網站無法從背景偷按你的按鈕
    （瀏覽器跨來源會先發 CORS 預檢，本面板不回應預檢，直接擋下）
  ● 按鈕背後跑的還是同一套腳本，clean.ps1 的白名單／備份還原照常把關

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\control-panel.ps1
  參數：-Port 8377（改埠號）  -NoBrowser（不自動開瀏覽器）
  停止：網頁上按「關閉面板」，或在視窗按 Ctrl+C
#>
[CmdletBinding()]
param(
    [int]$Port = 8377,
    [switch]$NoBrowser,
    [switch]$RegisterStartup,
    [switch]$UnregisterStartup
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$reportsDir = Join-Path $scriptDir 'reports'
$startupTaskName = 'Sysclean-ControlPanel'

# ---------- 開機常駐註冊／移除 ----------
if ($UnregisterStartup) {
    if (Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $startupTaskName -Confirm:$false
        Write-Host "已移除面板常駐：$startupTaskName" -ForegroundColor Green
    } else { Write-Host "沒有找到面板常駐排程" -ForegroundColor Yellow }
    exit 0
}
if ($RegisterStartup) {
    try {
        if (Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $startupTaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -NoBrowser -Port $Port" `
            -WorkingDirectory $scriptDir
        $trigger  = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $startupTaskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'sysclean 一鍵清潔面板常駐（僅本機 localhost 可連）' | Out-Null
        Start-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue
        Write-Host "面板已設為開機常駐並立即在背景啟動：http://localhost:$Port" -ForegroundColor Green
        Write-Host '（在背景隱藏執行，沒有黑色視窗可以誤關；移除：-UnregisterStartup）' -ForegroundColor DarkGray
    } catch {
        Write-Host "常駐註冊失敗：$($_.Exception.Message)" -ForegroundColor Red
    }
    exit 0
}

# 面板按鈕 → 腳本對照表（只允許這幾個，網址亂打不會執行任何東西）
# 參數一律用「具名」hashtable splatting，避免被當成位置參數塞錯欄位
$runMap = @{
    'tune'   = @{ file = 'quick-tune.ps1';   args = @{};                          label = '一鍵保養（零風險）' }
    'tunerb' = @{ file = 'quick-tune.ps1';   args = @{ IncludeRecycleBin = $true }; label = '一鍵保養＋清回收筒' }
    'scan'   = @{ file = 'scan.ps1';         args = @{};                          label = '一鍵健檢（唯讀）' }
    'makeplan' = @{ file = 'make-plan.ps1';  args = @{};                          label = '依健檢報告產生清理計畫' }
    'dryrun' = @{ file = 'clean.ps1';        args = @{};                          label = '乾跑預覽 plan.json' }
    'apply'  = @{ file = 'clean.ps1';        args = @{ Apply = $true };           label = '核准執行 plan.json' }
    'bridge' = @{ file = 'agent-bridge.ps1'; args = @{ Once = $true };            label = '處理橋接收件匣一輪' }
}

$html = @'
<!DOCTYPE html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>我的電腦一鍵清潔面板</title>
<style>
  :root { --bg:#0f1420; --card:#182031; --line:#26324a; --tx:#dce6f5; --dim:#8fa3c0;
          --ok:#3fd68f; --warn:#ffc24d; --bad:#ff6b6b; --accent:#5aa9ff; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:var(--bg); color:var(--tx); font:15px/1.6 "Segoe UI","Microsoft JhengHei",sans-serif; padding:24px; max-width:900px; margin:auto; }
  h1 { font-size:22px; margin-bottom:4px; }
  .sub { color:var(--dim); font-size:13px; margin-bottom:20px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:12px; margin-bottom:16px; }
  button { background:var(--card); border:1px solid var(--line); color:var(--tx); border-radius:12px;
           padding:16px; font-size:16px; cursor:pointer; text-align:left; transition:.15s; font-family:inherit; }
  button:hover { border-color:var(--accent); transform:translateY(-1px); }
  button b { display:block; font-size:17px; margin-bottom:4px; }
  button small { color:var(--dim); }
  button.warn b { color:var(--warn); }  button.bad b { color:var(--bad); }
  button:disabled { opacity:.45; cursor:wait; }
  a.rep { color:var(--accent); }
  #status { font-size:13px; color:var(--warn); min-height:20px; margin-bottom:8px; }
  pre { background:#0a0e18; border:1px solid var(--line); border-radius:10px; padding:14px;
        font-size:12.5px; white-space:pre-wrap; word-break:break-all; max-height:420px; overflow:auto; color:#b9c8e0; }
  footer { color:var(--dim); font-size:12px; margin-top:12px; }
</style>
</head>
<body>
<h1>🧹 我的電腦一鍵清潔面板</h1>
<div class="sub">只有這台電腦自己開得到（localhost）。按鈕執行時請耐心等待，結果會顯示在下方。<br>
⚠️ 啟動面板的<b>黑色視窗要保持開著</b> —— 那就是面板的引擎，關掉視窗＝面板下線。</div>
<div class="grid">
  <button onclick="run('tune',this)"><b>🚿 一鍵保養</b><small>零風險：暫存＋全瀏覽器快取＋DNS</small></button>
  <button onclick="run('tunerb',this)"><b>🗑️ 保養＋清回收筒</b><small>同上，連資源回收筒一起清</small></button>
  <button onclick="run('scan',this)"><b>🔍 一鍵健檢</b><small>唯讀掃描，跑完可看報告</small></button>
  <button onclick="window.open('/report','_blank')"><b>📊 看最新報告</b><small>HTML 健檢報告（新分頁）</small></button>
  <button onclick="run('makeplan',this)"><b>🧠 產生清理計畫</b><small>依健檢報告自動列出可清項目（先健檢再按）</small></button>
  <button class="warn" onclick="run('dryrun',this)"><b>👀 乾跑預覽 plan.json</b><small>看深度清理計畫會做什麼（不執行）</small></button>
  <button class="warn" onclick="if(confirm('確定執行 plan.json 的深度清理？（可還原，備份路徑會顯示在結果）')) run('apply',this)"><b>✅ 核准執行 plan.json</b><small>執行深度清理（先產生計畫＋乾跑過再按）</small></button>
  <button onclick="run('bridge',this)"><b>🤖 處理橋接收件匣</b><small>立刻處理遠端 AI 交來的計畫一輪</small></button>
  <button class="bad" onclick="if(confirm('關閉面板？（網址會失效，要再開就重跑 control-panel.ps1）')) quit(this)"><b>⏻ 關閉面板</b><small>停止本機伺服器</small></button>
</div>
<div id="status"></div>
<pre id="log">結果會顯示在這裡…</pre>
<footer>sysclean control panel · 按鈕背後是同一套 scan / quick-tune / clean 腳本，白名單與備份還原照常把關。</footer>
<script>
const st = document.getElementById('status'), lg = document.getElementById('log');
async function run(key, btn) {
  btn.disabled = true; st.textContent = '⏳ 執行中，請稍候（掃描約需 1～3 分鐘）…'; lg.textContent = '';
  try {
    const r = await fetch('/run/' + key, { method:'POST', headers:{ 'X-Sysclean':'1' } });
    lg.textContent = await r.text();
    st.textContent = r.ok ? '✅ 完成' : '❌ 失敗（見下方訊息）';
  } catch (e) {
    st.textContent = '❌ 面板引擎已停止（啟動面板的黑色視窗被關掉了）';
    lg.textContent = '怎麼救：雙擊桌面「一鍵面板」重新啟動（黑色視窗保持開著），然後重新整理本頁再按一次。';
  }
  btn.disabled = false;
}
async function quit(btn) {
  btn.disabled = true;
  try { await fetch('/quit', { method:'POST', headers:{ 'X-Sysclean':'1' } }); } catch (e) { }
  st.textContent = '面板已關閉，此頁可以關掉了。';
}
</script>
</body>
</html>
'@

function Send-Bytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType, [int]$Code = 200)
    try {
        $Context.Response.StatusCode = $Code
        $Context.Response.ContentType = $ContentType
        $Context.Response.ContentLength64 = $Bytes.Length
        $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
        $Context.Response.OutputStream.Close()
    } catch { }
}
function Send-Text {
    param($Context, [string]$Body, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Code = 200)
    Send-Bytes -Context $Context -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Body)) -ContentType $ContentType -Code $Code
}

# ---------- 啟動 ----------
$prefix = "http://localhost:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
    # 埠被占用時先確認是不是面板本尊已在背景常駐 —— 是的話直接開網頁就好
    $alive = $false
    try { $alive = ((Invoke-WebRequest -Uri ($prefix + 'ping') -UseBasicParsing -TimeoutSec 3).Content -eq 'ok') } catch { }
    if ($alive) {
        Write-Host "面板已經在背景執行中，直接打開：$prefix" -ForegroundColor Green
        if (-not $NoBrowser) { Start-Process $prefix }
        exit 0
    }
    Write-Host "無法啟動（埠 $Port 被其他程式占用，換一個：-Port 8378）：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host '=============== 一鍵清潔面板已啟動 ===============' -ForegroundColor Cyan
Write-Host "你的網址：$prefix" -ForegroundColor Green
Write-Host '（只有這台電腦開得到；關閉請在網頁按「關閉面板」或按 Ctrl+C）' -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $prefix }

function Invoke-PanelRequest {
    param($Context)
    $path = $Context.Request.Url.AbsolutePath
    $method = $Context.Request.HttpMethod

    if ($method -eq 'GET' -and $path -eq '/') {
        Send-Text -Context $Context -Body $html -ContentType 'text/html; charset=utf-8'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/ping') {
        Send-Text -Context $Context -Body 'ok'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/report') {
        $rep = Join-Path $reportsDir 'latest.html'
        if (Test-Path $rep) {
            Send-Bytes -Context $Context -Bytes ([System.IO.File]::ReadAllBytes($rep)) -ContentType 'text/html; charset=utf-8'
        } else {
            Send-Text -Context $Context -Body '還沒有報告，先按「一鍵健檢」。' -Code 404
        }
        return
    }
    # 以下全是會執行動作的端點：必須是 POST + 自訂標頭（擋掉惡意網站背景偷按）
    if ($method -ne 'POST' -or $Context.Request.Headers['X-Sysclean'] -ne '1') {
        Send-Text -Context $Context -Body 'forbidden' -Code 403
        return
    }
    if ($path -eq '/quit') {
        Send-Text -Context $Context -Body '面板關閉中'
        $script:running = $false
        return
    }
    if ($path -match '^/run/([a-z]+)$' -and $runMap.ContainsKey($Matches[1])) {
        $spec = $runMap[$Matches[1]]
        Write-Host "[面板] 執行：$($spec.label)" -ForegroundColor Cyan
        $target = Join-Path $scriptDir $spec.file
        $log = @()
        try {
            $sargs = $spec.args
            $log = @(& $target @sargs *>&1 | ForEach-Object { $_.ToString() })
        } catch { $log += "執行錯誤：$($_.Exception.Message)" }
        Send-Text -Context $Context -Body ("=== {0} ===`n{1}" -f $spec.label, ($log -join "`n"))
        Write-Host "[面板] 完成：$($spec.label)" -ForegroundColor Green
        return
    }
    Send-Text -Context $Context -Body 'not found' -Code 404
}

$running = $true
while ($running -and $listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    # 單一請求出錯絕不讓整個面板掛掉
    try { Invoke-PanelRequest -Context $ctx }
    catch {
        Write-Host "[面板] 處理要求時發生錯誤：$($_.Exception.Message)" -ForegroundColor Red
        try { Send-Text -Context $ctx -Body "伺服器錯誤：$($_.Exception.Message)" -Code 500 } catch { }
    }
}

$listener.Stop()
$listener.Close()
Write-Host '面板已關閉。' -ForegroundColor Cyan
