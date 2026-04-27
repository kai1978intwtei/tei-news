#Requires -Version 5.1
<#
國際大事件 · 每日簡報
參數：
  -OpenBrowser  跑完自動打開瀏覽器（只在手動執行／登入觸發時需要；排程跑時不要）
#>
[CmdletBinding()]
param(
    [switch]$OpenBrowser
)

$ErrorActionPreference = 'Continue'

# ---------- 0. 背景排程跑時自動寫 log（最先做，確保 PS 有跑就有紀錄）----------
$Global:__TeiLogPath = Join-Path $env:TEMP 'tei_news_silent.log'
"[$(Get-Date -Format o)] PS START (PID=$PID, Cwd=$(Get-Location))" |
    Out-File $Global:__TeiLogPath -Encoding UTF8 -Append -ErrorAction SilentlyContinue

# Console 編碼（在無 console 環境會拋例外，要包 try）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 啟動 transcript（捕捉所有 Write-Host 輸出）
try {
    Start-Transcript -Path $Global:__TeiLogPath -Append -Force -ErrorAction Stop | Out-Null
} catch {
    "[$(Get-Date -Format o)] Start-Transcript failed: $($_.Exception.Message)" |
        Out-File $Global:__TeiLogPath -Encoding UTF8 -Append -ErrorAction SilentlyContinue
}

"[$(Get-Date -Format o)] ScriptRoot=$PSScriptRoot, OpenBrowser=$OpenBrowser" |
    Out-File $Global:__TeiLogPath -Encoding UTF8 -Append -ErrorAction SilentlyContinue

# ---------- 1. 自動設定登入時啟動 ----------
function Install-StartupShortcut {
    try {
        $startup  = [Environment]::GetFolderPath('Startup')
        $shortcut = Join-Path $startup '國際大事件.lnk'
        if (Test-Path $shortcut) { return }
        if (-not $PSCommandPath) { return }

        $wsh = New-Object -ComObject WScript.Shell
        $sc  = $wsh.CreateShortcut($shortcut)
        $sc.TargetPath       = (Get-Command powershell.exe).Source
        # 登入時跑一次並開啟瀏覽器
        $sc.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -OpenBrowser"
        $sc.WorkingDirectory = Split-Path $PSCommandPath
        $sc.IconLocation     = 'imageres.dll,109'
        $sc.Save()
        Write-Host '[setup] 已在「啟動」資料夾建立捷徑，下次登入自動執行' -ForegroundColor Green
    } catch {
        Write-Host "[setup] 捷徑建立失敗：$_" -ForegroundColor Yellow
    }
}

function Install-DailyTask {
    try {
        $taskName = 'TEi-國際新聞-每日更新'
        # 每次都重新註冊，確保時間／參數變更生效
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        if (-not $PSCommandPath) { return }

        # 排程跑背景不打開瀏覽器（用戶的分頁會自動 refresh）
        # 直接 powershell 啟動，加 -WindowStyle Hidden 隱藏視窗
        # （會閃過很短的視窗，但確保 script 100% 跑得起來，比 VBS 包裝可靠）
        $action = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -WorkingDirectory (Split-Path $PSCommandPath)

        # 立即開始，每 10 分鐘執行一次（每天循環 24 小時不間斷）
        $startAt = (Get-Date).AddMinutes(2)  # 2 分鐘後開始第一次
        $trigger = New-ScheduledTaskTrigger -Daily -At $startAt
        $repTrig = New-ScheduledTaskTrigger -Once -At $startAt `
                       -RepetitionInterval (New-TimeSpan -Minutes 10) `
                       -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 50)
        $trigger.Repetition = $repTrig.Repetition

        $settings = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -RunOnlyIfNetworkAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 8) `
            -MultipleInstances IgnoreNew `
            -Hidden

        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal | Out-Null

        Write-Host "[setup] 已設定每 10 分鐘自動更新（首次 $($startAt.ToString('HH:mm'))，24 小時不間斷）" -ForegroundColor Green
    } catch {
        Write-Host "[setup] 排程建立失敗（可能需要先手動執行一次）: $_" -ForegroundColor Yellow
    }
}

# ---------- 2. RSS 來源 ----------
$Sources = @(
    @{ Name='BBC World';      Url='http://feeds.bbci.co.uk/news/world/rss.xml';                                                  Lang='en'; Weight=1.2 }
    @{ Name='BBC Business';   Url='http://feeds.bbci.co.uk/news/business/rss.xml';                                               Lang='en'; Weight=1.2 }
    @{ Name='BBC 中文';       Url='https://feeds.bbci.co.uk/zhongwen/trad/rss.xml';                                              Lang='zh'; Weight=1.2 }
    @{ Name='Al Jazeera';     Url='https://www.aljazeera.com/xml/rss/all.xml';                                                   Lang='en'; Weight=1.0 }
    @{ Name='Deutsche Welle'; Url='https://rss.dw.com/rdf/rss-en-all';                                                           Lang='en'; Weight=1.0 }
    # NYT 已移除：付費牆常擋同仁，改用 NPR／CNN 替代
    @{ Name='NPR World';      Url='https://feeds.npr.org/1004/rss.xml';                                                          Lang='en'; Weight=1.1 }
    @{ Name='NPR Business';   Url='https://feeds.npr.org/1006/rss.xml';                                                          Lang='en'; Weight=1.1 }
    @{ Name='AP News';        Url='https://news.google.com/rss/search?q=when:1d+site:apnews.com&hl=en-US&gl=US&ceid=US:en';        Lang='en'; Weight=1.0 }
    @{ Name='Guardian World'; Url='https://www.theguardian.com/world/rss';                                                       Lang='en'; Weight=1.0 }
    @{ Name='France 24';      Url='https://www.france24.com/en/rss';                                                             Lang='en'; Weight=0.9 }
    @{ Name='Reuters';        Url='https://news.google.com/rss/search?q=when:1d+site:reuters.com&hl=en-US&gl=US&ceid=US:en';     Lang='en'; Weight=1.1 }
    @{ Name='RFI 中文';       Url='https://www.rfi.fr/tw/rss';                                                                   Lang='zh'; Weight=0.9 }
    # ----- 科技／未來材料 -----
    @{ Name='TechCrunch';     Url='https://techcrunch.com/feed/';                                                                 Lang='en'; Weight=1.1 }
    @{ Name='The Verge';      Url='https://www.theverge.com/rss/index.xml';                                                       Lang='en'; Weight=1.0 }
    @{ Name='Wired';          Url='https://www.wired.com/feed/rss';                                                               Lang='en'; Weight=1.0 }
    @{ Name='IEEE Spectrum';  Url='https://spectrum.ieee.org/feeds/feed.rss';                                                     Lang='en'; Weight=1.0 }
)

# ---------- 3. 關鍵字評分 ----------
$Keywords = @{
    # 地緣政治（權重略降，避免戰爭新聞壟斷）
    'ukraine'=5; 'russia'=5; 'putin'=4; 'zelensky'=3
    'china'=5;   'xi jinping'=4; 'taiwan'=5; 'beijing'=3
    'israel'=4;  'gaza'=4; 'hamas'=3; 'iran'=4; 'lebanon'=3; 'hezbollah'=3
    'north korea'=4; 'kim jong'=3
    # 經濟（提高）
    'tariff'=6; 'trade war'=6; 'sanction'=5; 'sanctions'=5; 'inflation'=5; 'recession'=5
    'central bank'=5; 'federal reserve'=5; 'rate cut'=5; 'rate hike'=5; 'ecb'=4; 'imf'=4
    'oil price'=4; 'opec'=4; 'yuan'=3; 'dollar'=3
    'earnings'=4; 'ipo'=4; 'merger'=4; 'acquisition'=4; 'startup'=3; 'funding'=3; 'stock market'=4
    # 政治外交
    'election'=4; 'summit'=5; 'g7'=4; 'g20'=4; 'nato'=4; 'un security'=3
    'treaty'=3; 'ceasefire'=4; 'invasion'=4; 'referendum'=3
    # 衝突（權重降低，避免戰爭新聞壟斷）
    'war'=3; 'missile'=2; 'strike'=2; 'nuclear'=4; 'airstrike'=2; 'troops'=2
    # 科技／AI
    'ai'=5; 'artificial intelligence'=6; 'chatgpt'=4; 'openai'=5; 'anthropic'=5; 'llm'=4
    'semiconductor'=6; 'tsmc'=6; 'chip'=5; 'asml'=5; 'nvidia'=6; 'intel'=4; 'amd'=4
    # 無人機／自駕／太空
    'drone'=6; 'drones'=6; 'uav'=5; 'autonomous'=5; 'self-driving'=4
    'spacex'=5; 'satellite'=4; 'starlink'=4; 'rocket'=4; 'evtol'=5; 'air taxi'=5
    # 電動車／電池
    'electric vehicle'=5; 'tesla'=4; 'byd'=4; 'battery'=5; 'lithium'=4; 'solid-state'=5
    # 機器人／量子
    'robotics'=5; 'robot'=4; 'automation'=3; 'quantum'=5; 'quantum computing'=6
    # 未來材料
    'graphene'=6; 'nanotech'=5; 'nanomaterial'=5; 'hydrogen'=5; 'fuel cell'=5
    'composite'=5; 'cfrp'=6; 'lightweight material'=5; '3d printing'=5; 'additive manufacturing'=5
    'hypersonic'=5; 'biotech'=4; 'gene editing'=4
    'renewable energy'=4; 'solar'=3; 'wind power'=3; 'carbon capture'=4
    # 中文：政治／經濟
    '烏克蘭'=5; '俄羅斯'=5; '普京'=4; '普丁'=4; '澤倫斯基'=3
    '中國'=5;   '習近平'=4; '台灣'=5; '北京'=3
    '以色列'=4; '加薩'=4; '哈瑪斯'=3; '伊朗'=4; '黎巴嫩'=3
    '北韓'=4;   '金正恩'=3
    '關稅'=6;   '貿易戰'=6; '制裁'=5; '通膨'=5; '衰退'=5
    '央行'=5;   '聯準會'=5; '升息'=5; '降息'=5; '油價'=4
    '選舉'=4;   '峰會'=5; '外交'=3; '停火'=4; '入侵'=4
    '核武'=4;   '戰爭'=3; '飛彈'=2; '空襲'=2
    # 中文：科技／無人機／未來材料
    '人工智慧'=6; '半導體'=6; '台積電'=6; '晶片'=5; '輝達'=5
    '無人機'=6; '無人載具'=5; '自動駕駛'=5
    '電動車'=5; '特斯拉'=4; '電池'=5; '固態電池'=6; '鋰'=4
    '太空'=4; '衛星'=4; '火箭'=4
    '機器人'=5; '量子'=5; '量子電腦'=6
    '石墨烯'=6; '奈米'=5; '氫能'=5; '燃料電池'=5
    '複合材料'=6; '碳纖維'=6; '3D列印'=5; '先進材料'=6; '新材料'=6
    '生物科技'=4; '基因'=4; '再生能源'=4; '太陽能'=3; '風能'=3
}

# ---------- 2b. 碳纖維產業新聞來源 ----------
# 優先用直接 RSS（真實 URL 可抓文）；Google News 做補充
$CarbonSources = @(
    # 直接 RSS：真實 URL，Get-ArticleText 可抓到完整內容
    @{ Name='CompositesWorld'; Url='https://www.compositesworld.com/rss/news';   Lang='en'; Weight=1.3 }
    @{ Name='JEC Composites';  Url='https://www.jeccomposites.com/feed/';        Lang='en'; Weight=1.3 }
    # Google News 補充：URL 加密無法抓文，只用 RSS 描述
    @{ Name='碳纖維產業';       Url='https://news.google.com/rss/search?q=%22carbon+fiber%22+(industry+OR+manufacturer+OR+market+OR+production+OR+plant)+-amazon+-ebay+-walmart+-aliexpress&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=0.9 }
    @{ Name='國際品牌';         Url='https://news.google.com/rss/search?q=(Toray+OR+Hexcel+OR+Teijin+OR+SGL+OR+%22Mitsubishi+Chemical%22)+(carbon+OR+composite+OR+fiber)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=0.9 }
    @{ Name='碳纖維(繁中)';     Url='https://news.google.com/rss/search?q=%E7%A2%B3%E7%BA%96%E7%B6%AD+(%E7%94%A2%E6%A5%AD+OR+%E5%B8%82%E5%A0%B4+OR+%E5%85%AC%E5%8F%B8+OR+%E7%94%A2%E8%83%BD+OR+%E5%B7%A5%E5%BB%A0)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.0 }
)

# ---------- 2b2. 碳纖製造商官方新聞 ----------
$ManufacturerSources = @(
    # ---- 日本 ----
    @{ Name='Toray';              Url='https://news.google.com/rss/search?q=Toray+(carbon+fiber+OR+carbon+composite+OR+Torayca)&hl=en-US&gl=US&ceid=US:en';                            Lang='en'; Weight=1.2 }
    @{ Name='ZOLTEK';             Url='https://news.google.com/rss/search?q=ZOLTEK+(carbon+fiber+OR+composite)&hl=en-US&gl=US&ceid=US:en';                                             Lang='en'; Weight=1.1 }
    @{ Name='Teijin / TOHO Tenax';Url='https://news.google.com/rss/search?q=(Teijin+OR+%22TOHO+Tenax%22+OR+%22Teijin+Carbon%22)+(carbon+fiber+OR+Tenax+OR+Sereebo+OR+composite)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='Mitsubishi Chemical';Url='https://news.google.com/rss/search?q=%22Mitsubishi+Chemical%22+(carbon+fiber+OR+Grafil+OR+DIALEAD+OR+Pyrofil)&hl=en-US&gl=US&ceid=US:en';      Lang='en'; Weight=1.2 }
    @{ Name='Nippon Graphite';    Url='https://news.google.com/rss/search?q=(%22Nippon+Graphite+Fiber%22+OR+%22Nippon+Graphite%22+NGF)+carbon&hl=en-US&gl=US&ceid=US:en';              Lang='en'; Weight=1.0 }
    @{ Name='Kureha';             Url='https://news.google.com/rss/search?q=Kureha+(carbon+fiber+OR+%22KF+carbon%22)&hl=en-US&gl=US&ceid=US:en';                                       Lang='en'; Weight=0.9 }
    # ---- 美國／歐洲 ----
    @{ Name='Hexcel';             Url='https://news.google.com/rss/search?q=Hexcel+(carbon+OR+composite+OR+HexTow+OR+HexPly+OR+prepreg)&hl=en-US&gl=US&ceid=US:en';                  Lang='en'; Weight=1.2 }
    @{ Name='SGL Carbon';         Url='https://news.google.com/rss/search?q=%22SGL+Carbon%22+(carbon+fiber+OR+composite+OR+SIGRAFIL)&hl=en-US&gl=US&ceid=US:en';                     Lang='en'; Weight=1.1 }
    @{ Name='Solvay / Syensqo';   Url='https://news.google.com/rss/search?q=(Solvay+OR+Syensqo)+(carbon+OR+composite+OR+prepreg+OR+thermoset)&hl=en-US&gl=US&ceid=US:en';            Lang='en'; Weight=1.1 }
    @{ Name='Cytec / Syensqo';    Url='https://news.google.com/rss/search?q=(Cytec+OR+%22Cytec+Solvay%22)+(carbon+OR+composite)&hl=en-US&gl=US&ceid=US:en';                            Lang='en'; Weight=0.9 }
    @{ Name='DowAksa / Aksa';     Url='https://news.google.com/rss/search?q=(DowAksa+OR+%22Aksa+Akrilik%22)+(carbon+fiber+OR+composite)&hl=en-US&gl=US&ceid=US:en';                    Lang='en'; Weight=1.0 }
    @{ Name='Eurocarbon';         Url='https://news.google.com/rss/search?q=Eurocarbon+(fiber+OR+composite+OR+carbon)&hl=en-US&gl=US&ceid=US:en';                                       Lang='en'; Weight=0.9 }
    # ---- 台灣／韓國 ----
    @{ Name='Formosa / TAIRYFIL'; Url='https://news.google.com/rss/search?q=(%22Formosa+Plastics%22+OR+TAIRYFIL+OR+%E5%8F%B0%E5%A1%91)+(carbon+fiber+OR+composite+OR+%E7%A2%B3%E7%BA%96%E7%B6%AD)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.1 }
    @{ Name='Hyosung Advanced';   Url='https://news.google.com/rss/search?q=(Hyosung+OR+%22Hyosung+Advanced+Materials%22)+(carbon+fiber+OR+TANSOME+OR+TANFOCUS)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    # ---- 中國大陸業者 ----
    @{ Name='中復神鷹';            Url='https://news.google.com/rss/search?q=(%22Zhongfu+Shenying%22+OR+%E4%B8%AD%E5%BE%A9%E7%A5%9E%E9%B7%B9)+carbon&hl=en-US&gl=US&ceid=US:en';        Lang='en'; Weight=1.0 }
    @{ Name='吉林化纖';            Url='https://news.google.com/rss/search?q=(%22Jilin+Chemical+Fiber%22+OR+%22Jilin+Carbon%22+OR+%E5%90%89%E6%9E%97%E5%8C%96%E7%BA%96)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='光威復材';            Url='https://news.google.com/rss/search?q=(%22Weihai+Guangwei%22+OR+%22Guangwei+Composites%22+OR+%E5%85%89%E5%A8%81%E5%A4%8D%E6%9D%90)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Sinofibers';         Url='https://news.google.com/rss/search?q=Sinofibers+(carbon+fiber+OR+composite)&hl=en-US&gl=US&ceid=US:en';                                         Lang='en'; Weight=0.9 }
    @{ Name='康得複材';            Url='https://news.google.com/rss/search?q=(%22Kangde+Composite%22+OR+Kangde+carbon+OR+%E5%BA%B7%E5%BE%97%E8%A4%87%E6%9D%90)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=0.9 }
    @{ Name='精功科技';            Url='https://news.google.com/rss/search?q=(%22Jingong%22+OR+%E7%B2%BE%E5%8A%9F%E7%A7%91%E6%8A%80)+carbon+fiber&hl=zh-TW&gl=TW&ceid=TW:zh-TW';       Lang='zh'; Weight=0.9 }
)

# ---------- 2b3b. 塑膠大廠新聞 ----------
$PlasticSources = @(
    # 美／歐 大廠
    @{ Name='Dow Chemical';        Url='https://news.google.com/rss/search?q=(%22Dow+Chemical%22+OR+%22Dow+Inc%22)+(plastic+OR+polymer+OR+resin+OR+polyethylene)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='LyondellBasell';      Url='https://news.google.com/rss/search?q=LyondellBasell+(plastic+OR+polymer+OR+polyolefin+OR+polypropylene+OR+HDPE)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='BASF';                Url='https://news.google.com/rss/search?q=BASF+(plastic+OR+polymer+OR+polyurethane+OR+polyamide+OR+engineering+plastic)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='SABIC';               Url='https://news.google.com/rss/search?q=SABIC+(plastic+OR+polymer+OR+polyethylene+OR+polypropylene+OR+polycarbonate+OR+Noryl)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='Covestro';            Url='https://news.google.com/rss/search?q=Covestro+(plastic+OR+polymer+OR+polycarbonate+OR+Makrolon+OR+polyurethane)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='ExxonMobil Chemical'; Url='https://news.google.com/rss/search?q=%22ExxonMobil+Chemical%22+(plastic+OR+polymer+OR+polyethylene+OR+polypropylene)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='INEOS';               Url='https://news.google.com/rss/search?q=INEOS+(plastic+OR+polymer+OR+polyethylene+OR+polypropylene+OR+styrene+OR+ABS)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Chevron Phillips';    Url='https://news.google.com/rss/search?q=%22Chevron+Phillips%22+(plastic+OR+polymer+OR+polyethylene+OR+HDPE)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 歐洲特化 / 工程塑膠
    @{ Name='Arkema';              Url='https://news.google.com/rss/search?q=Arkema+(plastic+OR+polymer+OR+polyamide+OR+PVDF+OR+Rilsan)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Evonik';              Url='https://news.google.com/rss/search?q=Evonik+(plastic+OR+polymer+OR+PEEK+OR+polyamide+OR+VESTAMID)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Lanxess';             Url='https://news.google.com/rss/search?q=Lanxess+(plastic+OR+polymer+OR+polyamide+OR+Durethan+OR+Pocan)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='DSM / Envalior';      Url='https://news.google.com/rss/search?q=(%22Royal+DSM%22+OR+Envalior+OR+%22DSM+Engineering%22)+(plastic+OR+polymer+OR+engineering)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Celanese';            Url='https://news.google.com/rss/search?q=Celanese+(plastic+OR+polymer+OR+POM+OR+acetal+OR+engineering)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Eastman Chemical';    Url='https://news.google.com/rss/search?q=%22Eastman+Chemical%22+(plastic+OR+polymer+OR+copolyester+OR+Tritan)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Victrex';             Url='https://news.google.com/rss/search?q=Victrex+(PEEK+OR+polymer+OR+high-performance+plastic)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 日本
    @{ Name='Mitsui Chemicals';    Url='https://news.google.com/rss/search?q=%22Mitsui+Chemicals%22+(plastic+OR+polymer+OR+resin+OR+polyolefin)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Mitsubishi Chem 塑膠';Url='https://news.google.com/rss/search?q=%22Mitsubishi+Chemical%22+(engineering+plastic+OR+polycarbonate+OR+PBT+OR+ABS)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Sumitomo Chemical';   Url='https://news.google.com/rss/search?q=%22Sumitomo+Chemical%22+(plastic+OR+polymer+OR+resin+OR+polypropylene)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Asahi Kasei';         Url='https://news.google.com/rss/search?q=%22Asahi+Kasei%22+(plastic+OR+polymer+OR+resin+OR+Leona+OR+Xyron)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 南韓
    @{ Name='LG Chem';             Url='https://news.google.com/rss/search?q=%22LG+Chem%22+(plastic+OR+polymer+OR+ABS+OR+PC+OR+resin)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Hanwha Solutions';    Url='https://news.google.com/rss/search?q=%22Hanwha+Solutions%22+(plastic+OR+polymer+OR+PVC+OR+resin)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 台灣
    @{ Name='台塑 / 南亞塑膠';     Url='https://news.google.com/rss/search?q=(%E5%8F%B0%E5%A1%91+OR+%E5%8D%97%E4%BA%9E%E5%A1%91%E8%86%A0+OR+%22Formosa+Plastics%22+OR+%22Nan+Ya+Plastics%22)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.1 }
    # 巴西
    @{ Name='Braskem';             Url='https://news.google.com/rss/search?q=Braskem+(plastic+OR+polymer+OR+polyethylene+OR+polypropylene+OR+bio-based)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 直接 RSS — 塑膠產業雜誌
    @{ Name='Plastics Today';      Url='https://www.plasticstoday.com/rss.xml';                                                                                                         Lang='en'; Weight=1.2 }
)

# ---------- 2b3c. 世界金屬市場（鋼／鋁／銅／鋰／稀土／關鍵礦物）----------
$MetalSources = @(
    # 鋼鐵大廠
    @{ Name='ArcelorMittal';       Url='https://news.google.com/rss/search?q=ArcelorMittal+(steel+OR+production+OR+market+OR+green+steel)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='Nippon Steel';        Url='https://news.google.com/rss/search?q=%22Nippon+Steel%22+(steel+OR+production+OR+%22US+Steel%22+OR+Pittsburgh)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='POSCO';               Url='https://news.google.com/rss/search?q=POSCO+(steel+OR+hot-rolled+OR+production+OR+market+OR+battery)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Thyssenkrupp';        Url='https://news.google.com/rss/search?q=Thyssenkrupp+(steel+OR+production+OR+green+OR+decarbon)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Baowu / China Steel'; Url='https://news.google.com/rss/search?q=(Baowu+OR+%22China+Baowu%22+OR+%22China+Steel+Corp%22+OR+Shougang)+steel&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='JFE / Kobe';          Url='https://news.google.com/rss/search?q=(%22JFE+Steel%22+OR+%22Kobe+Steel%22+OR+%22Kobelco%22)+(steel+OR+production)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 鋁業
    @{ Name='Alcoa';               Url='https://news.google.com/rss/search?q=Alcoa+(aluminum+OR+smelter+OR+production+OR+market)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='Novelis';             Url='https://news.google.com/rss/search?q=Novelis+(aluminum+OR+recycled+OR+rolling+OR+sheet)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Norsk Hydro';         Url='https://news.google.com/rss/search?q=%22Norsk+Hydro%22+(aluminum+OR+smelter+OR+green)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='China Hongqiao';      Url='https://news.google.com/rss/search?q=(%22China+Hongqiao%22+OR+Hongqiao+aluminum)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 多金屬綜合礦業巨頭
    @{ Name='Rio Tinto';           Url='https://news.google.com/rss/search?q=%22Rio+Tinto%22+(iron+ore+OR+copper+OR+aluminum+OR+lithium+OR+mine+OR+production)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='BHP';                 Url='https://news.google.com/rss/search?q=BHP+(iron+ore+OR+copper+OR+nickel+OR+coal+OR+mine+OR+production)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='Glencore';            Url='https://news.google.com/rss/search?q=Glencore+(copper+OR+zinc+OR+cobalt+OR+nickel+OR+coal+OR+mine)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Vale';                Url='https://news.google.com/rss/search?q=%22Vale+SA%22+(iron+ore+OR+nickel+OR+copper+OR+mine+OR+Brazil)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Anglo American';      Url='https://news.google.com/rss/search?q=%22Anglo+American%22+(copper+OR+platinum+OR+iron+OR+mine+OR+production)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 銅
    @{ Name='Freeport-McMoRan';    Url='https://news.google.com/rss/search?q=Freeport-McMoRan+(copper+OR+gold+OR+mine+OR+production)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Codelco';             Url='https://news.google.com/rss/search?q=Codelco+copper+(production+OR+market+OR+Chile)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 鋰 / 電池金屬
    @{ Name='Albemarle';           Url='https://news.google.com/rss/search?q=Albemarle+(lithium+OR+battery+OR+production+OR+Greenbushes)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='SQM';                 Url='https://news.google.com/rss/search?q=(%22SQM+Lithium%22+OR+%22Sociedad+Qu%C3%ADmica%22)+(lithium+OR+Chile+OR+production)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Ganfeng Lithium';     Url='https://news.google.com/rss/search?q=(%22Ganfeng+Lithium%22+OR+Ganfeng)+(lithium+OR+battery+OR+mine)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 稀土 / 磁鐵
    @{ Name='Lynas Rare Earths';   Url='https://news.google.com/rss/search?q=(Lynas+OR+%22Lynas+Rare+Earths%22)+(rare+earth+OR+neodymium+OR+mine+OR+production)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='MP Materials';        Url='https://news.google.com/rss/search?q=%22MP+Materials%22+(rare+earth+OR+neodymium+OR+magnet+OR+Mountain+Pass)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 金屬市場 / 價格
    @{ Name='LME 金屬交易';        Url='https://news.google.com/rss/search?q=(LME+OR+%22London+Metal+Exchange%22)+(price+OR+market+OR+stock+OR+inventory)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='鋼價市場';            Url='https://news.google.com/rss/search?q=(%22steel+price%22+OR+%22steel+market%22+OR+%22steel+demand%22+OR+%22hot-rolled+coil%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='鋁價市場';            Url='https://news.google.com/rss/search?q=(%22aluminum+price%22+OR+%22aluminium+price%22+OR+%22aluminum+market%22+OR+%22aluminum+demand%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='銅價 / 鎳價';         Url='https://news.google.com/rss/search?q=(%22copper+price%22+OR+%22nickel+price%22+OR+%22copper+market%22+OR+%22nickel+market%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='關鍵礦物';            Url='https://news.google.com/rss/search?q=(%22critical+minerals%22+OR+%22rare+earth+market%22+OR+%22strategic+metals%22+OR+%22battery+metals%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    # 台灣 / 中文
    @{ Name='中鋼 / 台灣金屬';      Url='https://news.google.com/rss/search?q=(%E4%B8%AD%E9%8B%BC+OR+%22China+Steel%22+OR+%E5%8F%B0%E9%8B%81+OR+%E7%87%9F%E9%8B%BC)+(%E9%8B%BC%E9%90%B5+OR+%E5%83%B9%E6%A0%BC+OR+%E5%B8%82%E5%A0%B4+OR+%E9%8B%81%E5%93%81)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.0 }
)

# ---------- 2b3d. 娛樂新聞（音樂 + 電影）----------
$EntertainmentSources = @(
    @{ Name='Variety';           Url='https://variety.com/feed/';                                                             Lang='en'; Weight=1.2 }
    @{ Name='Billboard';         Url='https://www.billboard.com/feed/';                                                       Lang='en'; Weight=1.2 }
    @{ Name='Rolling Stone';     Url='https://www.rollingstone.com/feed/';                                                    Lang='en'; Weight=1.1 }
    @{ Name='Hollywood Reporter';Url='https://www.hollywoodreporter.com/feed/';                                               Lang='en'; Weight=1.1 }
    @{ Name='Pitchfork';         Url='https://pitchfork.com/rss/news/';                                                       Lang='en'; Weight=1.0 }
    @{ Name='音樂新聞';          Url='https://news.google.com/rss/search?q=(%22new+album%22+OR+%22music+release%22+OR+%22concert+tour%22+OR+%22music+video%22+OR+Grammy+OR+Billboard)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='電影新聞';          Url='https://news.google.com/rss/search?q=(%22box+office%22+OR+%22movie+release%22+OR+%22film+premiere%22+OR+Oscar+OR+%22Cannes+Festival%22+OR+%22movie+trailer%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='串流平台';          Url='https://news.google.com/rss/search?q=(Netflix+OR+%22Disney+Plus%22+OR+%22Apple+TV%22+OR+HBO+OR+%22Prime+Video%22)+(series+OR+show+OR+release+OR+launch)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='華語娛樂';          Url='https://news.google.com/rss/search?q=(%E9%9F%B3%E6%A8%82+OR+%E6%BC%94%E5%94%B1%E6%9C%83+OR+%E5%B0%88%E8%BC%AF+OR+%E9%9B%BB%E5%BD%B1+OR+%E9%87%91%E6%9B%B2%E7%8D%8E+OR+%E9%87%91%E9%A6%AC%E7%8D%8E)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.0 }
)

$EntertainmentSignals = @(
    # 音樂
    'album(?:s)?\b', 'song(?:s)?\b', '\bmusic\b', 'concert(?:s)?', 'tour(?:s|ed|ing)?',
    'festival(?:s)?\b', 'artist(?:s)?\b', 'band(?:s)?\b', 'singer(?:s)?\b',
    'Grammy', 'Billboard', 'chart(?:s|-topping)?', 'hit(?:s|ting)?\s+(?:single|the\s+charts)',
    # 電影／影視
    '\bmovie\b', '\bfilm\b', 'director', 'actor', 'actress', 'star(?:s|ring)?',
    'premier(?:e|es|ed)', 'debut(?:s|ed|ing)?', 'release(?:s|d|ing)?',
    'Oscar(?:s)?', 'Golden\s+Globe', 'Emmy(?:s)?', 'Academy\s+Award', 'Cannes',
    'box\s+office', 'stream(?:ing|er)?', 'Netflix', 'Disney', 'HBO', 'Prime\s+Video',
    'TV\s+(?:show|series)', 'season\s+\d', 'episode', 'trailer',
    'launch(?:es|ed|ing)?', 'announc(?:e|es|ed|ement)',
    # 中文
    '專輯', '歌曲', '音樂', '演唱會', '巡演', '藝人', '歌手', '樂團',
    '電影', '影片', '導演', '男星', '女星', '明星', '主演', '影帝', '影后',
    '發行', '上映', '首映', '金曲獎', '金馬獎', '奧斯卡', '坎城',
    '票房', '串流', '劇集', '連續劇', '綜藝', '節目',
    '推出', '發布', '宣布'
)

# ---------- 2b3e. 美食新聞 ----------
$FoodSources = @(
    @{ Name='Eater';            Url='https://www.eater.com/rss/index.xml';                                                       Lang='en'; Weight=1.5 }
    @{ Name='Bon Appetit';      Url='https://www.bonappetit.com/feed/rss';                                                       Lang='en'; Weight=1.4 }
    @{ Name='Serious Eats';     Url='https://www.seriouseats.com/latest.rss';                                                    Lang='en'; Weight=1.3 }
    @{ Name='The Spruce Eats';  Url='https://www.thespruceeats.com/rss';                                                         Lang='en'; Weight=1.2 }
    @{ Name='Food52';           Url='https://food52.com/blog.rss';                                                               Lang='en'; Weight=1.2 }
    @{ Name='Tasting Table';    Url='https://www.tastingtable.com/feed.rss';                                                     Lang='en'; Weight=1.2 }
    @{ Name='The Kitchn';       Url='https://www.thekitchn.com/main.rss';                                                        Lang='en'; Weight=1.2 }
    @{ Name='Food & Wine';      Url='https://news.google.com/rss/search?q=site:foodandwine.com&hl=en-US&gl=US&ceid=US:en';         Lang='en'; Weight=1.1 }
    @{ Name='Michelin Guide';   Url='https://news.google.com/rss/search?q=(Michelin+OR+%22Michelin+Guide%22+OR+%22Michelin+star%22)+restaurant&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.2 }
    @{ Name='新餐廳／開幕';      Url='https://news.google.com/rss/search?q=(%22new+restaurant%22+OR+%22restaurant+opens%22+OR+%22chef+launches%22+OR+%22tasting+menu%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='美食趨勢';          Url='https://news.google.com/rss/search?q=(%22food+trend%22+OR+%22culinary+trend%22+OR+%22best+restaurants%22+OR+%22World%27s+50+Best%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='飲品 / 咖啡 / 酒';  Url='https://news.google.com/rss/search?q=(%22new+coffee%22+OR+%22specialty+coffee%22+OR+%22craft+beer%22+OR+%22natural+wine%22+OR+cocktail+bar)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='華語美食';          Url='https://news.google.com/rss/search?q=(%E7%B1%B3%E5%85%B6%E6%9E%97+OR+%E7%BE%8E%E9%A3%9F+OR+%E9%A4%90%E5%BB%B3+OR+%E5%A4%A7%E5%BB%9A+OR+%E4%B8%BB%E5%BB%9A+OR+%E5%BF%85%E6%AF%94%E7%99%BB)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.0 }
    @{ Name='甜點 / 烘焙';       Url='https://news.google.com/rss/search?q=(bakery+OR+pastry+OR+dessert+OR+%22new+ice+cream%22+OR+patisserie)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=0.9 }
)

# ---------- 2b3f. 台中咖啡好去處（只推薦咖啡）----------
$LocalFoodSources = @(
    @{ Name='台中咖啡推薦'; Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+%E5%92%96%E5%95%A1+(%E6%8E%A8%E8%96%A6+OR+%E5%BA%97+OR+%E5%BB%B3+OR+%E9%A4%A8+OR+%E5%BF%85%E5%96%9D)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.4 }
    @{ Name='台中咖啡館';   Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E5%92%96%E5%95%A1%E9%A4%A8+OR+%E5%92%96%E5%95%A1%E5%BB%B3+OR+%E5%92%96%E5%95%A1%E5%BA%97+OR+cafe+OR+coffee)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.4 }
    @{ Name='台中新開咖啡'; Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+%E5%92%96%E5%95%A1+(%E6%96%B0%E9%96%8B+OR+%E9%96%8B%E5%B9%95+OR+%E5%85%A5%E9%A7%90+OR+%E9%96%8B%E5%BA%97)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.3 }
    @{ Name='台中精品咖啡'; Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E7%B2%BE%E5%93%81%E5%92%96%E5%95%A1+OR+%E8%87%AA%E5%AE%B6%E7%83%98%E7%84%99+OR+%E7%8D%A8%E7%AB%8B%E5%92%96%E5%95%A1+OR+specialty+coffee)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.3 }
    @{ Name='台中咖啡地圖'; Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E5%92%96%E5%95%A1%E5%9C%B0%E5%9C%96+OR+%E5%92%96%E5%95%A1%E5%B7%A1%E7%A6%AE+OR+%E5%92%96%E5%95%A1%E6%8E%A8%E8%96%A6+OR+%E5%92%96%E5%95%A1%E6%B8%85%E5%96%AE)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.2 }
    @{ Name='台中拿鐵手沖'; Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E6%8B%BF%E9%90%B5+OR+%E6%89%8B%E6%B2%96+OR+%E6%BF%83%E7%B8%AE+OR+%E8%99%B9%E5%90%B8+OR+%E5%8D%A1%E5%B8%83%E5%A5%87%E8%AB%BE+OR+%E9%82%A3%E4%B8%8D%E5%8B%92)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.2 }
)

# 必須含「咖啡」相關詞才納入（嚴格限定咖啡主題）
$LocalFoodSignals = @(
    '咖啡', '咖啡館', '咖啡店', '咖啡廳', '咖啡廳', '咖啡地圖', '咖啡巡禮',
    '拿鐵', '卡布奇諾', '美式', '濃縮', '手沖', '虹吸', '義式', '冷萃', '冰滴',
    '那不勒斯', '單品', '耶加雪菲', '曼特寧', '藝伎', '肯亞',
    '烘豆', '烘焙', '自家烘焙', '淺焙', '中焙', '深焙',
    '拉花', '精品咖啡', '獨立咖啡', 'specialty', 'coffee', 'cafe', 'latte', 'espresso'
)

# ---------- 2b3i. 天氣預報 + 空氣品質 ----------
$WeatherSources = @(
    @{ Name='天氣預報';     Url='https://news.google.com/rss/search?q=(%E5%A4%A9%E6%B0%A3+OR+%E6%B0%A3%E8%B1%A1+OR+%E9%8B%92%E9%9D%A2+OR+%E9%A2%B1%E9%A2%A8+OR+%E5%AF%92%E6%B5%81+OR+%E9%AB%98%E6%BA%AB+OR+%E8%B1%AA%E9%9B%A8)+%E5%8F%B0%E7%81%A3&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.3 }
    @{ Name='空氣品質';     Url='https://news.google.com/rss/search?q=(%E7%A9%BA%E6%B0%A3%E5%93%81%E8%B3%AA+OR+AQI+OR+PM2.5+OR+%E7%B4%B0%E7%A9%BA%E6%B0%A3%E6%B1%99%E6%9F%93+OR+%E6%9D%B1%E5%8C%97%E5%AD%A3%E9%A2%A8)+%E5%8F%B0%E7%81%A3&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.2 }
    @{ Name='中央氣象局';    Url='https://news.google.com/rss/search?q=(%E4%B8%AD%E5%A4%AE%E6%B0%A3%E8%B1%A1%E7%BD%B2+OR+%E6%B0%A3%E8%B1%A1%E7%BD%B2)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.2 }
)
$WeatherSignals = @(
    '天氣', '氣象', '氣溫', '降雨', '降雪', '颱風', '鋒面', '寒流', '寒潮',
    '高溫', '熱浪', '豪雨', '陣雨', '梅雨', '午後雷陣雨',
    '空氣', '空品', 'AQI', 'PM2.5', 'PM10', '霾', '東北季風', '西南氣流',
    '預報', '警報', '特報', '預估', '預測', '氣候', '極端'
)

# WMO 氣象代碼 → 中文
function Get-WeatherCodeLabel {
    param([int]$code)
    if ($code -eq 0) { return '晴朗' }
    if ($code -eq 1) { return '大致晴朗' }
    if ($code -eq 2) { return '局部多雲' }
    if ($code -eq 3) { return '陰天' }
    if ($code -in 45,48) { return '霧' }
    if ($code -in 51,53,55) { return '毛毛雨' }
    if ($code -in 56,57) { return '凍雨' }
    if ($code -in 61,63,65) { return '下雨' }
    if ($code -in 66,67) { return '凍雨' }
    if ($code -in 71,73,75,77) { return '下雪' }
    if ($code -in 80,81,82) { return '陣雨' }
    if ($code -in 85,86) { return '陣雪' }
    if ($code -in 95,96,99) { return '雷雨' }
    return '—'
}

function Get-WeatherCodeEmoji {
    param([int]$code)
    if ($code -eq 0) { return '☀️' }
    if ($code -in 1,2) { return '🌤️' }
    if ($code -eq 3) { return '☁️' }
    if ($code -in 45,48) { return '🌫️' }
    if ($code -in 51,53,55,61,63,65,80,81,82) { return '🌧️' }
    if ($code -in 71,73,75,77,85,86) { return '❄️' }
    if ($code -in 95,96,99) { return '⛈️' }
    return '🌡️'
}

function Get-WeatherDashboard {
    param([double]$lat = 24.104, [double]$lon = 120.503)
    try {
        $url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,precipitation&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max&timezone=Asia%2FTaipei&forecast_days=5"
        return Invoke-RestMethod -Uri $url -TimeoutSec 15
    } catch {
        Write-Host "  天氣 API 取得失敗: $_" -ForegroundColor Yellow
        return $null
    }
}

function Get-AQI {
    # 多城市查詢 waqi.info 免費公開端點（demo token，台灣各城市各抓一筆）
    $cities = @(
        @{ key='hemei';     name='和美' }
        @{ key='changhua';  name='彰化' }
        @{ key='lukang';    name='鹿港' }
        @{ key='taichung';  name='台中' }
        @{ key='taichung-xitun';     name='台中西屯' }
        @{ key='taichung-fengyuan';  name='台中豐原' }
        @{ key='nantou';    name='南投' }
        @{ key='miaoli';    name='苗栗' }
        @{ key='taipei';    name='台北' }
        @{ key='taoyuan';   name='桃園' }
        @{ key='hsinchu';   name='新竹' }
        @{ key='kaohsiung'; name='高雄' }
        @{ key='tainan';    name='台南' }
        @{ key='chiayi';    name='嘉義' }
        @{ key='yilan';     name='宜蘭' }
        @{ key='hualien';   name='花蓮' }
    )
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cities) {
        try {
            $url = "https://api.waqi.info/feed/$($c.key)/?token=demo"
            $r = Invoke-RestMethod -Uri $url -TimeoutSec 8 -UserAgent 'Mozilla/5.0'
            if ($r.status -eq 'ok' -and $r.data -and $r.data.aqi -and ($r.data.aqi -ne '-')) {
                $aqi = [int]$r.data.aqi
                $status = if ($aqi -le 50) {'良好'}
                          elseif ($aqi -le 100) {'普通'}
                          elseif ($aqi -le 150) {'敏感族群不健康'}
                          elseif ($aqi -le 200) {'不健康'}
                          elseif ($aqi -le 300) {'非常不健康'}
                          else {'危害'}
                $results.Add([pscustomobject]@{
                    sitename = $c.name
                    aqi      = $aqi
                    status   = $status
                })
            }
        } catch { }
    }
    return ,$results.ToArray()
}

# ---------- 2b3h. 親子週末好去處（有孩子同仁）----------
$KidSources = @(
    @{ Name='親子景點';     Url='https://news.google.com/rss/search?q=%E8%A6%AA%E5%AD%90+(%E6%99%AF%E9%BB%9E+OR+%E6%B4%BB%E5%8B%95+OR+%E6%8E%A8%E8%96%A6+OR+%E5%A5%BD%E5%8E%BB%E8%99%95)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.3 }
    @{ Name='週末親子';     Url='https://news.google.com/rss/search?q=%E9%80%B1%E6%9C%AB+%E8%A6%AA%E5%AD%90+(%E5%A5%BD%E5%8E%BB%E8%99%95+OR+%E6%B4%BB%E5%8B%95+OR+%E8%A1%8C%E7%A8%8B+OR+%E6%BA%9C%E5%B0%8F%E5%AD%A9)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.3 }
    @{ Name='親子餐廳';     Url='https://news.google.com/rss/search?q=%E8%A6%AA%E5%AD%90%E9%A4%90%E5%BB%B3+(%E6%8E%A8%E8%96%A6+OR+%E6%96%B0%E9%96%8B+OR+%E9%81%8A%E6%A8%82%E5%8D%80)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.2 }
    @{ Name='兒童樂園';     Url='https://news.google.com/rss/search?q=(%E9%81%8A%E6%A8%82%E5%9C%92+OR+%E6%B8%B8%E6%A8%82%E5%A0%B4+OR+%E4%B8%BB%E9%A1%8C%E6%A8%82%E5%9C%92+OR+%E5%85%92%E7%AB%A5)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.1 }
    @{ Name='博物館動物園'; Url='https://news.google.com/rss/search?q=(%E5%8B%95%E7%89%A9%E5%9C%92+OR+%E6%B0%B4%E6%97%8F%E9%A4%A8+OR+%E5%8D%9A%E7%89%A9%E9%A4%A8+OR+%E7%A7%91%E5%AD%B8%E9%A4%A8+OR+%E8%BE%B2%E5%A0%B4)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.1 }
    @{ Name='中部親子';     Url='https://news.google.com/rss/search?q=(%E5%8F%B0%E4%B8%AD+OR+%E5%BD%B0%E5%8C%96+OR+%E5%8D%97%E6%8A%95+OR+%E8%8B%97%E6%A0%97)+%E8%A6%AA%E5%AD%90&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.2 }
    @{ Name='全台親子';     Url='https://news.google.com/rss/search?q=%E5%85%A8%E5%8F%B0+%E8%A6%AA%E5%AD%90+(%E6%99%AF%E9%BB%9E+OR+%E6%B4%BB%E5%8B%95+OR+%E9%80%B1%E6%9C%AB)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.1 }
    @{ Name='戶外親子';     Url='https://news.google.com/rss/search?q=(%E9%9C%B2%E7%87%9F+OR+%E6%AD%A5%E9%81%93+OR+%E8%BE%B2%E5%A0%B4+OR+%E6%A3%AE%E6%9E%97%E9%81%8A%E6%A8%82%E5%8D%80)+%E8%A6%AA%E5%AD%90&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.0 }
)

$KidSignals = @(
    '親子', '小孩', '兒童', '孩子', '家庭',
    '週末', '假日', '連假', '暑假', '寒假', '出遊', '溜小孩', '放電',
    '景點', '活動', '推薦', '必去', '必玩', '好去處',
    '遊樂園', '遊樂場', '主題樂園', '樂園', '農場', '牧場', '森林', '步道',
    '動物園', '水族館', '博物館', '美術館', '兒童館', '科博館', '科工館',
    '公園', '野餐', '露營', '親水', '共融',
    '親子餐廳', '親子友善', '親子民宿', '親子飯店', '遊樂區',
    'DIY', '手作', '課程', '體驗', '展覽', '市集',
    '免費', '優惠', '新開', '開幕'
)

# ---------- 2b3j. 台中啤酒好地方 ----------
$BeerSources = @(
    @{ Name='台中精釀啤酒';  Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E7%B2%BE%E9%87%80+OR+%E7%B2%BE%E9%87%80%E5%95%A4%E9%85%92+OR+%E7%B2%BE%E9%87%80%E5%95%A4%E5%90%A7+OR+%E5%95%A4%E9%85%92%E5%90%A7+OR+craft+beer)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.3 }
    @{ Name='台中酒吧';      Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E9%85%92%E5%90%A7+OR+%E9%85%92%E9%A4%A8+OR+%E5%B0%8F%E9%85%92%E9%A4%A8+OR+%E8%AA%BF%E9%85%92+OR+cocktail+bar)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.2 }
    @{ Name='台中居酒屋';    Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E5%B1%85%E9%85%92%E5%B1%8B+OR+%E7%86%B1%E7%82%92+OR+%E7%83%8F%E9%BE%8D%E9%BA%B5+OR+%E7%87%92%E9%B3%A5)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.2 }
    @{ Name='台中餐酒館';    Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E9%A4%90%E9%85%92%E9%A4%A8+OR+%E9%A4%90%E9%85%92+OR+bistro+OR+tapas)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.1 }
    @{ Name='台中微醺';      Url='https://news.google.com/rss/search?q=%E5%8F%B0%E4%B8%AD+(%E5%BE%AE%E9%86%BA+OR+%E5%A4%9C%E6%99%9A+OR+%E6%B0%A3%E6%B0%9B+OR+%E6%B7%B1%E5%A4%9C%E9%A3%9F%E5%A0%82)+(%E9%85%92+OR+%E5%95%A4%E9%85%92)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.0 }
    @{ Name='中部精釀啤酒';  Url='https://news.google.com/rss/search?q=%E7%B2%BE%E9%87%80+%E5%95%A4%E9%85%92+(%E5%8F%B0%E4%B8%AD+OR+%E4%B8%AD%E9%83%A8+OR+%E5%BD%B0%E5%8C%96)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.1 }
)
$BeerSignals = @(
    '台中', '彰化', '精釀', '啤酒', '酒吧', '酒館', '居酒屋', '餐酒館',
    '調酒', '雞尾酒', '單一麥芽', '威士忌', '清酒', '生啤', '拉格', '艾爾',
    '熱炒', '深夜食堂', '下酒菜', '微醺', '消夜', '宵夜',
    '推薦', '必喝', '必去', '新開', '開幕', '排隊', '隱藏', '打卡',
    'bar', 'beer', 'brewery', 'cocktail', 'whisky', 'sake'
)

# ---------- 2b3g. 和美搖飲(忍) ----------
$RenSources = @(
    # 限定在 和美 + 飲料/手搖 範圍，避免抓到其他 "忍" 相關無關文章
    @{ Name='和美手搖飲料';  Url='https://news.google.com/rss/search?q=%E5%92%8C%E7%BE%8E+(%E6%89%8B%E6%91%87%E9%A3%B2+OR+%E6%89%8B%E6%91%87%E6%9D%AF+OR+%E9%A3%B2%E6%96%99%E5%BA%97+OR+%E6%90%96%E9%A3%B2+OR+%E6%89%8B%E6%91%87%E9%A3%B2%E6%96%99)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.5 }
    @{ Name='和美忍飲料';    Url='https://news.google.com/rss/search?q=%22%E5%92%8C%E7%BE%8E%22+%22%E5%BF%8D%22+(%E9%A3%B2+OR+%E8%8C%B6+OR+%E5%A5%B6)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.4 }
    @{ Name='彰化手搖';      Url='https://news.google.com/rss/search?q=%E5%BD%B0%E5%8C%96+(%E6%89%8B%E6%91%87%E9%A3%B2+OR+%E6%89%8B%E6%91%87%E6%9D%AF+OR+%E9%A3%B2%E6%96%99%E5%BA%97+OR+%E6%90%96%E9%A3%B2)&hl=zh-TW&gl=TW&ceid=TW:zh-TW'; Lang='zh'; Weight=1.0 }
)

# 必須同時含「和美/彰化」+「飲料類」關鍵字才納入
$RenSignals = @(
    '手搖', '手搖杯', '手搖飲', '手搖飲料', '飲料店', '搖飲',
    '珍珠', '珍奶', '奶茶', '紅茶', '綠茶', '果茶', '茶飲', '茶店',
    '波霸', '粉圓', '椰果', '仙草'
)

$FoodSignals = @(
    'restaurant(?:s)?\b', 'cafe\b', 'bistro\b', 'eatery', 'diner',
    'recipe(?:s)?\b', 'chef(?:s)?\b', 'cook(?:s|ing|ed|book)?\b',
    'Michelin\s+(?:star|guide)', 'Bib\s+Gourmand', '50\s+Best',
    'dining', 'meal(?:s)?\b', 'dish(?:es)?\b', 'cuisine', 'menu(?:s)?\b',
    '\bfood(?:ie)?\b', 'bakery', 'patisserie', 'pastry', 'dessert', 'ice\s+cream',
    'drink(?:s)?\b', 'beverage', '\bwine\b', '\bcoffee\b', '\btea\b',
    'cocktail(?:s)?', '\bbeer\b', 'craft\s+(?:beer|spirits)',
    'pizza', 'sushi', 'ramen', 'burger', 'taco', 'dim\s+sum', 'bbq',
    'seasonal', 'flavor(?:s)?', 'ingredient(?:s)?', 'gastronomy', 'culinary',
    'award(?:s|ed)?', 'open(?:s|ed|ing)?\b', 'launch(?:es|ed|ing)?',
    'new\s+(?:restaurant|menu|spot|chef|bar|cafe)', 'pop[-\s]?up',
    # 中文
    '餐廳', '餐館', '咖啡', '食譜', '主廚', '大廚', '廚師',
    '米其林', '美食', '料理', '菜單', '菜色', '菜品', '佳餚',
    '甜點', '烘焙', '麵包', '披薩', '壽司', '拉麵', '火鍋',
    '燒肉', '燉肉', '便當', '早餐', '午餐', '晚餐', '宵夜',
    '口味', '食材', '飲品', '葡萄酒', '啤酒',
    '必比登', '星級', '開幕', '新開', '新店', '推出', '新推出'
)

# ---------- 2b3. 複合材料技術新聞（製程／材料配方／R&D）----------
$TechSources = @(
    # 直接 RSS — 有圖片（og:image）
    @{ Name='CompositesWorld (Tech)'; Url='https://www.compositesworld.com/rss/news';   Lang='en'; Weight=1.4 }
    @{ Name='JEC Composites (Tech)';  Url='https://www.jeccomposites.com/feed/';        Lang='en'; Weight=1.4 }
    # Google News — 主題式搜尋
    @{ Name='自動疊層／AFP';     Url='https://news.google.com/rss/search?q=(%22automated+fiber+placement%22+OR+AFP+composite+OR+%22automated+tape+laying%22+OR+ATL+composite)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='樹脂傳遞成型';      Url='https://news.google.com/rss/search?q=(RTM+composite+OR+VARTM+OR+%22resin+transfer+molding%22+OR+%22resin+infusion%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='熱塑性複材';        Url='https://news.google.com/rss/search?q=(%22thermoplastic+composite%22+OR+%22thermoplastic+matrix%22+OR+TPC+composite+OR+%22PEEK+composite%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='Out-of-Autoclave';  Url='https://news.google.com/rss/search?q=(%22out-of-autoclave%22+OR+%22OOA+composite%22+OR+%22snap-cure%22+OR+%22fast+cure+composite%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='3D列印複材';        Url='https://news.google.com/rss/search?q=(%22composite+3D+printing%22+OR+%22composite+additive+manufacturing%22+OR+%22carbon+fiber+3D%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='複材回收';          Url='https://news.google.com/rss/search?q=(%22carbon+fiber+recycling%22+OR+%22composite+recycling%22+OR+%22recycled+carbon+fiber%22+OR+%22closed-loop+composite%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='生物基複材';        Url='https://news.google.com/rss/search?q=(%22bio-based+composite%22+OR+biocomposite+OR+%22natural+fiber+composite%22+OR+%22sustainable+composite%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='石墨烯／奈米複材';   Url='https://news.google.com/rss/search?q=(%22graphene+composite%22+OR+nanocomposite+OR+%22CNT+composite%22+OR+%22carbon+nanotube+composite%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='複材研究／突破';    Url='https://news.google.com/rss/search?q=(%22composite+research%22+OR+%22composite+breakthrough%22+OR+%22composite+innovation%22+OR+%22composite+technology%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='Digital / AI 複材'; Url='https://news.google.com/rss/search?q=(%22digital+composite%22+OR+%22AI+composite%22+OR+%22machine+learning+composite%22+OR+%22composite+simulation%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=0.9 }
)

# ---------- 2c. 複材應用新聞來源（8 個細分領域）----------
$AppSources = @(
    # Runner's World 直接 RSS（有圖＋真實 URL）
    @{ Name="Runner's World";      Url='https://www.runnersworld.com/rss/all.xml/';                                                                  Lang='en'; Weight=1.2 }
    @{ Name='運動鞋／超級跑鞋';  Url='https://news.google.com/rss/search?q=(%22carbon+plate%22+OR+%22super+shoes%22)+(running+OR+marathon+OR+Nike+OR+Adidas)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='自行車複材';         Url='https://news.google.com/rss/search?q=(%22carbon+bicycle%22+OR+%22carbon+frame%22+OR+%22composite+bike%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='航空／航太複材';     Url='https://news.google.com/rss/search?q=(%22composite+aircraft%22+OR+%22aerospace+composite%22+OR+%22composite+fuselage%22+OR+%22composite+wing%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='醫療複材';           Url='https://news.google.com/rss/search?q=(%22composite+medical%22+OR+%22carbon+prosthetic%22+OR+%22medical+carbon+fiber%22+OR+%22composite+implant%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='筆電／3C 複材';       Url='https://news.google.com/rss/search?q=(%22carbon+fiber+laptop%22+OR+%22composite+laptop%22+OR+%22carbon+fiber+phone%22+OR+%22magnesium+composite%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='水上運動';           Url='https://news.google.com/rss/search?q=(%22carbon+kayak%22+OR+%22carbon+paddle%22+OR+%22carbon+surfboard%22+OR+%22carbon+SUP%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='球拍／運動器材';     Url='https://news.google.com/rss/search?q=(%22composite+tennis%22+OR+%22carbon+tennis+racket%22+OR+%22graphene+racket%22+OR+%22carbon+golf%22+OR+%22carbon+baseball+bat%22+OR+%22carbon+pickleball%22+OR+%22badminton+racket%22+OR+%22squash+racket%22+OR+%22table+tennis%22+carbon)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='冰球曲棍球';         Url='https://news.google.com/rss/search?q=(%22hockey+stick%22+carbon+OR+%22composite+hockey%22+OR+%22hockey+blade%22+carbon+OR+%22ice+hockey%22+stick)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='運動品牌複材';       Url='https://news.google.com/rss/search?q=(Nike+OR+Adidas+OR+Puma+OR+%22New+Balance%22+OR+Asics+OR+%22Under+Armour%22+OR+Hoka+OR+Brooks)+(carbon+OR+composite+OR+%22super+shoe%22+OR+%22carbon+plate%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.1 }
    @{ Name='汽車複材';           Url='https://news.google.com/rss/search?q=(%22composite+automotive%22+OR+%22carbon+fiber+car%22+OR+%22BMW+CFRP%22+OR+%22Lamborghini+carbon%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
)

# ---------- 2d. 超級纖維技術（Kevlar／芳綸／UHMWPE／碳纖技術）----------
$FiberSources = @(
    @{ Name='Kevlar 應用';       Url='https://news.google.com/rss/search?q=Kevlar+(technology+OR+innovation+OR+application+OR+armor+OR+material)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='芳綸纖維';            Url='https://news.google.com/rss/search?q=(%22aramid+fiber%22+OR+%22aramid+fibre%22+OR+Twaron+OR+%22para-aramid%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='UHMWPE Dyneema';      Url='https://news.google.com/rss/search?q=(Dyneema+OR+%22UHMWPE%22+OR+%22Spectra+fiber%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='碳纖技術突破';        Url='https://news.google.com/rss/search?q=(%22carbon+fiber+technology%22+OR+%22carbon+fiber+breakthrough%22+OR+%22nano+carbon+fiber%22+OR+%22recycled+carbon+fiber%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='PBO/Zylon 超級纖維';  Url='https://news.google.com/rss/search?q=(Zylon+OR+PBO+fiber+OR+%22Vectran%22+OR+%22super+fiber%22)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='高性能纖維';           Url='https://news.google.com/rss/search?q=(%22high-performance+fiber%22+OR+%22advanced+fiber%22+OR+%22ballistic+fiber%22+OR+Technora+OR+Zylon)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
    @{ Name='纖維產業研究';         Url='https://news.google.com/rss/search?q=(fiber+manufacturer+OR+%22fiber+industry%22)+(announc+OR+launch+OR+research+OR+breakthrough)&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
)

# 電商商品/個人消費品關鍵字黑名單（出現就過濾）
$CarbonBlacklist = @(
    'amazon\.com', 'ebay', 'walmart', 'aliexpress', 'for sale', 'in stock',
    'bicycle fork', 'paddle tennis', 'belly pan', 'cargo cover', 'seat cover',
    'arrow carbon express', 'headset caps?', 'in-ceiling speakers?',
    'VEVOR', 'Monoprice', 'guitar pick', 'fishing rod', 'drone frame',
    'phone case', 'laptop case', 'watch band', 'watch strap', 'keychain',
    'knife handle', 'tie clip', 'vape', 'wallet', 'luggage', 'dashboard',
    'side mirror', 'hood cover', 'gun grip', 'motorcycle', 'scooter',
    'fairing', 'mudguard', 'spoiler', 'decal', 'wrap kit'
)

# ---------- 4. 工具函式 ----------
function Parse-Date {
    param([string]$s)
    if (-not $s) { return $null }
    try { return [datetime]::Parse($s).ToUniversalTime() } catch { return $null }
}

function Strip-Html {
    param([string]$s)
    if (-not $s) { return '' }
    $s = [regex]::Replace($s, '<[^>]+>', ' ')
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    $s = [regex]::Replace($s, '\s+', ' ')
    return $s.Trim()
}

function HtmlEsc {
    param([string]$s)
    if (-not $s) { return '' }
    return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
}

function Get-Score {
    param($Title, $Desc, $Weight, $Pub)
    $text  = ("$Title $Desc").ToLower()
    $score = 0.0
    foreach ($kw in $Keywords.Keys) {
        if ($text.Contains($kw.ToLower())) { $score += $Keywords[$kw] }
    }
    if ($Pub) {
        $age = ((Get-Date).ToUniversalTime() - $Pub).TotalHours
        $score += [math]::Max(0, 12 - $age * 0.5)
    }
    return [math]::Round($score * $Weight, 2)
}

function Get-TitleKey {
    param([string]$t)
    $t = $t.ToLower()
    $t = [regex]::Replace($t, '[^\w\u4e00-\u9fff ]', ' ')
    $stop = @('the','a','an','is','are','was','were','in','on','at','to','of','for','and','or','but','with','from','as','by','that','this','it','its','says','say')
    $words = $t -split '\s+' | Where-Object { $_.Length -ge 3 -and $_ -notin $stop } | Sort-Object -Unique
    return ,@($words)
}

function Is-Similar {
    param($key1, $key2)
    if ($key1.Count -eq 0 -or $key2.Count -eq 0) { return $false }
    $common = @($key1 | Where-Object { $_ -in $key2 }).Count
    $minLen = [math]::Min($key1.Count, $key2.Count)
    if ($minLen -eq 0) { return $false }
    return ($common / $minLen) -ge 0.55
}

function Get-Category {
    param([string]$Title, [string]$Desc)
    $t = ("$Title $Desc").ToLower()
    # 科技／未來材料優先判斷（避免被其他類別搶走）
    if ($t -match 'ai |artificial intelligence|chatgpt|openai|anthropic|llm|semiconductor|tsmc|chip|nvidia|asml|quantum|drone|uav|autonomous|self-driving|robotics|robot |spacex|starlink|satellite|evtol|electric vehicle|tesla|battery|lithium|graphene|nanotech|nanomaterial|hydrogen|fuel cell|composite|cfrp|carbon fiber|3d printing|additive manufacturing|hypersonic|biotech|gene editing|人工智慧|半導體|台積電|晶片|輝達|無人機|自動駕駛|機器人|量子|電動車|特斯拉|電池|固態電池|太空|衛星|火箭|石墨烯|奈米|氫能|燃料電池|複合材料|碳纖維|先進材料|新材料') { return 'Tech' }
    if ($t -match 'war|attack|missile|strike|killed|invasion|airstrike|戰爭|襲擊|飛彈|空襲|入侵|死亡|交火|停火') { return 'Conflict' }
    if ($t -match 'stock|bond|oil|yuan|dollar|market|股市|債券|油價|匯率|股票|市場') { return 'Markets' }
    if ($t -match 'tariff|trade|sanction|inflation|recession|gdp|fed|earnings|ipo|merger|acquisition|關稅|貿易|制裁|通膨|衰退|央行|升息|降息|聯準會') { return 'Economy' }
    if ($t -match 'summit|meeting|talks|diplomat|treaty|峰會|會談|外交|條約|訪問|協議') { return 'Diplomacy' }
    return 'Politics'
}

# ----- 翻譯（DeepL 優先 → Google fallback → 本地快取）-----
$script:TranslateCacheFile = Join-Path $PSScriptRoot '.translate_cache.json'
$script:TranslateCache = @{}
if (Test-Path $script:TranslateCacheFile) {
    try {
        $obj = Get-Content $script:TranslateCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) { $script:TranslateCache[$prop.Name] = $prop.Value }
    } catch { }
}

# 偵測 DeepL key（優先從 .deepl_key 檔，其次環境變數）
$script:DeepLKey = ''
$keyFile = Join-Path $PSScriptRoot '.deepl_key'
if (Test-Path $keyFile) {
    $script:DeepLKey = ((Get-Content $keyFile -Raw -ErrorAction SilentlyContinue) -replace '\s','').Trim()
}
if (-not $script:DeepLKey -and $env:DEEPL_API_KEY) { $script:DeepLKey = $env:DEEPL_API_KEY }
$script:UseDeepL = [bool]$script:DeepLKey
if ($script:UseDeepL) {
    Write-Host "[翻譯] 啟用 DeepL（品質最佳）" -ForegroundColor Green
} else {
    Write-Host "[翻譯] 使用 Google（要升級 DeepL，把 key 存到 .deepl_key 檔）" -ForegroundColor DarkGray
}

function Save-TranslateCache {
    try {
        $script:TranslateCache | ConvertTo-Json -Depth 3 |
            Out-File -FilePath $script:TranslateCacheFile -Encoding UTF8 -Force
    } catch { Write-Host "快取寫入失敗: $_" -ForegroundColor Yellow }
}

function Test-IsChinese {
    param([string]$s)
    if (-not $s) { return $true }
    $cjk = 0
    foreach ($c in $s.ToCharArray()) {
        $code = [int]$c
        if ($code -ge 0x4e00 -and $code -le 0x9fff) { $cjk++ }
    }
    return ($cjk -gt $s.Length * 0.2)
}

function Invoke-DeepL {
    param([string]$text, [string]$target)
    $endpoint = if ($script:DeepLKey.EndsWith(':fx')) {
        'https://api-free.deepl.com/v2/translate'
    } else {
        'https://api.deepl.com/v2/translate'
    }
    # 手動組 form body 並以 UTF-8 bytes 送出，避免 PS 5.1 編碼問題
    $bodyStr   = "text=$([uri]::EscapeDataString($text))&target_lang=$target&source_lang=EN"
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($bodyStr)
    $headers = @{
        Authorization  = "DeepL-Auth-Key $($script:DeepLKey)"
        'Content-Type' = 'application/x-www-form-urlencoded; charset=utf-8'
    }
    $resp = Invoke-WebRequest -Uri $endpoint -Method Post -Body $bodyBytes -Headers $headers `
            -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
    # 強制把回應 bytes 當 UTF-8 解碼
    $raw = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    $parsed = $raw | ConvertFrom-Json
    if ($parsed.translations -and $parsed.translations[0].text) {
        return [string]$parsed.translations[0].text
    }
    return $null
}

function Translate-WithDeepL {
    param([string]$text)
    if (-not $script:DeepLKey) { return $null }
    try {
        return Invoke-DeepL -text $text -target 'ZH-HANT'
    } catch {
        if ($_.Exception.Message -match '400|Bad Request') {
            try { return Invoke-DeepL -text $text -target 'ZH' } catch { }
        }
        Write-Host "  DeepL 失敗，改用 Google: $($_.Exception.Message)" -ForegroundColor DarkYellow
        $script:UseDeepL = $false
    }
    return $null
}

function Translate-WithGoogle {
    param([string]$text)
    try {
        $encoded = [uri]::EscapeDataString($text)
        $url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=zh-TW&dt=t&q=$encoded"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 15 -UserAgent 'Mozilla/5.0'
        $result = ''
        foreach ($seg in $resp[0]) {
            if ($seg -and $seg.Count -ge 1 -and $seg[0]) { $result += [string]$seg[0] }
        }
        if ($result) { return $result }
    } catch {
        Write-Host "  Google 翻譯失敗: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    return $null
}

function Translate-Text {
    param([string]$text)
    if (-not $text -or $text.Trim().Length -lt 2) { return $text }
    if (Test-IsChinese $text) { return $text }
    if ($script:TranslateCache.ContainsKey($text)) { return [string]$script:TranslateCache[$text] }

    $result = $null
    if ($script:UseDeepL) { $result = Translate-WithDeepL $text }
    if (-not $result)     { $result = Translate-WithGoogle $text }

    if ($result) {
        $script:TranslateCache[$text] = $result
        Start-Sleep -Milliseconds 100
        return $result
    }
    return $text   # 都失敗就回原文
}

# ----- 抓原文全文（碳纖維新聞用，Google News link 會先解析真網址）-----
function Resolve-GoogleNewsUrl {
    param([string]$url)
    if ($url -notmatch 'news\.google\.com/(rss/)?articles/') { return $url }

    # 方法 1：從 URL 內 base64 payload 直接抽真實網址（新版 Google News 常用）
    $m = [regex]::Match($url, '/articles/([A-Za-z0-9_\-]+)')
    if ($m.Success) {
        try {
            $encoded = $m.Groups[1].Value.Replace('-', '+').Replace('_', '/')
            while ($encoded.Length % 4 -ne 0) { $encoded += '=' }
            $bytes = [Convert]::FromBase64String($encoded)
            $text  = [Text.Encoding]::UTF8.GetString($bytes)
            $u = [regex]::Match($text, 'https?://[^\s\x00-\x1f"''<>]+')
            if ($u.Success -and $u.Value -notmatch 'news\.google\.com') {
                return $u.Value.TrimEnd([char]0x12, [char]0x10, '&', '?')
            }
        } catch { }
    }

    # 方法 2：fetch 後找 canonical / meta refresh
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 `
                -UserAgent 'Mozilla/5.0' -MaximumRedirection 10 -ErrorAction Stop
        $m = [regex]::Match($resp.Content, '<meta[^>]+http-equiv="refresh"[^>]+url=([^"''> ]+)', 'IgnoreCase')
        if ($m.Success) { return ([System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)) }
        $m = [regex]::Match($resp.Content, '<link[^>]+rel="canonical"[^>]+href="([^"]+)"', 'IgnoreCase')
        if ($m.Success -and $m.Groups[1].Value -notmatch 'news\.google\.com') { return $m.Groups[1].Value }
        $m = [regex]::Match($resp.Content, 'href="(https?://(?!news\.google\.com)[^"]+)"')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return $url
}

function Get-ArticleImage {
    param([string]$url)
    if (-not $url) { return '' }
    # Google News wrapper 解析不出，直接放棄
    if ($url -match 'news\.google\.com/(rss/)?articles/') { return '' }
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 `
                -UserAgent 'Mozilla/5.0' -MaximumRedirection 10 -ErrorAction Stop
        $html = $resp.Content
        # og:image（優先）
        $m = [regex]::Match($html, '<meta[^>]+property=["'']og:image(?::secure_url)?["''][^>]+content=["'']([^"'']+)', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
        # 反序也試
        $m = [regex]::Match($html, '<meta[^>]+content=["'']([^"'']+)["''][^>]+property=["'']og:image', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
        # twitter:image
        $m = [regex]::Match($html, '<meta[^>]+name=["'']twitter:image["''][^>]+content=["'']([^"'']+)', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
        # 第一張內文 <img>
        $m = [regex]::Match($html, '<img[^>]+src=["''](https?://[^"'']+\.(?:jpg|jpeg|png|webp)[^"'']*)', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return ''
}

# 無圖項目套用主題隨機圖（LoremFlickr 免費，依關鍵字挑 Flickr 圖）
function Set-FallbackImages {
    param($items, [string]$keywords)
    $cleanKw = ($keywords -replace '\s+','').ToLower()
    foreach ($p in $items) {
        if (-not $p.Image) {
            $hash = 0
            foreach ($c in ($p.Title + $p.Link).ToCharArray()) { $hash = ($hash * 31 + [int]$c) -band 0x7fffffff }
            $lock = $hash % 10000
            $p.Image = "https://loremflickr.com/400/225/$cleanKw`?lock=$lock"
        }
    }
}

# 副面板補圖（只對非 Google News 的直接 URL 有機會成功）
function Add-PanelImages {
    param($items, [string]$label)
    $before = @($items | Where-Object { $_.Image }).Count
    foreach ($p in $items) {
        if ($p.Image) { continue }
        $img = Get-ArticleImage $p.Link
        if ($img) { $p.Image = $img }
        Start-Sleep -Milliseconds 150
    }
    $after = @($items | Where-Object { $_.Image }).Count
    Write-Host ("  → {0} 圖片：{1} → {2}" -f $label, $before, $after) -ForegroundColor DarkGray
}

function Get-ArticleText {
    param([string]$url)
    if (-not $url) { return '' }
    $realUrl = Resolve-GoogleNewsUrl $url
    if ($realUrl -match 'news\.google\.com') { return '' }  # 無法解析就放棄
    try {
        $resp = Invoke-WebRequest -Uri $realUrl -UseBasicParsing -TimeoutSec 10 `
                -UserAgent 'Mozilla/5.0' -MaximumRedirection 10 -ErrorAction Stop
        $html = $resp.Content
        # 去除 script/style
        $html = [regex]::Replace($html, '(?is)<script[\s\S]*?</script>', ' ')
        $html = [regex]::Replace($html, '(?is)<style[\s\S]*?</style>', ' ')
        $html = [regex]::Replace($html, '(?is)<noscript[\s\S]*?</noscript>', ' ')
        # 抽 <p> 段落
        $paragraphs = [regex]::Matches($html, '(?is)<p[^>]*>([\s\S]*?)</p>')
        $sb = New-Object System.Text.StringBuilder
        foreach ($m in $paragraphs) {
            $p = Strip-Html $m.Groups[1].Value
            if ($p.Length -lt 60) { continue }
            if ($p -match '(?i)cookie|subscribe|sign\s*up|newsletter|privacy policy') { continue }
            if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
            [void]$sb.Append($p)
            if ($sb.Length -gt 800) { break }
        }
        return $sb.ToString().Trim()
    } catch {
        return ''
    }
}

# 從 RSS 條目抽圖（多重備援）
function Get-ImageFromItem {
    param($xmlItem, [string]$descRaw)
    if ($null -eq $xmlItem) { return '' }

    foreach ($c in $xmlItem.ChildNodes) {
        $ln = $c.LocalName
        if ($ln -eq 'thumbnail' -or $ln -eq 'content') {
            $url    = $c.GetAttribute('url')
            $medium = $c.GetAttribute('medium')
            if ($url -and ($medium -eq 'image' -or $url -match '\.(jpe?g|png|webp|gif)(\?|$)')) {
                return $url
            }
        }
        elseif ($ln -eq 'enclosure') {
            $url  = $c.GetAttribute('url')
            $type = $c.GetAttribute('type')
            if ($url -and (-not $type -or $type -like 'image/*')) { return $url }
        }
        elseif ($ln -eq 'link') {
            $rel  = $c.GetAttribute('rel')
            $type = $c.GetAttribute('type')
            $href = $c.GetAttribute('href')
            if ($href -and $rel -eq 'enclosure' -and $type -like 'image/*') { return $href }
        }
        elseif ($ln -eq 'group') {
            foreach ($cc in $c.ChildNodes) {
                if ($cc.LocalName -eq 'content' -or $cc.LocalName -eq 'thumbnail') {
                    $url = $cc.GetAttribute('url')
                    if ($url) { return $url }
                }
            }
        }
    }

    if ($descRaw) {
        $m = [regex]::Match($descRaw, '<img[^>]+src=["'']([^"''>\s]+)', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

function Get-RssItems {
    param($Source)
    $out = @()
    try {
        $resp = Invoke-WebRequest -Uri $Source.Url -UseBasicParsing -TimeoutSec 20 -UserAgent 'Mozilla/5.0 (GlobalBrief)'
        [xml]$xml = $resp.Content

        $entries = @()
        if     ($xml.rss.channel.item) { $entries = @($xml.rss.channel.item) }
        elseif ($xml.RDF.item)         { $entries = @($xml.RDF.item) }
        elseif ($xml.feed.entry)       { $entries = @($xml.feed.entry) }

        foreach ($i in $entries) {
            # 任何 XmlElement 都取 InnerText，避免 [string] 變成 "System.Xml.XmlElement"
            $getText = {
                param($n)
                if ($null -eq $n) { return '' }
                if ($n -is [System.Xml.XmlElement]) { return $n.InnerText }
                return [string]$n
            }

            $title = (& $getText $i.title).Trim()

            # Link
            $link = ''
            if ($i.link -is [array]) {
                if ($i.link[0].href) { $link = [string]$i.link[0].href } else { $link = & $getText $i.link[0] }
            } elseif ($i.link.href) {
                $link = [string]$i.link.href
            } else {
                $link = & $getText $i.link
            }

            # Raw description（給抽圖用）
            $descRaw = ''
            if     ($i.description) { $descRaw = & $getText $i.description }
            elseif ($i.summary)     { $descRaw = & $getText $i.summary }
            elseif ($i.content)     { $descRaw = & $getText $i.content }

            # Pub
            $pub = ''
            if     ($i.pubDate)    { $pub = & $getText $i.pubDate }
            elseif ($i.date)       { $pub = & $getText $i.date }
            elseif ($i.published)  { $pub = & $getText $i.published }
            elseif ($i.updated)    { $pub = & $getText $i.updated }

            # Image
            $img = Get-ImageFromItem -xmlItem $i -descRaw $descRaw

            $out += @{
                Title = $title
                Desc  = Strip-Html $descRaw
                Link  = $link
                Pub   = $pub
                Image = $img
            }
        }
        $withImg = @($out | Where-Object { $_.Image }).Count
        Write-Host ("  {0,-18} {1,3} 則  (含圖 {2})" -f $Source.Name, $out.Count, $withImg)
    } catch {
        Write-Host ("  {0,-18} [跳過] {1}" -f $Source.Name, $_.Exception.Message) -ForegroundColor Yellow
    }
    return $out
}

# ---------- 5. 主流程 ----------
Write-Host "`n=== 國際大事件 · 過去 24 小時 ===`n" -ForegroundColor Cyan
# 只在本機執行時才設定啟動捷徑／排程（Actions 雲端環境跳過）
if (-not $env:GITHUB_ACTIONS) {
    Install-StartupShortcut
    Install-DailyTask
} else {
    Write-Host '[環境] GitHub Actions — 略過本機排程設定' -ForegroundColor DarkGray
}

Write-Host "`n抓取 RSS…"
# URL 域名黑名單（電商／產品站／付費牆）— 先在這邊定義，後續所有 panel 都能用
$BadDomains = @(
    # 電商
    'amazon\.', 'ebay\.', 'walmart\.', 'aliexpress\.', 'alibaba\.',
    'etsy\.', 'shopee\.', 'lazada\.', 'wish\.com',
    'aplusme', 'bikesdirect\.', 'competitivecyclist',
    'backcountry\.', 'rei\.com', 'dickssportinggoods',
    'monoprice\.', 'vevor\.', 'temu\.',
    'gsm\w*arena', 'notebookcheck\.',
    # 付費牆
    'nytimes\.com', 'wsj\.com', 'washingtonpost\.com', 'ft\.com',
    'bloomberg\.com', 'economist\.com', 'barrons\.com',
    'businessinsider\.com', 'theinformation\.com',
    'thetimes\.co\.uk', 'telegraph\.co\.uk', 'spectator\.co\.uk',
    'investors\.com', 'marketwatch\.com',
    'nikkei\.com', 'asahi\.com', 'mainichi\.jp', 'yomiuri\.co\.jp',
    'theatlantic\.com', 'newyorker\.com', 'vanityfair\.com',
    'bostonglobe\.com', 'latimes\.com',
    'seekingalpha\.com', 'morningstar\.com',
    'afr\.com', 'smh\.com\.au'
)

$all = New-Object System.Collections.Generic.List[object]
foreach ($src in $Sources) {
    $items = Get-RssItems $src
    foreach ($it in $items) {
        $pub = Parse-Date $it.Pub
        if ($pub -and ((Get-Date).ToUniversalTime() - $pub).TotalHours -gt 24) { continue }
        # 過濾付費牆與電商
        $skipDomain = $false
        foreach ($d in $BadDomains) {
            if ($it.Link -imatch $d) { $skipDomain = $true; break }
        }
        if ($skipDomain) { continue }
        $desc = $it.Desc
        # 截至 600 英文字，翻譯後約 400–500 中文字，內容完整清晰
        if ($desc.Length -gt 600) { $desc = $desc.Substring(0, 600).TrimEnd() + '…' }
        $score = Get-Score -Title $it.Title -Desc $desc -Weight $src.Weight -Pub $pub
        $all.Add([pscustomobject]@{
            Source = $src.Name
            Lang   = $src.Lang
            Title  = $it.Title
            Desc   = $desc
            Link   = $it.Link
            Pub    = $pub
            Score  = $score
            Image  = $it.Image
        })
    }
}

Write-Host ("`n合計 {0} 則（24h 內）" -f $all.Count)
if ($all.Count -eq 0) {
    Write-Host '沒抓到任何新聞，檢查網路連線。' -ForegroundColor Red
    exit 1
}

# 依 URL 去重
$byUrl = $all | Group-Object Link | ForEach-Object {
    $_.Group | Sort-Object Score -Descending | Select-Object -First 1
}

# 依標題相似度去重，挑前 20
$sorted = $byUrl | Sort-Object Score -Descending
$picked = New-Object System.Collections.Generic.List[object]
$keys   = New-Object System.Collections.Generic.List[object]

$conflictCount = 0
$MaxConflict   = 5   # 衝突類最多 5 則，避免戰爭新聞壟斷
foreach ($item in $sorted) {
    if ($picked.Count -ge 20) { break }
    $cat = Get-Category $item.Title $item.Desc
    if ($cat -eq 'Conflict' -and $conflictCount -ge $MaxConflict) { continue }
    $k = Get-TitleKey $item.Title
    $dup = $false
    foreach ($seen in $keys) { if (Is-Similar $k $seen) { $dup = $true; break } }
    if (-not $dup) {
        $item | Add-Member -MemberType NoteProperty -Name Category -Value $cat -Force
        $picked.Add($item); $keys.Add($k)
        if ($cat -eq 'Conflict') { $conflictCount++ }
    }
}

foreach ($p in $picked) {
    $p | Add-Member -MemberType NoteProperty -Name Category -Value (Get-Category $p.Title $p.Desc) -Force
}

Write-Host ("挑出 {0} 則頭條（含圖 {1}）" -f $picked.Count, @($picked | Where-Object { $_.Image }).Count)

# ---------- 5a. 碳纖維產業新聞（右側面板用）----------
Write-Host "`n抓取碳纖維產業 RSS…"
$carbonAll = New-Object System.Collections.Generic.List[object]
foreach ($src in $CarbonSources) {
    $items = Get-RssItems $src
    foreach ($it in $items) {
        $pub = Parse-Date $it.Pub
        if ($pub -and ((Get-Date).ToUniversalTime() - $pub).TotalDays -gt 30) { continue }
        # 黑名單：電商商品／消費品
        $skip = $false
        foreach ($pat in $CarbonBlacklist) {
            if ($it.Title -match $pat) { $skip = $true; break }
        }
        if ($skip) { continue }
        # 關聯性：必須跟碳纖維有關（避免 JEC 的玻纖/天然纖維稿）
        $relevance = ($it.Title + ' ' + $it.Desc).ToLower()
        if ($relevance -notmatch 'carbon|cfrp|pan\s|prepreg|precursor|hexcel|toray|teijin|sgl|mitsubishi chemical|碳纖|碳纤') { continue }
        $desc = $it.Desc
        if ($desc.Length -gt 400) { $desc = $desc.Substring(0, 400).TrimEnd() + '…' }
        $carbonAll.Add([pscustomobject]@{
            Source = $src.Name
            Lang   = $src.Lang
            Title  = $it.Title
            Desc   = $desc
            Link   = $it.Link
            Pub    = $pub
            Image  = $it.Image
            Weight = $src.Weight
        })
    }
}

# 去重＋挑最新 10 則（避開 Sort-Object 對 null 的型別錯誤）
$carbonPicked = @()
try {
    if ($carbonAll.Count -gt 0) {
        # 先以 URL 去重
        $seenLinks = @{}
        $unique = New-Object System.Collections.Generic.List[object]
        foreach ($it in $carbonAll) {
            if (-not $it.Link) { continue }
            if (-not $seenLinks.ContainsKey($it.Link)) {
                $seenLinks[$it.Link] = $true
                $unique.Add($it)
            }
        }
        # 只留有日期的，依日期新到舊
        $withDate = @($unique | Where-Object { $_.Pub -is [datetime] })
        # 排序分數 = Weight × 2 + 近期度（過去 30 天 0–1），讓直接 RSS（權重高）優先
        $csorted = $withDate | Sort-Object -Property @{
            Expression = {
                $ageDays = ((Get-Date).ToUniversalTime() - $_.Pub).TotalDays
                $recency = [math]::Max(0, 30 - $ageDays) / 30
                ($_.Weight * 2) + $recency
            }
        } -Descending
        # 標題相似度去重
        $cPickedList = New-Object System.Collections.Generic.List[object]
        $cKeys = New-Object System.Collections.Generic.List[object]
        foreach ($item in $csorted) {
            if ($cPickedList.Count -ge 10) { break }
            $k = Get-TitleKey $item.Title
            $dup = $false
            foreach ($seen in $cKeys) { if (Is-Similar $k $seen) { $dup = $true; break } }
            if (-not $dup) { $cPickedList.Add($item); $cKeys.Add($k) }
        }
        $carbonPicked = @($cPickedList.ToArray())
    }
} catch {
    Write-Host "  [warn] 碳纖維新聞整理失敗: $($_.Exception.Message)" -ForegroundColor Yellow
    $carbonPicked = @()
}
Write-Host ("  → 挑出 {0} 則碳纖維新聞" -f $carbonPicked.Count)

# 產品／廣告／評論性內容黑名單（副面板共用）
$SecondarySpamPatterns = @(
    # 電商／購物
    'amazon\.com', 'ebay', 'walmart', 'aliexpress', 'alibaba', 'shopify',
    'for sale\b', 'in stock', 'on sale', 'pre-?order', 'ships?\s+(?:free|fast)',
    'buy\s+(?:now|online|it)', 'shop\s+(?:now|online)', 'add to cart',
    '\$\d+', '\bUSD\s*\d', 'pricing', 'price\s+(?:drop|alert|list)',
    'deal\b', 'discount', 'coupon', 'promo\b', 'sale\s*(?:ends|price|event)',
    'limited\s+(?:edition|offer|time)', 'new arrival', 'now available',
    'get\s+yours', 'where to buy', 'checkout', 'cart\b',
    # 評論／清單／購物指南（非正式新聞）
    'best\s+\d+', 'top\s+\d+', '\d+\s+best\b', 'reviewed\b', 'review[:.]?\s',
    'buying guide', 'shopping guide', 'comparison', ' vs\.? ', 'versus',
    'alternatives\b', 'how to choose', 'our pick', 'editors? pick',
    'tested\s+(?:and|&amp;)\s+reviewed', 'hands-on', 'first look', 'unboxing',
    # 具體產品型號／規格描述（通常是銷售頁）
    '\d+\s*mm\s*(?:OD|ID)', 'OD\s*[xX×]', 'ID\s*[xX×]',
    '\d+/\d+"', '\d+(?:\.\d+)?\s*(?:mm|cm|inch|in|lb|lbs|kg|oz)\b.*\d',
    # 消費品／服飾／戶外裝備（非正式報導）
    'armored\b', 'motorcycle jacket', 'biker pant', 'hiking pant', 'cycling jersey',
    '\bgloves?\b', '\bboots?\b', '\btent\b', '\btarp\b', '\bsling\b', '\brope\b', '\bcord\b',
    'hammock', 'backpack\b', 'luggage', 'handbag', 'duffel',
    # 消費電子配件
    'phone case', 'laptop case', 'watch band', 'watch strap', 'keychain',
    'knife handle', 'wallet', 'vape\b', '\bfishing\b', 'binoculars',
    # 店家／品牌型產品（常見銷售稿來源）
    'samson amsteel', 'salewa', 'bikers gear', 'profirst', 'vevor\b', 'monoprice\b',
    # 色號／尺碼／型號常見詞
    'color\s*:\s*\w+\s*/\s*\w+', 'size\s*[:：]?\s*[SMLX]\b',
    # 廣編／業配訊號
    'sponsored\b', 'promoted\b', 'paid\s+content', 'affiliate\b',
    'giveaway', 'contest\b', 'sweepstakes',
    # 精選清單／推薦文（非市場新聞）
    '\bthe\s+best\b', '\bbest\s+\w+\s+(?:shoes?|boots?|bikes?|rackets?|running|runner|gear|helmets?)',
    'our\s+favorite', 'our\s+top', 'round-?up',
    '\d+\s+(?:of\s+)?the\s+best', '\d+\s+best\b', 'best\s+of\s+the\s+best',
    # 評測／體驗文
    'tested\b', 'hands-on\b', 'in-depth\b', 'first\s+look\b',
    '\breview(?:ed|s|ing)?\b(?!\s+board)', # 允許 review board
    # 訓練／教學／How-to
    'training\s+(?:plan|tips|guide|program)', '\bworkout\b', 'how\s+to\s+\w',
    'tips\s+for', 'tutorial', "beginner'?s?\s+guide", 'a\s+guide\s+to',
    # 推銷語氣（過度 hype）
    'check\s+out\s+the', 'must-have\b', 'you\s+must\s+own',
    # 比較
    '\bvs\.?\s', '\bversus\s',
    # 跟我們產業無關的「纖維」意義（膳食纖維、光纖武器等）
    'dietary\s+fiber', 'fiber\s+supplement', 'gut\s+health',
    'optic(?:al)?\s+fiber\s+(?:drone|weapon|missile|bomb)',
    'fiber[-\s]optic(?:al)?\s+(?:drone|weapon|missile|bomb|strike)',
    '光纖\s*(?:無人機|武器|飛彈|炸彈)',
    '(?:lit|dark)\s+fiber\s+(?:market|network)',  # 光纖網路不同產業
    '\bchenille\b',  # 雪尼爾布（家飾紡織，非工業纖維）
    'textile-?to-?textile', '\bdenim\b',  # 時尚循環紡織（非本業）
    # 產品型號與規格（銷售頁常見）
    'for\s+(?:Toyota|Honda|Ford|BMW|Mercedes|Benz|Audi|VW|Nissan|Tesla|Hyundai|Kia|Mazda|Subaru|Porsche)\s+\w+', # "for Toyota RAV4"
    '\d+\s*-?speed\b', # "18-speed"
    '\bABS\s*材質', '\bABS\s+material',
    'Shimano\s+(?:SORA|Tiagra|105|Ultegra|Dura-Ace)', # Shimano gear groupsets = product spec
    'SRAM\s+(?:Red|Force|Rival|Apex|Eagle|GX|XX)',
    'T\d{3,4}\s+(?:Carbon\s+)?Frame\b', # "T800 Carbon Frame"
    '\b(?:UD|3K|12K)\s+(?:Carbon|Matte|Gloss)', # "3K Carbon Matte"
    'matte\s+finish', 'gloss\s+finish',
    # 汽車／自行車改裝貼片／配件（產品頁常見）
    '(?:interior|exterior|dash|door|trim)\s+(?:cover|panel|accessor)',
    'body\s+kit', 'spoiler', 'fender\s+flare'
)

# 市場新聞訊號（副面板必須含至少一個）
$MarketSignalPatterns = @(
    # 企業正式動作
    'launch(?:es|ed|ing)?', 'announc(?:e|es|ed|ement)',
    'unveil(?:s|ed|ing)?', 'introduc(?:e|es|ed|ing)',
    'reveal(?:s|ed|ing)?', 'debut(?:s|ed|ing)?',
    'roll(?:s|ed|ing)?\s+out',
    'deploy(?:s|ed|ing|ment)', 'open(?:s|ed|ing)?\s+(?:new|plant|factory)',
    'expand(?:s|ed|ing|ion)\b', 'grow(?:s|ing|th)\s+(?:into|to|in)',
    'enter(?:s|ed|ing)\s+(?:new|the)', 'first-ever\b',
    # 合作／投資／併購
    'partner(?:ship|ed|s\s+with)', 'collaborat(?:e|es|ed|ion)\s+with',
    'joint\s+venture', 'acquir(?:e|es|ed|ition)', 'merger\b',
    'invest(?:s|ed|ment)', 'fund(?:s|ed|ing)',
    'agreement', 'contract(?:ed|s|ual)?', 'signed\s+(?:deal|agreement|contract)',
    # 市場數據／報告
    'market\s+(?:size|share|growth|report|forecast|analysis|to\s+reach|projected|expected|trend|outlook)',
    'industry\s+(?:report|trend|news|growth|size|analysis|forecast|outlook)',
    'global\s+\w+\s+market', 'market\s+research',
    'revenue\b', 'earnings\b', 'profit\b', 'quarterly\s+(?:revenue|earnings|results)',
    'Q[1-4]\s+(?:revenue|earnings|report|results)',
    # 研發／產線／產能
    'breakthrough', 'patent(?:ed|s)?', 'certifi(?:ed|cation)',
    'new\s+(?:material|technology|process|plant|factory|production\s+line|product\s+line|model|design|generation)',
    'manufactur(?:e|er|ers|ing)', 'suppl(?:y|ier|ied|ying)',
    'distribut(?:or|ion)', 'production\s+(?:line|capacity|plant|facility)',
    'mass\s+production', 'scale-up', 'scaling', 'ramp(?:ing|s)?\s+up',
    # 產業特寫／工廠故事／供應鏈報導（合法產業新聞）
    'inside\s+(?:the|\w+''?s)', 'behind\s+the', 'how\s+\w+\s+(?:builds|makes|produces)',
    'factory\s+tour', 'plant\s+tour', 'facility\s+(?:tour|visit)',
    '(?:features|powered\s+by|built\s+with)\s+(?:\w+\s+)?(?:carbon|composite|CFRP|aramid|Kevlar|UHMWPE|Dyneema|fiber)',
    'first\s+(?:commercial|production|composite|carbon|all-composite)',
    'key\s+supplier', 'critical\s+(?:supplier|material|component)',
    'next\s+generation', 'all[-\s]composite', 'all[-\s]carbon',
    # 法規／訂單
    'approv(?:ed|al|es)', 'FDA\b', 'EASA\b', 'FAA\b',
    'order(?:s|ed|ing)?\s+(?:for|from)', 'contract\s+award',
    # 中文
    '推出', '發布', '發表', '宣布', '亮相', '首發', '首款', '上市', '發售',
    '研發', '突破', '專利', '認證', '量產', '投產', '產能', '新廠', '新材料',
    '合作', '簽約', '投資', '併購', '收購', '入股', '募資', '協議',
    '市場', '產業', '財報', '營收', '獲利', '訂單',
    '新工廠', '新產線', '產線', '生產線'
)

# 消費市場產品訊號（複材應用面板用）— 聚焦終端消費者產品
$ConsumerProductPatterns = @(
    # 產品發表／上市
    'launch(?:es|ed|ing)?', 'announc(?:e|es|ed|ement)', 'unveil(?:s|ed|ing)?',
    'introduc(?:e|es|ed|ing)', 'reveal(?:s|ed|ing)?', 'debut(?:s|ed|ing)?',
    'release(?:s|ed|ing)?', 'drop(?:s|ped|ping)?\s+(?:new|the|its)',
    'present(?:s|ed|ing)', 'rolls?\s+out', 'coming\s+(?:soon|to)',
    # 新產品名詞
    'new\s+(?:shoe|shoes|bike|bikes|racket|rackets|racquet|watch|watches|bat|bats|stick|sticks|helmet|helmets|board|boards|ski|skis|snowboard|club|paddle|paddles|model|models|collection|edition|lineup|series|generation|line)',
    'latest\s+(?:shoe|bike|racket|watch|model|collection|edition|helmet|board|line|series)',
    'first[-\s](?:carbon|composite|all-carbon|all-composite|ever)',
    'next[-\s]gen(?:eration)?',
    # 限量／紀念／簽名（合法消費者新聞）
    'limited\s+edition', 'anniversary\s+(?:edition|release|collection|model)',
    'tribute\s+(?:to|collection|edition|model)', 'commemorat',
    'special\s+edition', 'signature\s+(?:edition|series|model|collection)',
    'reimagined\b', 'celebrates?\s+\d+\s+years',
    # 職業選手／賽事使用
    '(?:wore|wearing|worn\s+by|uses|used\s+by|debut(?:ed|s)?\s+at|raced\s+(?:with|in)|won\s+(?:with|in|the))',
    'Olympic(?:s)?', 'Olympian', 'Tour\s+de\s+France', 'world\s+championship', 'championship',
    'pro\s+(?:tour|rider|player|athlete)', 'ATP\b', 'WTA\b', 'PGA\b', 'NHL\b', 'NBA\b', 'MLB\b',
    'Grand\s+Slam', 'marathon\s+(?:winner|record|world)',
    'record-breaking', 'world\s+record', 'sets?\s+(?:a\s+)?record', 'breaks?\s+(?:a\s+)?record',
    # 合作／代言
    'partner(?:ship|s\s+with|ed\s+with)', 'collaborat(?:e|es|ed|ion)\s+with',
    'endors(?:e|ed|ement)', 'team\s+up\s+with', 'signed\s+deal',
    # 關鍵品牌（出現即為消費者品牌新聞）
    '\bNike\b', '\bAdidas\b', '\bPuma\b', '\bAsics\b', '\bHoka\b', '\bBrooks\b', '\bNew\s+Balance\b',
    '\bUnder\s+Armour\b', '\bOn\s+Running\b', '\bSaucony\b', '\bReebok\b',
    '\bTrek\b', '\bSpecialized\b', '\bCannondale\b', '\bPinarello\b', '\bCervelo\b', '\bGiant\b', '\bCanyon\b',
    '\bWilson\b', '\bHead\b(?:\s+racket|\s+tennis)', '\bYonex\b', '\bBabolat\b', '\bPrince\b',
    '\bBauer\b', '\bCCM\b', '\bTRUE\b', '\bWarrior\b',  # hockey
    '\bCallaway\b', '\bTaylorMade\b', '\bTitleist\b', '\bPing\b',  # golf
    '\bCasio\b', '\bG-Shock\b', '\bGarmin\b', '\bFitbit\b', '\bSuunto\b',
    '\bLouis\s+Vuitton\b', '\bLV\b',
    '\bBMW\b', '\bMercedes\b', '\bAudi\b', '\bPorsche\b', '\bFerrari\b', '\bLamborghini\b',
    '\bMcLaren\b', '\bTesla\b', '\bToyota\b', '\bHonda\b',
    '\bApple\b', '\bSamsung\b', '\bLenovo\b', '\bDell\b', '\bHP\b', '\bAsus\b',
    # 中文消費者新聞
    '推出', '發布', '發表', '宣布', '亮相', '首發', '首款', '上市', '發售',
    '新品', '新款', '新車', '新鞋', '新錶', '新機', '新車型',
    '限量', '紀念版', '簽名款', '合作款', '特別版', '聯名',
    '奧運', '冠軍', '紀錄', '職業', '選手', '穿著', '搭配', '騎乘',
    '合作', '簽約', '代言',
    '卡西歐', '耐吉', '愛迪達', '特斯拉', '寶馬'
)

# 技術層面訊號（複材技術面板專用，需含技術／工藝／材料／研發語言）
$TechOnlySignals = @(
    # 製程／工藝
    'automated\s+fiber\s+placement', '\bAFP\b', 'automated\s+tape\s+laying', '\bATL\b',
    'resin\s+transfer\s+molding', '\bRTM\b', 'VARTM', 'resin\s+infusion',
    'prepreg\b', 'preform\b', 'filament\s+winding', 'pultru(?:sion|ded)',
    'autoclave', 'out-of-autoclave', 'OOA\b', 'vacuum\s+bag',
    'cur(?:e|es|ed|ing)\s+(?:cycle|process|system|technology)', 'snap-?cure', 'fast-?cure', 'UV\s+cure', 'oven\s+cure',
    'molding\s+(?:process|technology|compound)', 'compression\s+molding', 'injection\s+molding',
    'layup\b', 'lamina(?:te|tion)', 'ply\s+(?:drop|layup|stack)',
    'braid(?:ing|ed)', 'weave\s+(?:pattern|design)', 'woven\s+(?:fabric|composite)', 'non-crimp\s+fabric', '\bNCF\b',
    # 材料／配方
    'resin\s+(?:formulation|chemistry|system|matrix)', 'epoxy\s+(?:resin|system|formulation)',
    'thermoplastic\s+(?:composite|matrix|resin)', 'thermoset\s+(?:composite|matrix|resin)',
    'PEEK\b', 'PEKK\b', 'PPS\b', 'PAEK\b', 'polyetheretherketone',
    '\b(?:bio-?based|biocomposite|natural\s+fiber)\b', 'sustainable\s+(?:composite|resin|matrix)',
    'matrix\s+(?:material|system)', 'fiber\s+sizing', 'interphase', 'fiber-matrix',
    'nanotub(?:e|es)', 'nanoparticle', 'nanocomposite', 'graphene', 'carbon\s+nanotube', '\bCNT\b',
    'recycl(?:e|ed|ing)\s+(?:carbon|composite|fiber)', 'pyrolysis', 'solvolysis', 'chemical\s+recycling',
    # 機械性能／特性
    'tensile\s+(?:strength|modulus|property)', 'compressive\s+(?:strength|property)',
    'flexural\s+(?:strength|modulus)', 'shear\s+(?:strength|modulus)', 'impact\s+(?:strength|resistance)',
    'fatigue\s+(?:life|testing|resistance)', 'fracture\s+(?:toughness|behavior)',
    'stiffness', 'modulus\b', 'Young''?s\s+modulus', 'damage\s+tolerance', 'delamination',
    'mechanical\s+(?:properties|performance|testing)', 'thermal\s+(?:properties|stability|conductivity)',
    # 研發／學術／模擬
    'research(?:er|ers)?\s+(?:at|from|team|group|develop|show)',
    'stud(?:y|ies)\s+(?:finds|shows|demonstrates|reveals)',
    'publish(?:ed)?\s+in\s+(?:journal|nature|science)', 'peer-reviewed',
    'universit(?:y|ies)\s+(?:of|research)', '\binstitute\b', 'laborator(?:y|ies)',
    'PhD\b', 'professor\b', 'scientist(?:s)?\b',
    'finite\s+element\s+(?:analysis|method)', '\bFEA\b', 'FEM\b',
    'simulation', 'modeling', 'digital\s+twin', 'machine\s+learning', '\bAI-driven',
    # 檢測／分析
    'testing\s+(?:method|technique|protocol)', 'characteri[sz]ation',
    'microscop(?:y|ic)', 'scanning\s+electron', '\bSEM\b', 'X-ray\s+(?:CT|tomography|diffraction)',
    'spectroscop(?:y|ic)', '\bFTIR\b', 'ultrasound', 'non-destructive\s+(?:testing|evaluation)', '\bNDT\b',
    'defect\s+detection',
    # 突破／改良語言
    'breakthrough', 'novel\s+(?:material|process|technique|approach|method)',
    '(?:improve|enhance|boost|increase|reduce)(?:s|d|ing)?\s+(?:strength|stiffness|toughness|performance|cure|cycle)',
    'patent(?:ed|s)?\s+(?:technology|process|material)', 'first[-\s]of[-\s]its[-\s]kind',
    # 3D 列印／積層
    '3D[-\s]print(?:ed|ing)', 'additive\s+manufactur(?:e|ing)', 'FDM\b', 'FFF\b', 'stereolithography',
    # 中文技術語言
    '工藝', '製程', '成型', '固化', '熱壓罐', '真空袋', '預浸料', '樹脂灌注',
    '熱塑性', '熱固性', '纖維上漿', '界面', '基體',
    '奈米', '石墨烯', '碳奈米管', '回收技術', '裂解',
    '抗拉強度', '剛性', '韌性', '疲勞', '衝擊',
    '模擬', '有限元素', '機器學習',
    '研究團隊', '學者', '實驗', '論文', '期刊', '突破', '新技術', '新工藝', '專利技術',
    '層壓', '鋪層', '編織', '纖維束'
)

# BadDomains 已移到主流程前定義

# 正式新聞訊號（標題或描述必須至少含一個）
$NewsworthyPatterns = @(
    # 動作詞
    'launch(?:es|ed|ing)?', 'announc(?:e|es|ed|ement)', 'unveil(?:s|ed|ing)?',
    'introduc(?:e|es|ed|ing)', 'develop(?:s|ed|ing|ment)', 'reveal(?:s|ed)',
    'debut(?:s|ed)?', 'roll(?:s|ed)?\s+out', 'deliver(?:s|ed|ing|y)',
    # 合作／投資
    'partner(?:ship|s|ed)?', 'collaborat(?:e|es|ed|ion)', 'joint venture', 'acquir(?:e|es|ed|ition)',
    'invest(?:s|ed|ment|or)?', 'fund(?:s|ed|ing)?', 'agreement', 'contract(?:ed|s)?', 'deal\s+with',
    # 研發／學術
    'research(?:er|ers)?', 'stud(?:y|ies|ied)', 'breakthrough', 'innovat(?:e|ion|ive)',
    'patent(?:ed|s)?', 'certifi(?:ed|cation)', 'approv(?:ed|al)',
    'universit(?:y|ies)', 'institute\b', 'laborator(?:y|ies)', 'MIT\b', 'NASA\b',
    # 產業／市場
    'new\s+(?:material|technology|process|plant|factory|product|model)', 'first-ever', 'world-first',
    'market\s+(?:growth|share|report|forecast|to\s+reach|trend|size)', 'industry\s+(?:report|trend|news)',
    'manufactur(?:e|er|ers|ing)', 'suppl(?:y|ier|ied|ying)', 'produc(?:e|ed|er|ers|tion)',
    'compan(?:y|ies)', 'corporation', 'startup\b', 'CEO\b', 'executive\b', 'founder\b',
    # 領域／場域
    'aerospace\b', 'aviation\b', 'automotive\b', 'bicycle\s+industry', 'cycling\s+industry',
    'marine\s+industry', 'boat\s+industry', 'medical\s+device', 'healthcare',
    'hospital', 'clinical', 'prosthetic', 'implant', 'surgical',
    'racing', 'formula\s+1', 'f1\b', 'motorsport', 'moto-?gp', 'tour\s+de\s+france',
    'olympic', 'championship', 'record-breaking', 'world\s+record',
    # 大品牌／關鍵業者
    'Toyota', 'Honda', 'Ford', 'BMW', 'Mercedes', 'Audi', 'Porsche', 'Ferrari', 'Lamborghini',
    'Tesla', 'BYD', 'Volkswagen', 'Nissan', 'Hyundai',
    'Boeing', 'Airbus', 'Bombardier', 'Embraer', 'Dassault', 'Lockheed',
    'SpaceX', 'Blue Origin', 'Rocket Lab',
    'Nike', 'Adidas', 'Puma', 'New Balance', 'Asics', 'Under Armour', 'Hoka', 'Brooks',
    'Specialized', 'Trek\s+Bicycle', 'Cannondale', 'Giant\s+Bicycle', 'Pinarello',
    'Toray', 'Hexcel', 'Teijin', 'Solvay', 'Syensqo', 'SGL', 'Mitsubishi Chemical', 'DuPont',
    'Samsung', 'Apple', 'Sony', 'LG\b', 'Lenovo', 'Dell\b', 'HP\b', 'Asus',
    # 中文
    '推出', '發布', '發表', '宣布', '亮相', '首發', '首款', '發售', '上市',
    '研發', '研究', '研製', '創新', '突破', '專利', '認證', '核准',
    '合作', '簽約', '投資', '併購', '收購', '入股', '募資', '協議',
    '公司', '廠商', '企業', '集團', '產業', '市場', '報告', '預測',
    '量產', '投產', '產能', '新廠', '新材料', '新技術', '新產品',
    '航空', '航太', '汽車', '醫療', '賽事', '奧運', '冠軍', '紀錄'
)

# ---------- 5a2. 複材應用 + 超級纖維 ----------
function Get-SecondaryPanel {
    param($sources, [int]$maxItems, [int]$days, [int]$descCap, [array]$requireSignals)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($src in $sources) {
        $items = Get-RssItems $src
        foreach ($it in $items) {
            $pub = Parse-Date $it.Pub
            if ($pub -and ((Get-Date).ToUniversalTime() - $pub).TotalDays -gt $days) { continue }
            # 過濾：URL 域名／來源名 黑名單
            $skip = $false
            foreach ($d in $BadDomains) {
                if ($it.Link -imatch $d) { $skip = $true; break }
            }
            if ($skip) { continue }
            # Google News item 的來源名常出現在描述文字尾端
            $srcCheck = "$($it.Title) $($it.Desc)"
            foreach ($d in @('A Plus Me','Monoprice','VEVOR','Temu','Lazada','Shopee','aliexpress')) {
                if ($srcCheck -imatch [regex]::Escape($d)) { $skip = $true; break }
            }
            if ($skip) { continue }
            # 過濾：標題／描述產品垃圾
            $spamCheck = "$($it.Title) $($it.Desc)"
            foreach ($pat in $SecondarySpamPatterns) {
                if ($spamCheck -imatch $pat) { $skip = $true; break }
            }
            if ($skip) { continue }
            # 必須含至少一個指定訊號（由呼叫者決定是市場訊號或消費產品訊號）
            $signals = if ($requireSignals) { $requireSignals } else { $MarketSignalPatterns }
            $hasSignal = $false
            foreach ($mp in $signals) {
                if ($spamCheck -imatch $mp) { $hasSignal = $true; break }
            }
            if (-not $hasSignal) { continue }
            $desc = $it.Desc
            if ($desc.Length -gt $descCap) { $desc = $desc.Substring(0, $descCap).TrimEnd() + '…' }
            $all.Add([pscustomobject]@{
                Source = $src.Name; Lang = $src.Lang; Title = $it.Title
                Desc = $desc; Link = $it.Link; Pub = $pub; Image = $it.Image
                Weight = $src.Weight
            })
        }
    }
    if ($all.Count -eq 0) { return ,@() }
    $unique = @($all | Group-Object Link | ForEach-Object { $_.Group | Select-Object -First 1 })
    # 排序：直接 RSS（Weight 高）優先 + 近期度
    $sorted = @($unique | Where-Object { $_.Pub -is [datetime] } | Sort-Object -Property @{
        Expression = {
            $ageDays = ((Get-Date).ToUniversalTime() - $_.Pub).TotalDays
            $recency = [math]::Max(0, 60 - $ageDays) / 60
            ($_.Weight * 3) + $recency
        }
    } -Descending)

    $picked = New-Object System.Collections.Generic.List[object]
    $keys   = New-Object System.Collections.Generic.List[object]
    $errCount = 0
    foreach ($item in $sorted) {
        if ($picked.Count -ge $maxItems) { break }
        try {
            $k = Get-TitleKey $item.Title
            $dup = $false
            foreach ($seen in $keys) { if (Is-Similar $k $seen) { $dup = $true; break } }
            if (-not $dup) { $picked.Add($item); $keys.Add($k) }
        } catch {
            $errCount++
            if ($errCount -le 2) { Write-Host ("    ERR: $_") -ForegroundColor Red }
        }
    }
    if ($errCount -gt 0) { Write-Host ("    （{0} 則處理錯誤略過）" -f $errCount) -ForegroundColor Yellow }
    # unary comma 防止 PowerShell 展開陣列
    return ,$picked.ToArray()
}

Write-Host "`n抓取碳纖製造商 RSS…"
# 不限數量，把所有通過過濾的製造商新聞全收
$mfgPicked = Get-SecondaryPanel -sources $ManufacturerSources -maxItems 100 -days 90 -descCap 180 -requireSignals $MarketSignalPatterns
Write-Host ("  → 挑出 {0} 則製造商新聞" -f $mfgPicked.Count)

Write-Host "`n抓取塑膠消息 RSS…"
$plasticPicked = Get-SecondaryPanel -sources $PlasticSources -maxItems 25 -days 90 -descCap 180 -requireSignals $MarketSignalPatterns
Write-Host ("  → 挑出 {0} 則塑膠消息" -f $plasticPicked.Count)

Write-Host "`n抓取世界金屬市場 RSS…"
$metalPicked = Get-SecondaryPanel -sources $MetalSources -maxItems 30 -days 90 -descCap 180 -requireSignals $MarketSignalPatterns
Write-Host ("  → 挑出 {0} 則金屬市場新聞" -f $metalPicked.Count)

Write-Host "`n抓取娛樂新聞 RSS…"
$funRaw = Get-SecondaryPanel -sources $EntertainmentSources -maxItems 80 -days 30 -descCap 180 -requireSignals $EntertainmentSignals
if ($funRaw.Count -gt 0) { Add-PanelImages $funRaw '來點好心情候選' }
# 只留有圖，取前 20
$funPicked = @($funRaw | Where-Object { $_.Image } | Sort-Object -Property @{Expression={ ($_.Weight * 3) + [math]::Max(0, 60 - ((Get-Date).ToUniversalTime() - $_.Pub).TotalDays) / 60 }} -Descending | Select-Object -First 20)
Write-Host ("  → 挑出 {0} 則娛樂新聞（全部含圖）" -f $funPicked.Count)

Write-Host "`n抓取美食新聞 RSS…"
$foodRaw = Get-SecondaryPanel -sources $FoodSources -maxItems 80 -days 45 -descCap 180 -requireSignals $FoodSignals
if ($foodRaw.Count -gt 0) { Add-PanelImages $foodRaw '給你的美食候選' }
$foodPicked = @($foodRaw | Where-Object { $_.Image } | Sort-Object -Property @{Expression={ ($_.Weight * 3) + [math]::Max(0, 60 - ((Get-Date).ToUniversalTime() - $_.Pub).TotalDays) / 60 }} -Descending | Select-Object -First 20)
Write-Host ("  → 挑出 {0} 則美食新聞（全部含圖）" -f $foodPicked.Count)

Write-Host "`n抓取台中咖啡好去處 RSS…"
$localFoodRaw = Get-SecondaryPanel -sources $LocalFoodSources -maxItems 80 -days 90 -descCap 180 -requireSignals $LocalFoodSignals
if ($localFoodRaw.Count -gt 0) { Add-PanelImages $localFoodRaw '台中咖啡候選' }
$localFoodWithImg = @($localFoodRaw | Where-Object { $_.Image } | Sort-Object Pub -Descending | Select-Object -First 20)
if ($localFoodWithImg.Count -lt 15) {
    $localFoodNoImg = @($localFoodRaw | Where-Object { -not $_.Image } | Sort-Object Pub -Descending | Select-Object -First (20 - $localFoodWithImg.Count))
    $localFoodPicked = @($localFoodWithImg) + @($localFoodNoImg)
} else {
    $localFoodPicked = $localFoodWithImg
}
# 嚴格過濾：必須明確提到台中 + 咖啡
$taichungLocations = '台中|北屯|西屯|南屯|大里|太平|豐原|潭子|霧峰|神岡|沙鹿|清水|梧棲|大甲|大雅|烏日|龍井|外埔|后里|新社|東勢|石岡|東區|西區|南區|北區|中區|臺中'
$localFoodPicked = @($localFoodPicked | Where-Object {
    $t = "$($_.Title) $($_.Desc)"
    ($t -match $taichungLocations) -and ($t -match '咖啡|cafe|coffee|latte|espresso')
})
Set-FallbackImages $localFoodPicked 'coffee,cafe,latte,espresso'
Write-Host ("  → 挑出 {0} 則台中咖啡好去處" -f $localFoodPicked.Count)

Write-Host "`n取即時天氣 + AQI…"
$weatherPicked = @()  # 不再抓天氣新聞，只留儀表板
$weatherData = Get-WeatherDashboard
$aqiData = Get-AQI
Write-Host ("  → 氣象: {0} · AQI 測站: {1}" -f ($null -ne $weatherData), @($aqiData).Count)

Write-Host "`n抓取親子週末好去處 RSS…"
$kidRaw = Get-SecondaryPanel -sources $KidSources -maxItems 80 -days 45 -descCap 180 -requireSignals $KidSignals
if ($kidRaw.Count -gt 0) { Add-PanelImages $kidRaw '親子候選' }
$kidWithImg = @($kidRaw | Where-Object { $_.Image } | Sort-Object Pub -Descending | Select-Object -First 20)
if ($kidWithImg.Count -lt 15) {
    $kidNoImg = @($kidRaw | Where-Object { -not $_.Image } | Sort-Object Pub -Descending | Select-Object -First (20 - $kidWithImg.Count))
    $kidPicked = @($kidWithImg) + @($kidNoImg)
} else {
    $kidPicked = $kidWithImg
}
# 親子出遊推薦 + 台灣限定：放寬為 (台灣地名出現) OR (沒提國外地名)
$outingKeywords = '景點|活動|出遊|好去處|好玩|景色|樂園|遊樂|主題樂園|農場|牧場|森林|步道|動物園|水族館|博物館|美術館|兒童館|科博館|公園|野餐|露營|親水|玩水|親子餐廳|觀光|體驗|DIY|手作|展覽|市集|渡假|溜小孩|放電|賞花|賞楓|親子飯店|親子民宿|一日遊|兩日遊|小旅行|行程|遊記|旅遊|旅行|玩法|攻略|去哪玩|好地方|推薦|親子共遊|親子旅遊|必去|必玩'
$taiwanLocations = '台灣|臺灣|台北|臺北|新北|基隆|桃園|新竹|宜蘭|花蓮|台東|臺東|苗栗|台中|臺中|彰化|南投|雲林|嘉義|台南|臺南|高雄|屏東|澎湖|金門|馬祖|全台|全臺|北部|中部|南部|東部|墾丁|日月潭|阿里山|太魯閣|九份|烏來|陽明山|野柳|北投|淡水|鹿港|礁溪|三峽|八里|林口|汐止|板橋|新店|蘆洲|五股|泰山|中和|永和|土城|樹林|鶯歌|三重|安平|關子嶺|溪頭|清境|合歡山|梨山|大雪山|桃機|松山|林口'
$foreignKeywords = '日本|東京|大阪|京都|沖繩|北海道|韓國|首爾|釜山|美國|紐約|洛杉磯|歐洲|巴黎|倫敦|泰國|曼谷|新加坡|越南|印尼|峇里島|馬來西亞|吉隆坡|澳洲|雪梨|墨爾本|紐西蘭|中國大陸|北京|上海|廣州|深圳|香港|澳門'
$excludeKeywords = '教育|教學|補習|升學|安親|家教|幼兒園|幼教|課綱|學測|國中|高中|醫療|疫苗|生病|過敏|保險|理財|基金|虐待|受傷|霸凌|家暴|離婚|監護|綁架|犯罪|司法|法律|判刑|性侵|猥褻|失蹤|兇殺|走失'
$kidPicked = @($kidPicked | Where-Object {
    $t = "$($_.Title) $($_.Desc)"
    $hasKid     = $t -match '親子|小孩|兒童|孩子|家庭|帶小孩|遛小孩|爸媽|爸爸|媽媽|全家'
    $hasOuting  = $t -match $outingKeywords
    $hasTaiwan  = $t -match $taiwanLocations
    $hasForeign = $t -match $foreignKeywords
    $inExclude  = $t -match $excludeKeywords
    # 必須：親子 + 出遊 + 非排除類；且（台灣地名出現 OR 沒提到國外）
    $hasKid -and $hasOuting -and (-not $inExclude) -and ($hasTaiwan -or (-not $hasForeign))
})
Set-FallbackImages $kidPicked 'kids,family,playground,park'
Write-Host ("  → 挑出 {0} 則親子出遊推薦（嚴格過濾）" -f $kidPicked.Count)

Write-Host "`n抓取台中啤酒好地方 RSS…"
$beerRaw = Get-SecondaryPanel -sources $BeerSources -maxItems 60 -days 60 -descCap 180 -requireSignals $BeerSignals
if ($beerRaw.Count -gt 0) { Add-PanelImages $beerRaw '台中啤酒候選' }
$beerPicked = @($beerRaw | Sort-Object Pub -Descending | Select-Object -First 15)
Set-FallbackImages $beerPicked 'beer,bar,craftbeer,pub'
Write-Host ("  → 挑出 {0} 則台中啤酒（全部含圖）" -f $beerPicked.Count)

Write-Host "`n讀取和美搖飲店家資料（ren-shops.json）…"
$renShopsFile = Join-Path $PSScriptRoot 'ren-shops.json'
$renShops = @()
if (Test-Path $renShopsFile) {
    try {
        $json = Get-Content $renShopsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $renShops = @($json)
        Write-Host ("  → 讀到 {0} 家店" -f $renShops.Count) -ForegroundColor Green
    } catch {
        Write-Host "  JSON 格式錯誤: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "  沒有 ren-shops.json，面板會顯示設定說明" -ForegroundColor DarkGray
}
# 不再抓新聞，用空陣列以免其他地方出錯
$renPicked = @()

Write-Host "`n抓取複材技術 RSS…"
# 先挑 40 則候選（嚴格技術訊號），再補圖＋排序（有圖優先），最後取 20
$techRaw = Get-SecondaryPanel -sources $TechSources -maxItems 40 -days 120 -descCap 180 -requireSignals $TechOnlySignals
Write-Host ("  → 候選 {0} 則，補圖中…" -f $techRaw.Count)
if ($techRaw.Count -gt 0) { Add-PanelImages $techRaw '複材技術候選' }
# 有圖優先，同權重再依時間新舊
$techPicked = @($techRaw | Sort-Object `
    @{Expression={ if ($_.Image) { 0 } else { 1 } }}, `
    @{Expression={ $_.Pub }; Descending=$true} | Select-Object -First 20)
$techImgN = @($techPicked | Where-Object { $_.Image }).Count
Write-Host ("  → 挑出 {0} 則複材技術新聞（含圖 {1}）" -f $techPicked.Count, $techImgN)

Write-Host "`n抓取市場情報 RSS…"
$appPicked = Get-SecondaryPanel -sources $AppSources -maxItems 15 -days 90 -descCap 180 -requireSignals $ConsumerProductPatterns
Write-Host ("  → 挑出 {0} 則市場情報新聞" -f $appPicked.Count)

Write-Host "`n抓取超級纖維 RSS…"
$fiberPicked = Get-SecondaryPanel -sources $FiberSources -maxItems 10 -days 90 -descCap 180 -requireSignals $MarketSignalPatterns
Write-Host ("  → 挑出 {0} 則超級纖維新聞" -f $fiberPicked.Count)

# 抓原文補強：Google News 描述通常很短，直接抓原網頁段落
if ($carbonPicked.Count -gt 0) {
    Write-Host "  → 抓原文補強內容…"
    $idx = 0
    foreach ($p in $carbonPicked) {
        $idx++
        $preview = $p.Title.Substring(0, [math]::Min(45, $p.Title.Length))
        Write-Host ("    [{0}/{1}] {2}" -f $idx, $carbonPicked.Count, $preview)
        $article = Get-ArticleText $p.Link
        # 只要比 RSS 描述長就採用
        if ($article -and $article.Length -gt ([math]::Max(120, $p.Desc.Length))) {
            if ($article.Length -gt 400) { $article = $article.Substring(0, 400).TrimEnd() + '…' }
            $p.Desc = $article
        }
        # 若 RSS 無圖，抓 og:image 補
        if (-not $p.Image) {
            $img = Get-ArticleImage $p.Link
            if ($img) { $p.Image = $img }
        }
        Start-Sleep -Milliseconds 250
    }
}

Add-PanelImages $appPicked '市場情報'
Add-PanelImages $fiberPicked '超級纖維'

# ---------- 5aZ. 跨面板去重（同一 URL 只保留最先出現的面板）----------
function Filter-DuplicateAcross {
    param($items, $seenUrls)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($it in $items) {
        if ($it.Link -and -not $seenUrls.Contains($it.Link)) {
            [void]$seenUrls.Add($it.Link)
            $out.Add($it)
        }
    }
    return ,$out.ToArray()
}
$seenUrls = New-Object System.Collections.Generic.HashSet[string]
foreach ($p in $picked) { if ($p.Link) { [void]$seenUrls.Add($p.Link) } }
$carbonPicked    = Filter-DuplicateAcross $carbonPicked    $seenUrls
$mfgPicked       = Filter-DuplicateAcross $mfgPicked       $seenUrls
$techPicked      = Filter-DuplicateAcross $techPicked      $seenUrls
$appPicked       = Filter-DuplicateAcross $appPicked       $seenUrls
$fiberPicked     = Filter-DuplicateAcross $fiberPicked     $seenUrls
$plasticPicked   = Filter-DuplicateAcross $plasticPicked   $seenUrls
$metalPicked     = Filter-DuplicateAcross $metalPicked     $seenUrls
$funPicked       = Filter-DuplicateAcross $funPicked       $seenUrls
$foodPicked      = Filter-DuplicateAcross $foodPicked      $seenUrls
$localFoodPicked = Filter-DuplicateAcross $localFoodPicked $seenUrls
$kidPicked       = Filter-DuplicateAcross $kidPicked       $seenUrls
$beerPicked      = Filter-DuplicateAcross $beerPicked      $seenUrls
$renPicked       = Filter-DuplicateAcross $renPicked       $seenUrls
Write-Host ("  → 跨面板去重後累計 {0} 個不重複 URL" -f $seenUrls.Count) -ForegroundColor Cyan

# ---------- 5b. 翻譯英文內容為中文（主新聞 + 碳纖維新聞）----------
$allToTranslate = New-Object System.Collections.Generic.List[object]
foreach ($p in $picked)       { [void]$allToTranslate.Add($p) }
foreach ($p in $carbonPicked) { [void]$allToTranslate.Add($p) }
foreach ($p in $mfgPicked)    { [void]$allToTranslate.Add($p) }
foreach ($p in $techPicked)   { [void]$allToTranslate.Add($p) }
foreach ($p in $plasticPicked){ [void]$allToTranslate.Add($p) }
foreach ($p in $metalPicked)  { [void]$allToTranslate.Add($p) }
foreach ($p in $funPicked)    { [void]$allToTranslate.Add($p) }
foreach ($p in $foodPicked)   { [void]$allToTranslate.Add($p) }
foreach ($p in $localFoodPicked) { [void]$allToTranslate.Add($p) }
foreach ($p in $kidPicked)    { [void]$allToTranslate.Add($p) }
foreach ($p in $weatherPicked){ [void]$allToTranslate.Add($p) }
foreach ($p in $beerPicked)   { [void]$allToTranslate.Add($p) }
foreach ($p in $renPicked)    { [void]$allToTranslate.Add($p) }
foreach ($p in $appPicked)    { [void]$allToTranslate.Add($p) }
foreach ($p in $fiberPicked)  { [void]$allToTranslate.Add($p) }
$needTranslate  = @($allToTranslate | Where-Object { -not (Test-IsChinese $_.Title) }).Count
if ($needTranslate -gt 0) {
    Write-Host ("`n翻譯 {0} 則英文…" -f $needTranslate)
    $idx = 0
    foreach ($p in $allToTranslate) {
        $idx++
        if (Test-IsChinese $p.Title) { continue }
        $preview = $p.Title.Substring(0, [math]::Min(50, $p.Title.Length))
        Write-Host ("  [{0}/{1}] {2}" -f $idx, $allToTranslate.Count, $preview)
        $p.Title = Translate-Text $p.Title
        if ($p.Desc) { $p.Desc = Translate-Text $p.Desc }
    }
    Save-TranslateCache
    Write-Host ("  快取累計 {0} 條" -f $script:TranslateCache.Count) -ForegroundColor Green
}

# 翻譯後保險封頂
foreach ($p in $picked) {
    if ($p.Desc -and $p.Desc.Length -gt 500) { $p.Desc = $p.Desc.Substring(0, 500).TrimEnd() + '…' }
}
foreach ($p in $carbonPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 400) { $p.Desc = $p.Desc.Substring(0, 400).TrimEnd() + '…' }
}
foreach ($p in $mfgPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 400) { $p.Desc = $p.Desc.Substring(0, 400).TrimEnd() + '…' }
}
foreach ($p in $techPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 400) { $p.Desc = $p.Desc.Substring(0, 400).TrimEnd() + '…' }
}
foreach ($p in $plasticPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 400) { $p.Desc = $p.Desc.Substring(0, 400).TrimEnd() + '…' }
}
foreach ($p in $metalPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 400) { $p.Desc = $p.Desc.Substring(0, 400).TrimEnd() + '…' }
}
foreach ($p in $funPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 300) { $p.Desc = $p.Desc.Substring(0, 300).TrimEnd() + '…' }
}
foreach ($p in $foodPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 300) { $p.Desc = $p.Desc.Substring(0, 300).TrimEnd() + '…' }
}
foreach ($p in $localFoodPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 300) { $p.Desc = $p.Desc.Substring(0, 300).TrimEnd() + '…' }
}
foreach ($p in $kidPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 300) { $p.Desc = $p.Desc.Substring(0, 300).TrimEnd() + '…' }
}
foreach ($p in $weatherPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 250) { $p.Desc = $p.Desc.Substring(0, 250).TrimEnd() + '…' }
}
foreach ($p in $beerPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 300) { $p.Desc = $p.Desc.Substring(0, 300).TrimEnd() + '…' }
}
foreach ($p in $renPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 300) { $p.Desc = $p.Desc.Substring(0, 300).TrimEnd() + '…' }
}
foreach ($p in $appPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 250) { $p.Desc = $p.Desc.Substring(0, 250).TrimEnd() + '…' }
}
foreach ($p in $fiberPicked) {
    if ($p.Desc -and $p.Desc.Length -gt 250) { $p.Desc = $p.Desc.Substring(0, 250).TrimEnd() + '…' }
}

# ---------- 6. 產生 HTML ----------
$outputDir = Join-Path $PSScriptRoot 'output'
if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory | Out-Null }

# 偵測 LOGO：PNG/JPG（真實圖檔）> SVG（向量）> 文字占位
$logoHtml = ''
# 1) 真實圖檔優先（使用者可隨時替換為正式 LOGO）
foreach ($ext in 'png','jpg','jpeg','webp') {
    $p = Join-Path $PSScriptRoot "logo.$ext"
    if (Test-Path $p) {
        $mime = if ($ext -eq 'jpg' -or $ext -eq 'jpeg') { 'image/jpeg' } else { "image/$ext" }
        $b64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($p))
        $logoHtml = "<img class=""logo"" src=""data:$mime;base64,$b64"" alt=""TEi Composites"">"
        Write-Host "  → 使用 LOGO: $p" -ForegroundColor Green
        break
    }
}
# 2) 嵌入 SVG 向量（直接 inline，任何尺寸都銳利）
if (-not $logoHtml) {
    $svgPath = Join-Path $PSScriptRoot 'logo.svg'
    if (Test-Path $svgPath) {
        $svg = (Get-Content $svgPath -Raw -Encoding UTF8) -replace '(?s)<\?xml[^>]+\?>\s*', ''
        $svg = [regex]::Replace($svg, '(?i)<svg(?!\s+class=)', '<svg class="logo"', 1)
        $logoHtml = $svg
        Write-Host "  → 使用 LOGO: $svgPath" -ForegroundColor Green
    }
}
# 3) 文字占位
if (-not $logoHtml) {
    $logoHtml = '<div class="logo-placeholder">TEi</div>'
    Write-Host "  → 未偵測到 LOGO，使用文字占位" -ForegroundColor Yellow
}

$dateStr  = Get-Date -Format 'yyyy-MM-dd HH:mm'
$catLabel = @{ Tech='科技'; Conflict='衝突'; Politics='政治'; Economy='經濟'; Markets='市場'; Diplomacy='外交' }
$catColor = @{ Tech='#0891b2'; Conflict='#e0556f'; Politics='#5b87e0'; Economy='#3ba374'; Markets='#e0a040'; Diplomacy='#9966d4' }
$catGrad  = @{
    Tech      = 'linear-gradient(135deg,#06b6d4 0%,#0ea5e9 100%)'
    Conflict  = 'linear-gradient(135deg,#ff758c 0%,#ff9a7e 100%)'
    Politics  = 'linear-gradient(135deg,#667eea 0%,#89b4fa 100%)'
    Economy   = 'linear-gradient(135deg,#43cea2 0%,#6ee7b7 100%)'
    Markets   = 'linear-gradient(135deg,#f7971e 0%,#ffd86f 100%)'
    Diplomacy = 'linear-gradient(135deg,#a18cd1 0%,#fbc2eb 100%)'
}

function Get-ImgStyle {
    param([string]$img, [string]$cat)
    $grad = $catGrad[$cat]
    if ($img) {
        # 漸層當後備色，圖片 404 時就會露出漸層，避免空白方塊
        return "background:$grad;background-image:url('$(HtmlEsc $img)');background-size:cover;background-position:center;background-repeat:no-repeat;"
    }
    return "background:$grad;"
}

function Format-Pub {
    param($p)
    if (-not $p) { return '' }
    return ([datetime]$p).ToLocalTime().ToString('MM/dd HH:mm')
}

# 產生「閱讀完整報導」按鈕 HTML
# 中文來源 → 單一按鈕直接開原文
# 英文來源 → 主按鈕 Google 翻譯版，附小按鈕「原文」作後援（某些網站會擋翻譯代理）
function Get-ReadMoreHtml {
    param([string]$url, [string]$lang)
    if (-not $url) { return '' }
    $origEsc = HtmlEsc $url
    # 中文來源 或 Google News wrapper（被翻譯代理空白化）→ 直接開原連結
    $isGoogleNews = $url -match 'news\.google\.com/(rss/)?articles/'
    if ($lang -eq 'zh' -or $isGoogleNews) {
        return "<a class=""read-more"" href=""$origEsc"" target=""_blank"" rel=""noopener"" title=""在 Chrome／Edge 可右鍵選『翻譯成中文』"">閱讀完整報導 →</a>"
    }
    $translateUrl = "https://translate.google.com/translate?sl=auto&tl=zh-TW&u=$([uri]::EscapeDataString($url))"
    $transEsc = HtmlEsc $translateUrl
    return @"
<div class="read-more-group">
  <a class="read-more" href="$transEsc" target="_blank" rel="noopener">閱讀完整報導 (繁中) →</a>
  <a class="read-more-alt" href="$origEsc" target="_blank" rel="noopener" title="若翻譯版被網站封鎖，可點此看英文原文。在 Chrome／Edge 瀏覽器可右鍵選「翻譯成中文」使用瀏覽器內建翻譯（不經代理、不被擋）">原文</a>
</div>
"@
}

# 分拆：1 hero + 4 list + 15 tiles
$heroItem  = $picked[0]
$listItems = @($picked | Select-Object -Skip 1 -First 4)
$gridItems = @($picked | Select-Object -Skip 5)

# --- Hero ---
$h = $heroItem
$heroHtml = @"
<details class="card hero">
  <summary>
    <div class="hero-img" style="$(Get-ImgStyle $h.Image $h.Category)"></div>
    <div class="hero-overlay"></div>
    <div class="hero-caption">
      <div class="tags">
        <span class="tag" style="background:$($catColor[$h.Category])">$($catLabel[$h.Category])</span>
      </div>
      <h2>$(HtmlEsc $h.Title)</h2>
      <div class="meta">$(HtmlEsc $h.Source) · $(Format-Pub $h.Pub)</div>
    </div>
  </summary>
  <div class="detail">
    <p>$(HtmlEsc $h.Desc)</p>
    $(Get-ReadMoreHtml $h.Link $h.Lang)
  </div>
</details>
"@

# --- List card ---
$listBody = ''
foreach ($p in $listItems) {
    $listBody += @"
<details class="list-item">
  <summary>
    <div class="list-thumb" style="$(Get-ImgStyle $p.Image $p.Category)"></div>
    <div class="list-caption">
      <h4>$(HtmlEsc $p.Title)</h4>
      <div class="meta">
        <span class="tag tiny" style="background:$($catColor[$p.Category])">$($catLabel[$p.Category])</span>
        $(HtmlEsc $p.Source) · $(Format-Pub $p.Pub)
      </div>
    </div>
  </summary>
  <div class="detail">
    <p>$(HtmlEsc $p.Desc)</p>
    $(Get-ReadMoreHtml $p.Link $p.Lang)
  </div>
</details>
"@
}
$listHtml = @"
<aside class="card list">
  <h3>重點追蹤</h3>
  $listBody
</aside>
"@

# --- 碳纖維即時新聞卡（右側面板）---
$carbonBody = ''
if ($carbonPicked.Count -eq 0) {
    $carbonBody = '<div class="carbon-empty">目前 30 天內無新進新聞</div>'
} else {
    foreach ($p in $carbonPicked) {
        $pubStr = if ($p.Pub) { ([datetime]$p.Pub).ToLocalTime().ToString('MM/dd') } else { '' }
        $descBlock = if ($p.Desc) { "<p>$(HtmlEsc $p.Desc)</p>" } else { '' }
        $carbonBody += @"
<details class="carbon-item">
  <summary>
    <span class="carbon-badge">CF</span>
    <div class="carbon-line">
      <h4>$(HtmlEsc $p.Title)</h4>
      <div class="meta">$(HtmlEsc $p.Source) · $pubStr</div>
    </div>
  </summary>
  <div class="detail">
    $descBlock
    $(Get-ReadMoreHtml $p.Link $p.Lang)
  </div>
</details>
"@
    }
}
$carbonHtml = @"
<section class="panel-section carbon-section" data-group="carbon">
  <h2 class="panel-title">碳纖維即時新聞 <span class="sub">Carbon Fiber · $($carbonPicked.Count) 則</span></h2>
  <div class="carbon-grid">
    $carbonBody
  </div>
</section>
"@

# --- Grid tiles ---
$gridBody = ''
foreach ($p in $gridItems) {
    $gridBody += @"
<details class="card tile">
  <summary>
    <div class="tile-img" style="$(Get-ImgStyle $p.Image $p.Category)"></div>
    <div class="tile-body">
      <div class="tags">
        <span class="tag tiny" style="background:$($catColor[$p.Category])">$($catLabel[$p.Category])</span>
      </div>
      <h3>$(HtmlEsc $p.Title)</h3>
      <div class="meta">$(HtmlEsc $p.Source) · $(Format-Pub $p.Pub)</div>
    </div>
  </summary>
  <div class="detail">
    <p>$(HtmlEsc $p.Desc)</p>
    $(Get-ReadMoreHtml $p.Link $p.Lang)
  </div>
</details>
"@
}

# --- 複材應用 + 超級纖維通用卡片產生器 ---
function Build-MiniTile {
    param($p)
    $pubStr = if ($p.Pub) { ([datetime]$p.Pub).ToLocalTime().ToString('MM/dd') } else { '' }
    $descBlock = if ($p.Desc) { "<p>$(HtmlEsc $p.Desc)</p>" } else { '' }
    $imgOverlay = if (-not $p.Image) {
        # 無圖 → 漸層上疊來源名浮水印，提升視覺辨識
        "<div class=""img-overlay"">$(HtmlEsc $p.Source)</div>"
    } else { '' }
    return @"
<details class="mini-tile">
  <summary>
    <div class="mini-img" style="$(Get-ImgStyle $p.Image 'Tech')">$imgOverlay</div>
    <div class="mini-body">
      <h4>$(HtmlEsc $p.Title)</h4>
      <div class="meta">$(HtmlEsc $p.Source) · $pubStr</div>
    </div>
  </summary>
  <div class="detail">
    $descBlock
    $(Get-ReadMoreHtml $p.Link $p.Lang)
  </div>
</details>
"@
}

$appBody = ''
foreach ($p in $appPicked)    { $appBody   += (Build-MiniTile $p) }
$fiberBody = ''
foreach ($p in $fiberPicked)  { $fiberBody += (Build-MiniTile $p) }
$mfgBody = ''
foreach ($p in $mfgPicked)    { $mfgBody   += (Build-MiniTile $p) }

$mfgHtml = if ($mfgPicked.Count -gt 0) { @"
<section class="panel-section mfg-section" data-group="mfg">
  <h2 class="panel-title">碳纖製造商 <span class="sub">Toray / Hexcel / Teijin / Mitsubishi / SGL / Syensqo · $($mfgPicked.Count) 則</span></h2>
  <div class="mini-grid">$mfgBody</div>
</section>
"@ } else { '' }

$techBody = ''
foreach ($p in $techPicked)   { $techBody  += (Build-MiniTile $p) }
$plasticBody = ''
foreach ($p in $plasticPicked) { $plasticBody += (Build-MiniTile $p) }
$metalBody = ''
foreach ($p in $metalPicked)   { $metalBody += (Build-MiniTile $p) }
$funBody = ''
foreach ($p in $funPicked)     { $funBody   += (Build-MiniTile $p) }
$foodBody = ''
foreach ($p in $foodPicked)    { $foodBody  += (Build-MiniTile $p) }
$localFoodBody = ''
foreach ($p in $localFoodPicked) { $localFoodBody += (Build-MiniTile $p) }
$kidBody = ''
foreach ($p in $kidPicked)       { $kidBody += (Build-MiniTile $p) }

# ---- 天氣儀表板卡 ----
$weatherCard = ''
if ($weatherData) {
    $cur = $weatherData.current
    $curLabel = Get-WeatherCodeLabel ([int]$cur.weather_code)
    $curEmoji = Get-WeatherCodeEmoji ([int]$cur.weather_code)

    $dailyHtml = ''
    $dayCount = [math]::Min(5, $weatherData.daily.time.Count)
    for ($i = 0; $i -lt $dayCount; $i++) {
        $t = [datetime]$weatherData.daily.time[$i]
        $dayName = switch ($t.DayOfWeek.ToString()) {
            'Monday'    { '週一' } 'Tuesday'  { '週二' } 'Wednesday'{ '週三' }
            'Thursday'  { '週四' } 'Friday'   { '週五' } 'Saturday' { '週六' }
            'Sunday'    { '週日' } default { '' }
        }
        $maxT = [math]::Round([double]$weatherData.daily.temperature_2m_max[$i])
        $minT = [math]::Round([double]$weatherData.daily.temperature_2m_min[$i])
        $rain = [int]$weatherData.daily.precipitation_probability_max[$i]
        $dailyLabel = Get-WeatherCodeLabel ([int]$weatherData.daily.weather_code[$i])
        $dailyEmoji = Get-WeatherCodeEmoji ([int]$weatherData.daily.weather_code[$i])
        $dailyHtml += @"
<div class="weather-day">
  <div class="day-name">$dayName</div>
  <div class="day-icon">$dailyEmoji</div>
  <div class="day-temp">$maxT&deg; / $minT&deg;</div>
  <div class="day-label">$dailyLabel</div>
  <div class="day-rain">&#x2614; $rain%</div>
</div>
"@
    }
} else {
    $dailyHtml = '<div class="weather-day">天氣資料取得失敗</div>'
    $curLabel = '—'; $curEmoji = '🌡️'
    $cur = @{ temperature_2m = '—'; apparent_temperature = '—'; relative_humidity_2m = '—'; wind_speed_10m = '—' }
}

# AQI 表格：直接列出所有成功取得的測站
$aqiRows = ''
$aqiShown = 0
foreach ($r in $aqiData) {
    if ($aqiShown -ge 16) { break }
    $aqiVal = [int]$r.aqi
    $status = [string]$r.status
    $colorClass = if ($aqiVal -le 50) { 'aqi-good' }
                  elseif ($aqiVal -le 100) { 'aqi-moderate' }
                  elseif ($aqiVal -le 150) { 'aqi-unhealthy-sg' }
                  elseif ($aqiVal -le 200) { 'aqi-unhealthy' }
                  elseif ($aqiVal -le 300) { 'aqi-very-unhealthy' }
                  else { 'aqi-hazardous' }
    $aqiRows += "<div class=""aqi-row $colorClass""><span class=""site"">$([System.Net.WebUtility]::HtmlEncode($r.sitename))</span><strong>$aqiVal</strong><span class=""status"">$([System.Net.WebUtility]::HtmlEncode($status))</span></div>"
    $aqiShown++
}
if ($aqiShown -eq 0) {
    $aqiRows = '<div class="aqi-row">AQI 資料暫時無法取得（稍後自動重試）</div>'
}

$curTemp = if ($weatherData) { [math]::Round([double]$cur.temperature_2m) } else { '—' }
$curFeel = if ($weatherData) { [math]::Round([double]$cur.apparent_temperature) } else { '—' }

$weatherCard = @"
<div class="weather-card">
  <div class="weather-current">
    <div class="weather-emoji">$curEmoji</div>
    <div class="weather-temp">${curTemp}&deg;C</div>
    <div class="weather-info">
      <div class="weather-label">$curLabel</div>
      <div class="weather-sub">體感 ${curFeel}&deg;C &middot; 濕度 $($cur.relative_humidity_2m)% &middot; 風速 $([math]::Round([double]$cur.wind_speed_10m, 1)) km/h</div>
    </div>
    <div class="weather-loc">&#128205; 和美 · 彰化</div>
  </div>
  <div class="weather-forecast">$dailyHtml</div>
  <div class="aqi-section">
    <h3>空氣品質 AQI &middot; 即時監測</h3>
    <div class="aqi-list">$aqiRows</div>
  </div>
</div>
"@

$weatherBody = ''
foreach ($p in $weatherPicked) { $weatherBody += (Build-MiniTile $p) }

$beerBody = ''
foreach ($p in $beerPicked)    { $beerBody += (Build-MiniTile $p) }

# 飲料店品牌 → 官網 domain 對應，用於自動取 logo
$brandDomains = @{
    '得正'             = 'dejhengtea.com'
    '果冉'             = ''
    '杯子洪了'          = ''
    '茗沏'             = ''
    '就是橘子樹'        = ''
    '龜記'             = 'kueimemory.com.tw'
    '什麼茶'           = ''
    '幸福味'           = ''
    '紅茶巴士'         = 'blackteabus.com'
    'Black Tea Bus'    = 'blackteabus.com'
    '回憶小時候'        = ''
    '思饗茶'           = ''
    'TEA TOP'          = 'teatop.com.tw'
    '第一味'           = 'teatop.com.tw'
    '鹿兒角'           = ''
    '先喝道'           = 'shineroad.com.tw'
    '普樂'             = ''
    '萬波'             = 'wanpotea.com'
    'Wanpo'            = 'wanpotea.com'
    '十二韻'           = ''
    '迷客夏'           = 'milkshoptea.com'
    'Milksha'          = 'milkshoptea.com'
    'Milk shop'        = 'milkshoptea.com'
    '可不可'           = 'kebuke.com'
    '大雪山'           = ''
    '南海茶道'         = ''
    '清心福全'         = 'chingshin.com.tw'
    '清心'             = 'chingshin.com.tw'
    '大碗公'           = ''
    '功夫茶'           = 'kungfutea.com'
    'KUNGFUTEA'        = 'kungfutea.com'
    '鶴茶樓'           = 'hechalou.com'
    '50嵐'             = '50lan.com'
    '50lan'            = '50lan.com'
    '85度C'            = '85cafe.com.tw'
    '85cafe'           = '85cafe.com.tw'
    'CoCo都可'         = 'coco-tea.com'
    'CoCo'             = 'coco-tea.com'
    '麻古茶坊'         = 'macutea.com'
    '麻古'             = 'macutea.com'
    '老賴茶棧'         = 'lailai-tea.com'
    '老賴'             = 'lailai-tea.com'
    '黑堂'             = ''
    '杯樂'             = ''
    '茶湯會'           = 'tp-tea.com'
    '大苑子'           = 'dayungs.com'
    '一沐日'           = 'yimuri.com.tw'
    '八曜和茶'         = 'yashantea.com.tw'
    '鮮茶道'           = 'presotea.com'
    '御私藏'           = 'tea-yu.com.tw'
    '一手私藏'         = 'tea-1.com.tw'
    '茶の魔手'         = 'magicians.com.tw'
    '茶之魔手'         = 'magicians.com.tw'
}

function Get-ShopLogo {
    param([string]$name)
    foreach ($key in $brandDomains.Keys) {
        if ($name -match [regex]::Escape($key)) {
            $d = $brandDomains[$key]
            if ($d) { return "https://www.google.com/s2/favicons?domain=$d&sz=128" }
        }
    }
    return ''
}

# 店家色塊：法式色票 — 巴黎藍／勃艮第／鼠尾草／古銅金／玫瑰粉
$brandStyles = [ordered]@{
    'Black Tea Bus' = @{ bg = '#7c3a3a'; text = '紅茶巴士' }
    '紅茶巴士'      = @{ bg = '#7c3a3a'; text = '紅茶巴士' }
    '萬波島嶼'      = @{ bg = '#3d5a80'; text = '萬波' }
    '萬波'          = @{ bg = '#3d5a80'; text = '萬波' }
    'TEA TOP'       = @{ bg = '#7a2a3a'; text = 'TEA·TOP' }
    '第一味'        = @{ bg = '#7a2a3a'; text = 'TEA·TOP' }
    'Milksha'       = @{ bg = '#7a8a5a'; text = '迷客夏' }
    'Milk shop'     = @{ bg = '#7a8a5a'; text = '迷客夏' }
    '迷客夏'        = @{ bg = '#7a8a5a'; text = '迷客夏' }
    '85度C'         = @{ bg = '#5a6a3a'; text = '85°C' }
    'CoCo都可'      = @{ bg = '#7c3a3a'; text = 'CoCo' }
    'CoCo'          = @{ bg = '#7c3a3a'; text = 'CoCo' }
    '清心福全'      = @{ bg = '#7c3a3a'; text = '清心' }
    '清心'          = @{ bg = '#7c3a3a'; text = '清心' }
    '麻古茶坊'      = @{ bg = '#2d2d2a'; text = '麻古' }
    '麻古'          = @{ bg = '#2d2d2a'; text = '麻古' }
    '老賴茶棧'      = @{ bg = '#7a2a3a'; text = '老賴' }
    '老賴'          = @{ bg = '#7a2a3a'; text = '老賴' }
    '可不可熟成'    = @{ bg = '#5a3a2a'; text = '可不可' }
    '可不可'        = @{ bg = '#5a3a2a'; text = '可不可' }
    '龜記茗品'      = @{ bg = '#b8956b'; text = '龜記' }
    '龜記'          = @{ bg = '#b8956b'; text = '龜記' }
    '50嵐'          = @{ bg = '#7c3a3a'; text = '50嵐' }
    '茶湯會'        = @{ bg = '#a07a5a'; text = '茶湯會' }
    '大苑子'        = @{ bg = '#7a8a5a'; text = '大苑子' }
    '一沐日'        = @{ bg = '#7a6f5a'; text = '一沐日' }
    '八曜和茶'      = @{ bg = '#5a6a70'; text = '八曜' }
    '鮮茶道'        = @{ bg = '#7a5a8a'; text = '鮮茶道' }
    '御私藏'        = @{ bg = '#7a8a5a'; text = '御私藏' }
    '一手私藏'      = @{ bg = '#1d3557'; text = '一手' }
    '鶴茶樓'        = @{ bg = '#c4a04a'; text = '鶴茶樓' }
    '功夫茶'        = @{ bg = '#2d2d2a'; text = '功夫茶' }
    'KUNGFUTEA'     = @{ bg = '#2d2d2a'; text = '功夫茶' }
    '茶の魔手'      = @{ bg = '#7a5a8a'; text = '魔手' }
    '茶之魔手'      = @{ bg = '#7a5a8a'; text = '魔手' }
    '得正'          = @{ bg = '#7a8a5a'; text = '得正' }
    'Oolong'        = @{ bg = '#7a8a5a'; text = '得正' }
    '十二韻'        = @{ bg = '#5a3a2a'; text = '十二韻' }
    '幸福味'        = @{ bg = '#c47a8c'; text = '幸福味' }
    '思饗茶'        = @{ bg = '#7a8a5a'; text = '思饗茶' }
    '飲茶屋'        = @{ bg = '#7a6f5a'; text = '飲茶屋' }
    '果冉'          = @{ bg = '#b8895c'; text = '果冉' }
    '什麼茶'        = @{ bg = '#5a7a90'; text = '什麼茶' }
    '南海茶道'      = @{ bg = '#3d5a80'; text = '南海' }
    '鹿兒角'        = @{ bg = '#a07a5a'; text = '鹿兒角' }
    '杯子洪了'      = @{ bg = '#7a5a8a'; text = '杯子洪了' }
    '杯樂'          = @{ bg = '#b8895c'; text = '杯樂' }
    '黑堂'          = @{ bg = '#2d2d2a'; text = '黑堂' }
    '大碗公'        = @{ bg = '#3d5a80'; text = '大碗公' }
    '回憶小時候'    = @{ bg = '#7a5a8a'; text = '回憶' }
    '就是橘子樹'    = @{ bg = '#b8895c'; text = '橘子樹' }
    '大雪山'        = @{ bg = '#3d5a80'; text = '大雪山' }
    '茗沏'          = @{ bg = '#7a8a5a'; text = '茗沏' }
    '普樂'          = @{ bg = '#5a7a90'; text = '普樂' }
    '先喝道'        = @{ bg = '#5a7a90'; text = '先喝道' }
}

function Get-BrandStyle {
    param([string]$shopName)
    foreach ($key in $brandStyles.Keys) {
        if ($shopName -match [regex]::Escape($key)) {
            return $brandStyles[$key]
        }
    }
    return @{ bg = 'linear-gradient(135deg,#5a4a3a,#7a5b3a)'; text = '🍵' }
}

# 和美搖飲(忍) — 優先顯示菜單圖（menu-ren.jpg / menu-ren.png），再列新聞
$renMenuCard = ''
foreach ($ext in 'jpg','jpeg','png','webp') {
    $mp = Join-Path $PSScriptRoot "menu-ren.$ext"
    if (Test-Path $mp) {
        $mime = if ($ext -eq 'jpg' -or $ext -eq 'jpeg') { 'image/jpeg' } else { "image/$ext" }
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mp))
        $renMenuCard = @"
<details class="mini-tile" open>
  <summary>
    <div class="mini-img" style="background-image:url('data:$mime;base64,$b64');background-size:contain;background-position:center;background-repeat:no-repeat;background-color:#f8fafc;aspect-ratio:auto;min-height:340px;"></div>
    <div class="mini-body">
      <h4>📋 和美搖飲(忍) 菜單</h4>
      <div class="meta">店家菜單 · 點擊查看完整資訊</div>
    </div>
  </summary>
  <div class="detail">
    <p>和美搖飲 忍 — 彰化縣和美鎮。完整品項參考上方菜單圖。</p>
  </div>
</details>
"@
        Write-Host "  → 找到菜單圖 menu-ren.$ext，已嵌入" -ForegroundColor Green
        break
    }
}
# 無菜單圖就不顯示占位卡，完全讓店家卡獨立呈現
$renBody = $renMenuCard

# 店家卡片
if ($renShops.Count -gt 0) {
    foreach ($shop in $renShops) {
        # 優先順序：手動填的 image > 品牌色塊 logo
        if ($shop.image) {
            $imgStyle = "background-image:url('$(HtmlEsc $shop.image)');background-size:cover;background-position:center;"
            $imgContent = ''
        } else {
            $brand = Get-BrandStyle $shop.name
            $imgStyle = "background:$($brand.bg);display:flex;align-items:center;justify-content:center;color:#fff;font-size:30px;font-weight:800;letter-spacing:1px;text-shadow:0 2px 8px rgba(0,0,0,0.35);text-align:center;padding:8px;"
            $imgContent = $brand.text
        }
        $mapsLink = if ($shop.maps) { "<a class=""read-more"" href=""$(HtmlEsc $shop.maps)"" target=""_blank"" rel=""noopener"">📍 Google Maps</a>" } else { '' }
        $fbLink   = if ($shop.fb)   { "<a class=""read-more-alt"" href=""$(HtmlEsc $shop.fb)"" target=""_blank"" rel=""noopener"">Facebook</a>" } else { '' }
        $igLink   = if ($shop.ig)   { "<a class=""read-more-alt"" href=""$(HtmlEsc $shop.ig)"" target=""_blank"" rel=""noopener"">Instagram</a>" } else { '' }
        $renBody += @"
<details class="mini-tile" open>
  <summary>
    <div class="mini-img" style="$imgStyle">$imgContent</div>
    <div class="mini-body">
      <h4>$(HtmlEsc $shop.name)</h4>
      <div class="meta">📍 $(HtmlEsc $shop.address)</div>
    </div>
  </summary>
  <div class="detail">
    $(if ($shop.phone) { "<p>📞 $(HtmlEsc $shop.phone)</p>" })
    $(if ($shop.hours) { "<p>🕐 $(HtmlEsc $shop.hours)</p>" })
    $(if ($shop.signature) { "<p>⭐ 招牌：$(HtmlEsc $shop.signature)</p>" })
    $(if ($shop.note) { "<p style='color:#888;font-size:12px'>$(HtmlEsc $shop.note)</p>" })
    <div class="read-more-group">$mapsLink $fbLink $igLink</div>
  </div>
</details>
"@
    }
} else {
    $renBody += @"
<details class="mini-tile" open>
  <summary>
    <div class="mini-img" style="background:linear-gradient(135deg,#14b8a6,#06b6d4);display:flex;align-items:center;justify-content:center;color:#fff;font-size:40px;aspect-ratio:auto;min-height:160px;">📝</div>
    <div class="mini-body">
      <h4>請編輯 ren-shops.json 填入店家資訊</h4>
      <div class="meta">和美手搖店家目錄</div>
    </div>
  </summary>
  <div class="detail">
    <p>檔案位置：<code>$PSScriptRoot\ren-shops.json</code></p>
    <p>JSON 格式範例（每間店一個物件）：</p>
    <pre style="background:#f1f5f9;padding:10px;border-radius:6px;font-size:11px;overflow:auto;">[
  {
    "name": "店名",
    "address": "地址",
    "phone": "電話",
    "hours": "營業時間",
    "maps": "Google Maps 連結",
    "fb": "Facebook 連結",
    "ig": "Instagram 連結",
    "image": "店家照片 URL",
    "signature": "招牌飲品",
    "note": "備註"
  }
]</pre>
    <p>編輯完存檔，下次執行會自動顯示店家卡片。</p>
  </div>
</details>
"@
}

$techHtml = if ($techPicked.Count -gt 0) { @"
<section class="panel-section tech-section" data-group="tech">
  <h2 class="panel-title">複材技術 <span class="sub">Composite Technology · AFP / RTM / 熱塑性 / 3D列印 / 回收 / 生物基 · $($techPicked.Count) 則</span></h2>
  <div class="mini-grid">$techBody</div>
</section>
"@ } else { '' }

$plasticHtml = if ($plasticPicked.Count -gt 0) { @"
<section class="panel-section plastic-section" data-group="plastic">
  <h2 class="panel-title">塑膠消息 <span class="sub">Plastics · Dow / BASF / SABIC / LyondellBasell / Covestro / Arkema · $($plasticPicked.Count) 則</span></h2>
  <div class="mini-grid">$plasticBody</div>
</section>
"@ } else { '' }

$metalHtml = if ($metalPicked.Count -gt 0) { @"
<section class="panel-section metal-section" data-group="metal">
  <h2 class="panel-title">世界金屬市場 <span class="sub">Metals · 鋼鐵／鋁／銅／鋰／稀土 · ArcelorMittal / Alcoa / Rio Tinto / BHP · $($metalPicked.Count) 則</span></h2>
  <div class="mini-grid">$metalBody</div>
</section>
"@ } else { '' }

$funHtml = if ($funPicked.Count -gt 0) { @"
<section class="panel-section fun-section" data-group="fun">
  <h2 class="panel-title">來點好心情 <span class="sub">音樂 &amp; 電影 · Variety / Billboard / Rolling Stone / Hollywood Reporter · $($funPicked.Count) 則</span></h2>
  <div class="mini-grid">$funBody</div>
</section>
"@ } else { '' }

$foodHtml = if ($foodPicked.Count -gt 0) { @"
<section class="panel-section food-section" data-group="food">
  <h2 class="panel-title">給你的美食 <span class="sub">Food &amp; Dining · Eater / Bon Appétit / Michelin · $($foodPicked.Count) 則</span></h2>
  <div class="mini-grid">$foodBody</div>
</section>
"@ } else { '' }

$localFoodHtml = if ($localFoodPicked.Count -gt 0) { @"
<section class="panel-section local-section" data-group="local">
  <h2 class="panel-title">台中咖啡好去處 <span class="sub">☕ 台中在地咖啡館 / 手沖 / 精品咖啡 / 獨立咖啡 · $($localFoodPicked.Count) 則</span></h2>
  <div class="mini-grid">$localFoodBody</div>
</section>
"@ } else { '' }

$kidHtml = if ($kidPicked.Count -gt 0) { @"
<section class="panel-section kid-section" data-group="kid">
  <h2 class="panel-title">親子週末 <span class="sub">有孩子同仁 · 週末好去處 · 景點 / 樂園 / 動物園 / 親子餐廳 · $($kidPicked.Count) 則</span></h2>
  <div class="mini-grid">$kidBody</div>
</section>
"@ } else { '' }

$weatherHtml = @"
<section class="panel-section weather-section" data-group="weather">
  <h2 class="panel-title">天氣預報 <span class="sub">即時氣象 + 空氣品質 AQI · 和美／彰化／台中</span></h2>
  $weatherCard
</section>
"@

$beerHtml = if ($beerPicked.Count -gt 0) { @"
<section class="panel-section beer-section" data-group="beer">
  <h2 class="panel-title">台中啤酒好地方 <span class="sub">精釀啤酒 / 酒吧 / 居酒屋 / 餐酒館 · ⚠️ 嚴禁酒駕 · $($beerPicked.Count) 則</span></h2>
  <div class="mini-grid">$beerBody</div>
</section>
"@ } else { '' }

$renHtml = @"
<section class="panel-section ren-section" data-group="ren">
  <h2 class="panel-title">和美搖飲(忍) <span class="sub">彰化和美 · 手搖飲店家資訊 + 菜單 · $($renShops.Count) 家店</span></h2>
  <div class="mini-grid">$renBody</div>
</section>
"@

$appHtml = if ($appPicked.Count -gt 0) { @"
<section class="panel-section app-section" data-group="app">
  <h2 class="panel-title">市場情報 <span class="sub">Market Intelligence · $($appPicked.Count) 則</span></h2>
  <div class="mini-grid">$appBody</div>
</section>
"@ } else { '' }

$fiberHtml = if ($fiberPicked.Count -gt 0) { @"
<section class="panel-section fiber-section" data-group="fiber">
  <h2 class="panel-title">超級纖維技術 <span class="sub">Kevlar／芳綸／UHMWPE／碳纖技術 · $($fiberPicked.Count) 則</span></h2>
  <div class="mini-grid">$fiberBody</div>
</section>
"@ } else { '' }

# --- Full HTML ---
$htmlShell = @"
<!doctype html>
<html lang="zh-TW">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta http-equiv="refresh" content="600">
<meta name="theme-color" content="#81d8d0">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="format-detection" content="telephone=no">
<title>TEi Composites · 國際新聞 · $dateStr</title>
<style>
 * { box-sizing: border-box; }
 html, body { overscroll-behavior-y:none; }
 body { margin:0; min-height:100vh; color:#1d1d1f; line-height:1.5;
        font-family:"SF Pro Display","SF Pro Text",-apple-system,BlinkMacSystemFont,"PingFang TC","Microsoft JhengHei","Helvetica Neue",sans-serif;
        background:
          radial-gradient(1200px 820px at 8% -10%, rgba(255,255,255,0.55), transparent 60%),
          radial-gradient(1000px 720px at 92% 0%, rgba(255,255,255,0.30), transparent 65%),
          radial-gradient(900px 700px at 50% 110%, rgba(10,186,181,0.25), transparent 60%),
          linear-gradient(180deg, #b4e6e1 0%, #81d8d0 55%, #5fc7be 100%);
        background-attachment:fixed;
        letter-spacing:-0.003em;
        -webkit-font-smoothing:antialiased; -moz-osx-font-smoothing:grayscale; }
 .wrap { max-width:1320px; margin:24px auto; padding:32px;
         background:rgba(255,255,255,0.72);
         backdrop-filter:saturate(180%) blur(28px);
         -webkit-backdrop-filter:saturate(180%) blur(28px);
         border-radius:22px;
         box-shadow:
           0 1px 0 rgba(255,255,255,0.9) inset,
           0 1px 2px rgba(0,0,0,0.04),
           0 18px 50px rgba(60,70,90,0.12),
           0 6px 18px rgba(60,70,90,0.06);
         border:1px solid rgba(255,255,255,0.6); }
 .wrap::before { display:none; }
 header { display:flex; align-items:center; gap:16px; margin-bottom:22px;
          padding-bottom:18px; border-bottom:1px solid rgba(0,0,0,0.06); }
 header .logo { height:48px; width:auto; flex-shrink:0; }
 header .logo-placeholder { height:48px; min-width:48px; border-radius:10px;
          background:linear-gradient(135deg,#3a3a3a,#1a1a1a); color:#fff;
          display:flex; align-items:center; justify-content:center;
          font-weight:800; font-size:20px; letter-spacing:0.04em; padding:0 12px; flex-shrink:0; }
 header .brand-text { display:flex; flex-direction:column; gap:3px; min-width:0; flex:1; }
 header h1 { font-size:24px; margin:0; font-weight:600; letter-spacing:-0.02em; line-height:1.25; color:#1d1d1f; }
 header .sub { color:#6e6e73; font-size:12.5px; line-height:1.4; }

 /* 頁籤導覽 — 彩色玻璃方格 */
 .tabs { display:flex; gap:8px; padding:10px; margin:0 0 24px; border-radius:18px;
         background:rgba(255,255,255,0.55);
         backdrop-filter:saturate(180%) blur(24px);
         -webkit-backdrop-filter:saturate(180%) blur(24px);
         border:1px solid rgba(255,255,255,0.7);
         flex-wrap:wrap;
         position:sticky; top:10px; z-index:50;
         box-shadow:
           0 1px 0 rgba(255,255,255,0.8) inset,
           0 4px 14px rgba(60,70,90,0.08),
           0 1px 3px rgba(0,0,0,0.04); }
 .tab { padding:10px 16px; border-radius:14px; font-size:13px; font-weight:600;
        cursor:pointer; border:1px solid rgba(255,255,255,0.55);
        font-family:inherit;
        transition:transform .35s cubic-bezier(0.34,1.56,0.64,1),
                   box-shadow .35s cubic-bezier(0.34,1.56,0.64,1),
                   background .25s, color .2s;
        letter-spacing:-0.003em;
        color:#1d1d1f;
        min-height:40px;
        display:inline-flex; align-items:center; gap:8px;
        white-space:nowrap;
        backdrop-filter:saturate(160%) blur(14px);
        -webkit-backdrop-filter:saturate(160%) blur(14px);
        box-shadow:
          0 1px 0 rgba(255,255,255,0.85) inset,
          0 1px 2px rgba(0,0,0,0.05),
          0 4px 10px rgba(60,70,90,0.06);
        position:relative; overflow:hidden; }
 /* 玻璃高光 — 模擬液態流動 */
 .tab::after { content:''; position:absolute; top:0; left:-30%; width:30%; height:100%;
               background:linear-gradient(115deg, transparent, rgba(255,255,255,0.55), transparent);
               transform:skewX(-20deg);
               transition:left .7s ease;
               pointer-events:none; }
 .tab:hover::after { left:130%; }
 .tab em { font-style:normal; font-weight:600; font-size:11.5px;
           color:rgba(0,0,0,0.55); padding:1px 7px; border-radius:99px;
           background:rgba(255,255,255,0.7); margin-left:2px;
           border:1px solid rgba(0,0,0,0.04); }
 /* 頁籤小色點 — 強化辨識 */
 .tab::before { content:''; display:inline-block; width:9px; height:9px;
                border-radius:50%; flex-shrink:0; background:#cbd5e1;
                box-shadow:0 0 0 2px rgba(255,255,255,0.6),
                           0 1px 2px rgba(0,0,0,0.15); }

 /* 每個 tab 自己的玻璃漸層底色 */
 .tab[data-tab="all"]     { background:linear-gradient(135deg, rgba(232,236,242,0.75), rgba(214,220,230,0.55)); }
 .tab[data-tab="main"]    { background:linear-gradient(135deg, rgba(186,213,243,0.75), rgba(146,184,228,0.55)); }
 .tab[data-tab="carbon"]  { background:linear-gradient(135deg, rgba(190,228,200,0.75), rgba(154,206,170,0.55)); }
 .tab[data-tab="mfg"]     { background:linear-gradient(135deg, rgba(214,200,235,0.75), rgba(184,164,218,0.55)); }
 .tab[data-tab="tech"]    { background:linear-gradient(135deg, rgba(216,228,178,0.75), rgba(186,206,142,0.55)); }
 .tab[data-tab="plastic"] { background:linear-gradient(135deg, rgba(244,202,222,0.75), rgba(228,164,196,0.55)); }
 .tab[data-tab="metal"]   { background:linear-gradient(135deg, rgba(232,212,178,0.75), rgba(206,180,140,0.55)); }
 .tab[data-tab="app"]     { background:linear-gradient(135deg, rgba(176,222,222,0.75), rgba(132,194,194,0.55)); }
 .tab[data-tab="fiber"]   { background:linear-gradient(135deg, rgba(244,196,168,0.75), rgba(226,158,124,0.55)); }
 .tab[data-tab="fun"]     { background:linear-gradient(135deg, rgba(248,228,158,0.75), rgba(232,202,118,0.55)); }
 .tab[data-tab="food"]    { background:linear-gradient(135deg, rgba(240,178,178,0.75), rgba(216,134,134,0.55)); }
 .tab[data-tab="local"]   { background:linear-gradient(135deg, rgba(220,196,170,0.75), rgba(192,162,128,0.55)); }
 .tab[data-tab="ren"]     { background:linear-gradient(135deg, rgba(238,210,168,0.75), rgba(218,182,128,0.55)); }
 .tab[data-tab="kid"]     { background:linear-gradient(135deg, rgba(248,206,200,0.75), rgba(228,168,156,0.55)); }
 .tab[data-tab="weather"] { background:linear-gradient(135deg, rgba(180,210,240,0.75), rgba(140,182,224,0.55)); }
 .tab[data-tab="beer"]    { background:linear-gradient(135deg, rgba(240,214,170,0.75), rgba(218,184,128,0.55)); }

 /* 對應的色點 */
 .tab[data-tab="all"]::before     { background:#5a6478; }
 .tab[data-tab="main"]::before    { background:#3b6fb6; }
 .tab[data-tab="carbon"]::before  { background:#3f8f5a; }
 .tab[data-tab="mfg"]::before     { background:#8a5fb8; }
 .tab[data-tab="tech"]::before    { background:#7c9230; }
 .tab[data-tab="plastic"]::before { background:#c64a8c; }
 .tab[data-tab="metal"]::before   { background:#a07a3a; }
 .tab[data-tab="app"]::before     { background:#2d8a8a; }
 .tab[data-tab="fiber"]::before   { background:#c45a2a; }
 .tab[data-tab="fun"]::before     { background:#c49a2a; }
 .tab[data-tab="food"]::before    { background:#b03a3a; }
 .tab[data-tab="local"]::before   { background:#7a5a3a; }
 .tab[data-tab="ren"]::before     { background:#a07a3a; }
 .tab[data-tab="kid"]::before     { background:#c47565; }
 .tab[data-tab="weather"]::before { background:#3d72b8; }
 .tab[data-tab="beer"]::before    { background:#a87a3a; }

 /* hover / 觸控放大感 */
 .tab:hover {
   transform:translateY(-2px) scale(1.06);
   box-shadow:
     0 1px 0 rgba(255,255,255,0.9) inset,
     0 4px 8px rgba(0,0,0,0.08),
     0 14px 28px rgba(60,70,90,0.18);
 }
 .tab:active { transform:translateY(0) scale(0.98); transition-duration:.1s; }

 /* Active：飽和加深 + 更強陰影飄浮 */
 .tab.active {
   color:#0d0d0f !important;
   transform:translateY(-1px) scale(1.04);
   box-shadow:
     0 1px 0 rgba(255,255,255,0.95) inset,
     0 0 0 2px rgba(255,255,255,0.7),
     0 6px 14px rgba(0,0,0,0.10),
     0 16px 32px rgba(60,70,90,0.20);
   border-color:rgba(255,255,255,0.8);
 }
 .tab.active::before {
   transform:scale(1.2);
   box-shadow:0 0 0 2px rgba(255,255,255,0.85), 0 1px 3px rgba(0,0,0,0.25);
 }

 .hero-row { display:grid; grid-template-columns:1.5fr 1fr; gap:14px; margin-bottom:14px; }

 /* 碳纖維專屬 grid（獨立區塊用） */
 .carbon-grid { display:grid; grid-template-columns:repeat(2, 1fr); gap:10px; }
 .carbon-section .carbon-item { background:rgba(255,255,255,0.82);
                                 backdrop-filter:saturate(160%) blur(14px);
                                 -webkit-backdrop-filter:saturate(160%) blur(14px);
                                 border:1px solid rgba(255,255,255,0.6);
                                 border-radius:14px; padding:14px 18px;
                                 box-shadow:
                                   0 1px 0 rgba(255,255,255,0.85) inset,
                                   0 1px 2px rgba(0,0,0,0.04),
                                   0 6px 16px rgba(60,70,90,0.08);
                                 transition:transform .35s cubic-bezier(0.34,1.56,0.64,1),
                                            box-shadow .35s cubic-bezier(0.34,1.56,0.64,1); }
 .carbon-section .carbon-item:hover {
   transform:translateY(-4px) scale(1.02);
   box-shadow:
     0 1px 0 rgba(255,255,255,0.95) inset,
     0 2px 4px rgba(0,0,0,0.05),
     0 14px 28px rgba(60,70,90,0.16),
     0 24px 48px rgba(60,70,90,0.10);
 }
 .carbon-section .carbon-item:active { transform:translateY(-1px) scale(1.005); transition-duration:.15s; }
 .grid { display:grid; grid-template-columns:repeat(3,1fr); gap:14px; }

 .card { background:rgba(255,255,255,0.85);
         backdrop-filter:saturate(160%) blur(18px);
         -webkit-backdrop-filter:saturate(160%) blur(18px);
         border-radius:20px; overflow:hidden;
         box-shadow:
           0 1px 0 rgba(255,255,255,0.9) inset,
           0 1px 2px rgba(0,0,0,0.04),
           0 8px 22px rgba(60,70,90,0.10),
           0 22px 44px rgba(60,70,90,0.06);
         border:1px solid rgba(255,255,255,0.65);
         transition:transform .4s cubic-bezier(0.34,1.56,0.64,1),
                    box-shadow .4s cubic-bezier(0.34,1.56,0.64,1); }
 .card:hover, .card:focus-within {
   transform:translateY(-6px) scale(1.025);
   box-shadow:
     0 1px 0 rgba(255,255,255,0.95) inset,
     0 2px 4px rgba(0,0,0,0.05),
     0 16px 36px rgba(60,70,90,0.18),
     0 36px 64px rgba(60,70,90,0.14);
 }
 .card:active { transform:translateY(-2px) scale(1.01); transition-duration:.15s; }
 details { cursor:pointer; }
 details > summary { list-style:none; cursor:pointer; display:block; }
 details > summary::-webkit-details-marker { display:none; }

 /* Hero */
 .hero { position:relative; min-height:440px; display:flex; flex-direction:column; }
 .hero > summary { flex:1; position:relative; min-height:440px; }
 .hero-img { position:absolute; inset:0; background-size:cover;
             background-position:center; background-repeat:no-repeat; }
 .hero-overlay { position:absolute; inset:0;
             background:linear-gradient(to top,rgba(0,0,0,0.85) 0%,rgba(0,0,0,0.35) 45%,transparent 75%); }
 .hero-caption { position:absolute; bottom:0; left:0; right:0; padding:24px 26px; color:#fff; z-index:1; }
 .hero-caption h2 { font-size:22px; margin:10px 0 8px; line-height:1.35;
             text-shadow:0 2px 12px rgba(0,0,0,0.55); font-weight:700; }
 .hero-caption .meta { font-size:12.5px; opacity:0.9; }

 /* List */
 .list { padding:18px 20px; }
 .list h3, .carbon h3 { margin:0 0 12px; font-size:14.5px; font-weight:700; display:flex; align-items:baseline; gap:8px; }
 .list h3 .sub, .carbon h3 .sub { font-size:11px; color:#86868b; font-weight:400; }
 .list-item { border-bottom:1px solid rgba(0,0,0,0.06); padding:10px 0; }
 .list-item:last-of-type { border-bottom:none; padding-bottom:0; }
 .list-item summary { display:flex; gap:12px; align-items:flex-start; }
 .list-thumb { width:68px; height:68px; flex-shrink:0; border-radius:8px;
               background-size:cover; background-position:center; }
 .list-caption { flex:1; min-width:0; }
 .list-caption h4 { font-size:13.5px; margin:0 0 5px; line-height:1.4; font-weight:600; color:#1d1d1f;
                    display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
 .list-caption .meta { font-size:11px; color:#6e6e73; display:flex; align-items:center; gap:6px; flex-wrap:wrap; }

 /* Carbon Fiber 右側面板 */
 .carbon { padding:18px 18px 14px; display:flex; flex-direction:column; min-height:0; }
 .carbon-list { overflow-y:auto; flex:1; min-height:0; margin:0 -8px; padding:0 8px 4px; }
 .carbon-list::-webkit-scrollbar { width:5px; }
 .carbon-list::-webkit-scrollbar-thumb { background:rgba(0,0,0,0.15); border-radius:3px; }
 .carbon-list::-webkit-scrollbar-track { background:transparent; }
 .carbon-item { border-bottom:1px solid rgba(0,0,0,0.06); padding:8px 0; }
 .carbon-item:last-of-type { border-bottom:none; }
 .carbon-item summary { display:flex; gap:10px; align-items:flex-start; }
 .carbon-badge { flex-shrink:0; font-size:10px; font-weight:700; padding:2px 6px;
                 background:linear-gradient(135deg,#2a2a2a,#555); color:#fff;
                 border-radius:4px; letter-spacing:0.04em; margin-top:2px; }
 .carbon-line { flex:1; min-width:0; }
 .carbon-line h4 { font-size:12.5px; margin:0 0 3px; line-height:1.4; font-weight:600; color:#1d1d1f;
                   display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
 .carbon-line .meta { font-size:10.5px; color:#6e6e73; }
 .carbon-empty { font-size:12px; color:#86868b; padding:20px 4px; text-align:center; }
 .carbon-item .detail { padding:10px 4px 4px; background:transparent; border-top:1px dashed rgba(184,149,107,0.30); margin-top:8px; font-size:12px; }

 /* Tile */
 .tile-img { width:100%; aspect-ratio:16/9; background-size:cover; background-position:center; }
 .tile-body { padding:12px 14px 14px; }
 .tile-body h3 { font-size:14.5px; margin:8px 0 6px; line-height:1.45; font-weight:600; color:#1d1d1f;
                 display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
 .tile-body .meta { font-size:11.5px; color:#6e6e73; }

 /* 複材應用／超級纖維面板 */
 .panel-section { margin-top:34px; }
 .panel-section:first-of-type { margin-top:0; }
 .panel-title { font-size:18px; margin:0 0 14px; font-weight:700;
                display:flex; align-items:baseline; gap:10px; flex-wrap:wrap;
                padding-bottom:10px; border-bottom:3px solid transparent; }
 .app-section .panel-title   { border-bottom-color:#5a7a90; }
 .fiber-section .panel-title { border-bottom-color:#a85a3a; }
 .mfg-section .panel-title   { border-bottom-color:#7c3a3a; }
 .tech-section .panel-title  { border-bottom-color:#7a8a5a; }
 .plastic-section .panel-title { border-bottom-color:#c47a8c; }
 .metal-section .panel-title   { border-bottom-color:#b8956b; }
 .fun-section .panel-title     { border-bottom-color:#c4a04a; }
 .food-section .panel-title    { border-bottom-color:#7a2a3a; }
 .local-section .panel-title   { border-bottom-color:#5a3a2a; }
 .ren-section .panel-title     { border-bottom-color:#a07a5a; }
 .kid-section .panel-title     { border-bottom-color:#c48899; }
 .weather-section .panel-title { border-bottom-color:#3d5a80; }
 .beer-section .panel-title    { border-bottom-color:#b8895c; }

 /* 天氣儀表板卡片 */
 .weather-card { background:linear-gradient(180deg,rgba(254,250,240,0.92) 0%,rgba(248,242,228,0.82) 100%);
                 backdrop-filter:blur(20px) saturate(120%);
                 -webkit-backdrop-filter:blur(20px) saturate(120%);
                 border-radius:6px; padding:22px 26px; margin:0 0 14px;
                 border:1px solid rgba(184,149,107,0.32);
                 box-shadow:inset 0 1px 0 rgba(255,255,255,0.85),0 6px 20px rgba(80,60,30,0.10); }
 .weather-current { display:flex; align-items:center; gap:18px; flex-wrap:wrap;
                    padding-bottom:18px; border-bottom:1px solid rgba(184,149,107,0.25); }
 .weather-emoji { font-size:52px; line-height:1; }
 .weather-temp { font-size:54px; font-weight:700; color:#3d5a80; line-height:1;
                 letter-spacing:-0.02em; }
 .weather-info { flex:1; min-width:200px; }
 .weather-label { font-size:18px; font-weight:600; color:#1d1d1f; }
 .weather-sub { font-size:13px; color:#6e6e73; margin-top:4px; }
 .weather-loc { color:#6e6e73; font-size:13px; font-weight:600; }
 .weather-forecast { display:grid; grid-template-columns:repeat(5,1fr); gap:10px;
                     padding:16px 0; border-bottom:1px solid rgba(184,149,107,0.25); }
 .weather-day { text-align:center; padding:12px 8px;
                background:linear-gradient(180deg,rgba(255,255,255,0.6),rgba(248,242,228,0.4));
                border-radius:4px;
                border:1px solid rgba(184,149,107,0.20); }
 .day-name { font-weight:700; font-size:13.5px; color:#3d5a80; }
 .day-icon { font-size:24px; margin:4px 0; }
 .day-temp { font-size:13px; font-weight:600; color:#1d1d1f; }
 .day-label { font-size:11.5px; color:#6e6e73; margin-top:2px; }
 .day-rain { font-size:11px; color:#5a7a90; margin-top:2px; }
 .aqi-section { padding-top:14px; }
 .aqi-section h3 { font-size:13px; color:#6e6e73; margin:0 0 10px; font-weight:600; }
 .aqi-list { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:6px; }
 .aqi-row { display:grid; grid-template-columns:1fr auto auto; gap:6px;
            padding:6px 10px; border-radius:6px; align-items:center; font-size:12px; }
 .aqi-row .site { font-weight:600; }
 .aqi-row strong { font-size:15px; }
 .aqi-row .status { font-size:11px; }
 .aqi-good           { background:#dcfce7; color:#166534; }
 .aqi-moderate       { background:#fef9c3; color:#854d0e; }
 .aqi-unhealthy-sg   { background:#fed7aa; color:#9a3412; }
 .aqi-unhealthy      { background:#fecaca; color:#991b1b; }
 .aqi-very-unhealthy { background:#e9d5ff; color:#6b21a8; }
 .aqi-hazardous      { background:#4c0519; color:#fff; }

 @media (max-width:700px) {
   .weather-forecast { grid-template-columns:repeat(3,1fr); }
   .weather-temp { font-size:44px; }
 }
 .panel-title .sub { font-size:12.5px; color:#6e6e73; font-weight:400; letter-spacing:0.02em; }
 .mini-grid { display:grid; grid-template-columns:repeat(3, 1fr); gap:12px; }
 .mini-tile { background:rgba(255,255,255,0.82);
              backdrop-filter:saturate(160%) blur(16px);
              -webkit-backdrop-filter:saturate(160%) blur(16px);
              border-radius:18px; overflow:hidden;
              box-shadow:
                0 1px 0 rgba(255,255,255,0.9) inset,
                0 1px 2px rgba(0,0,0,0.04),
                0 6px 18px rgba(60,70,90,0.10),
                0 18px 36px rgba(60,70,90,0.05);
              border:1px solid rgba(255,255,255,0.65);
              transition:transform .4s cubic-bezier(0.34,1.56,0.64,1),
                         box-shadow .4s cubic-bezier(0.34,1.56,0.64,1); }
 .mini-tile:hover, .mini-tile:focus-within {
   transform:translateY(-5px) scale(1.03);
   box-shadow:
     0 1px 0 rgba(255,255,255,0.95) inset,
     0 2px 4px rgba(0,0,0,0.05),
     0 14px 30px rgba(60,70,90,0.18),
     0 30px 56px rgba(60,70,90,0.12);
 }
 .mini-tile:active { transform:translateY(-2px) scale(1.01); transition-duration:.15s; }
 .mini-img { width:100%; aspect-ratio:16/9; background-size:cover; background-position:center;
             position:relative; overflow:hidden; }
 .img-overlay { position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
                color:rgba(255,255,255,0.95); font-size:16px; font-weight:700; text-align:center;
                padding:16px; letter-spacing:0.03em; text-shadow:0 2px 10px rgba(0,0,0,0.35);
                background:linear-gradient(135deg, rgba(0,0,0,0.15), rgba(0,0,0,0.0) 50%); }
 .mini-body { padding:10px 13px 12px; }
 .mini-body h4 { font-size:13.5px; margin:0 0 5px; line-height:1.45; font-weight:600; color:#1d1d1f;
                 display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
 .mini-body .meta { font-size:11px; color:#6e6e73; }

 .tags { display:flex; gap:6px; align-items:center; }
 .tag { font-size:10.5px; padding:2px 9px; border-radius:999px;
        color:#fff; font-weight:600; letter-spacing:0.03em; }
 .tag.tiny { font-size:10px; padding:1px 7px; }
 .lang { font-size:10px; padding:1px 6px; border-radius:3px;
         background:rgba(255,255,255,0.10); color:#d0d0d6; font-weight:600; }
 .lang.dark { background:rgba(255,255,255,0.25); color:#fff; }

 /* Detail expansion */
 .detail { padding:16px 20px 20px;
           background:#fafafc;
           border-top:1px solid #f0f0f3;
           font-size:13.5px; color:#1d1d1f; }
 .detail p { margin:0 0 10px; line-height:1.6; }
 .read-more-group { display:flex; gap:10px; align-items:center; margin-top:4px; flex-wrap:wrap; }
 .read-more { display:inline-block; padding:6px 12px;
              background:#5b87e0; color:#fff !important; font-size:12.5px;
              font-weight:600; border-radius:6px; text-decoration:none;
              transition:background .15s; }
 .read-more:hover { background:#4870c8; text-decoration:none; }
 .read-more-alt { color:#6e6e73; font-size:12px; text-decoration:none;
                  padding:4px 8px; border:1px solid #ddd; border-radius:5px;
                  transition:color .15s, border-color .15s; }
 .read-more-alt:hover { color:#333; border-color:#aaa; text-decoration:none; }
 .carbon-item .read-more { padding:4px 10px; font-size:11.5px; }
 .carbon-item .read-more-alt { font-size:11px; padding:3px 7px; }
 .detail a { color:#5b87e0; text-decoration:none; font-weight:600; font-size:13px; }
 .detail a:hover { text-decoration:underline; }
 .hero .detail { padding:16px 26px 22px; }

 footer { margin-top:22px; padding-top:14px; border-top:1px solid rgba(0,0,0,0.07);
          text-align:center; font-size:11.5px; color:#86868b; }

 /* 點擊區域至少符合 Apple HIG 44px touch target（連結 / 詳情按鈕） */
 .card summary, .mini-tile summary, .list-item summary, .carbon-item summary {
   -webkit-tap-highlight-color:rgba(0,0,0,0.04);
 }

 @media (max-width:1000px) {
   .hero-row { grid-template-columns:1fr; }
   .carbon-grid { grid-template-columns:1fr; }
   .grid { grid-template-columns:repeat(2,1fr); }
   .hero { min-height:320px; }
   .hero > summary { min-height:320px; }
 }

 /* Apple HIG 行動體驗：tabs 改水平捲動、touch target ≥44px、層級單純化 */
 @media (max-width:768px) {
   .wrap { padding:18px 16px; margin:10px; border-radius:16px;
           box-shadow:0 1px 2px rgba(0,0,0,0.04),0 4px 16px rgba(0,0,0,0.05); }
   header { gap:12px; margin-bottom:18px; padding-bottom:14px; }
   header .logo { height:40px; }
   header .logo-placeholder { height:40px; min-width:40px; font-size:16px; padding:0 10px; }
   header h1 { font-size:19px; line-height:1.3; letter-spacing:-0.015em;
               white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
   header .sub { font-size:11.5px; }

   /* tabs：改成水平捲動條，避免 sticky 過高遮住內容 */
   .tabs { flex-wrap:nowrap; overflow-x:auto; overflow-y:visible;
           padding:10px 12px; margin:0 -16px 18px; border-radius:0;
           border-left:none; border-right:none;
           top:0; gap:8px;
           scroll-snap-type:x proximity;
           -webkit-overflow-scrolling:touch;
           scrollbar-width:none;
           background:rgba(255,255,255,0.78);
           backdrop-filter:saturate(180%) blur(22px);
           -webkit-backdrop-filter:saturate(180%) blur(22px);
           border-top:1px solid rgba(255,255,255,0.6);
           border-bottom:1px solid rgba(0,0,0,0.06); }
   .tabs::-webkit-scrollbar { display:none; }
   .tab { flex-shrink:0; padding:9px 14px; min-height:42px;
          font-size:13px; scroll-snap-align:start; border-radius:12px; }
   /* mobile 觸控放大替代 hover */
   .tab:active {
     transform:translateY(-1px) scale(1.04);
     box-shadow:
       0 1px 0 rgba(255,255,255,0.95) inset,
       0 4px 8px rgba(0,0,0,0.08),
       0 10px 20px rgba(60,70,90,0.18);
   }
   .card:active, .mini-tile:active {
     transform:translateY(-3px) scale(1.02);
   }

   /* hero/list/grid 全部單欄 */
   .grid { grid-template-columns:1fr; gap:12px; }
   .hero { min-height:300px; }
   .hero > summary { min-height:300px; }
   .hero-caption { padding:18px 18px; }
   .hero-caption h2 { font-size:18px; }
   .list { padding:14px 16px; }

   /* mini-grid 改為 2 欄 */
   .mini-grid { grid-template-columns:repeat(2,1fr); gap:10px; }
   .mini-tile { border-radius:14px; }
   .card { border-radius:14px; }

   /* panel 標題小一點 */
   .panel-section { margin-top:26px; }
   .panel-title { font-size:16px; }

   /* 天氣面板響應式 */
   .weather-card { padding:18px 18px; border-radius:14px; }
   .weather-temp { font-size:42px; }
   .weather-emoji { font-size:42px; }
   .weather-forecast { grid-template-columns:repeat(3,1fr); gap:8px; }
   .aqi-list { grid-template-columns:repeat(2,1fr); }

   /* detail 縮排 */
   .detail { padding:14px 16px 16px; font-size:13px; }
   .hero .detail { padding:14px 18px 18px; }
   .read-more { padding:8px 14px; font-size:13px; min-height:36px; display:inline-flex; align-items:center; }
 }

 @media (max-width:480px) {
   .wrap { padding:16px 14px; margin:8px; border-radius:14px; }
   header { gap:10px; }
   header h1 { font-size:17px; }
   header .sub { font-size:11px; }
   .mini-grid { grid-template-columns:1fr; }
   .weather-forecast { grid-template-columns:repeat(2,1fr); }
   .aqi-list { grid-template-columns:1fr; }
 }
</style>
</head>
<body>
<div class="wrap">
  <header>
    $logoHtml
    <div class="brand-text">
      <h1>TEi Composites Corporation 國際新聞</h1>
      <div class="sub">For 同仁 · 過去 24 小時 · $($picked.Count + $carbonPicked.Count + $appPicked.Count + $fiberPicked.Count) 則 · $dateStr</div>
    </div>
  </header>

  <nav class="tabs">
    <button type="button" class="tab active" data-tab="all">全部</button>
    <button type="button" class="tab" data-tab="weather">天氣預報</button>
    <button type="button" class="tab" data-tab="main">國際要聞 <em>$($picked.Count)</em></button>
    <button type="button" class="tab" data-tab="carbon">碳纖維即時 <em>$($carbonPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="mfg">碳纖製造商 <em>$($mfgPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="tech">複材技術 <em>$($techPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="app">市場情報 <em>$($appPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="fiber">超級纖維 <em>$($fiberPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="plastic">塑膠消息 <em>$($plasticPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="metal">世界金屬 <em>$($metalPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="fun">來點好心情 <em>$($funPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="food">給你的美食 <em>$($foodPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="local">台中咖啡好去處 <em>$($localFoodPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="kid">親子週末 <em>$($kidPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="beer">台中啤酒好地方 <em>$($beerPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="ren">和美搖飲(忍) <em>$($renShops.Count)</em></button>
  </nav>

  $weatherHtml

  <section class="hero-row" data-group="main">
    $heroHtml
    $listHtml
  </section>

  <section class="grid" data-group="main">
    $gridBody
  </section>

  $carbonHtml

  $mfgHtml

  $techHtml

  $appHtml

  $fiberHtml

  $plasticHtml

  $metalHtml

  $funHtml

  $foodHtml

  $localFoodHtml

  $kidHtml

  $beerHtml

  $renHtml

  <footer>純 RSS + PowerShell · 無 API · 零費用 · $dateStr</footer>
</div>
<script>
(function(){
  function show(name){
    document.querySelectorAll('.tab').forEach(function(t){
      t.classList.toggle('active', t.dataset.tab === name);
    });
    document.querySelectorAll('[data-group]').forEach(function(s){
      s.style.display = (name === 'all' || s.dataset.group === name) ? '' : 'none';
    });
    try { localStorage.setItem('activeTab', name); } catch(e){}
    window.scrollTo({top: 0, behavior: 'instant'});
  }
  document.querySelectorAll('.tab').forEach(function(t){
    t.addEventListener('click', function(){ show(t.dataset.tab); });
  });
  var saved = 'all';
  try { saved = localStorage.getItem('activeTab') || 'all'; } catch(e){}
  show(saved);
})();
</script>
</body>
</html>
"@

$outFile = Join-Path $outputDir 'latest.html'
$dated   = Join-Path $outputDir ((Get-Date -Format 'yyyy-MM-dd') + '.html')
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outFile, $htmlShell, $utf8NoBom)
[System.IO.File]::WriteAllText($dated,   $htmlShell, $utf8NoBom)

Write-Host ("`n已產出 {0}" -f $outFile) -ForegroundColor Green

# ---------- 7. 自動發佈到 GitHub Pages ----------
function Publish-FileToGitHub {
    # 把單一本地檔案推到 GitHub repo（PUT /contents/<path>），支援 409/422 衝突自動重試
    param([string]$LocalFile, [string]$RepoPath, [string]$Token, [string]$Repo, [string]$CommitMsg)
    $apiBase = "https://api.github.com/repos/$Repo/contents"
    $headers = @{
        Authorization = "token $Token"
        'User-Agent'  = 'TEi-News-Publisher'
        Accept        = 'application/vnd.github+json'
    }
    $bytes = [IO.File]::ReadAllBytes($LocalFile)
    $b64   = [Convert]::ToBase64String($bytes)

    # 最多重試 6 次（雲端 Actions 同時推時可能撞 sha）
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            # 每次重試都重新抓最新 sha，避免再次撞牆
            $sha = $null
            try {
                $existing = Invoke-RestMethod -Uri "$apiBase/$RepoPath" -Headers $headers -Method Get -ErrorAction Stop
                $sha = $existing.sha
                if ($existing.content -and (($existing.content -replace '\s','') -eq $b64)) { return $true }
            } catch { }

            $body = @{
                message = $CommitMsg
                content = $b64
                branch  = 'main'
            }
            if ($sha) { $body.sha = $sha }
            $json = ($body | ConvertTo-Json -Compress)
            $jsonBytes = [Text.Encoding]::UTF8.GetBytes($json)
            Invoke-RestMethod -Uri "$apiBase/$RepoPath" -Headers $headers -Method Put -Body $jsonBytes -ContentType 'application/json; charset=utf-8' | Out-Null
            return $true
        } catch {
            $msg = $_.Exception.Message
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            # 409 衝突 / 422 sha 過期 → 重抓 sha 重試
            if ($status -eq 409 -or $status -eq 422) {
                Start-Sleep -Milliseconds (300 + (Get-Random -Maximum 700))
                continue
            }
            # 其他錯誤直接結束
            if ($attempt -eq 6) {
                Write-Host ("  [失敗] {0}: {1}" -f $RepoPath, $msg) -ForegroundColor Yellow
            }
            return $false
        }
    }
    Write-Host ("  [失敗] {0}: 超過 6 次衝突重試" -f $RepoPath) -ForegroundColor Yellow
    return $false
}

function Publish-ToGitHub {
    param([string]$LocalFile)
    $tokenFile = Join-Path $PSScriptRoot '.github_token'
    $repoFile  = Join-Path $PSScriptRoot '.github_repo'
    if (-not (Test-Path $tokenFile) -or -not (Test-Path $repoFile)) {
        Write-Host '[發佈] 未設定 .github_token / .github_repo，跳過上傳' -ForegroundColor DarkGray
        return
    }
    $token = (Get-Content $tokenFile -Raw).Trim()
    $repo  = (Get-Content $repoFile -Raw).Trim()
    if (-not $token -or -not $repo) { return }

    try {
        # 主要：產出的 HTML 上傳為 index.html
        $date = Get-Date -Format 'yyyy-MM-dd HH:mm'
        Publish-FileToGitHub -LocalFile $LocalFile -RepoPath 'index.html' -Token $token -Repo $repo -CommitMsg "Daily update $date" | Out-Null

        # 同步腳本／LOGO／搖飲店家資料／workflow（供 Actions 使用）
        # 本機 PS1 是中文檔名，repo 上是英文檔名（給 Actions 用）
        $syncTargets = @(
            @{ Local='抓新聞_fetch_news.ps1'; Repo='fetch_news.ps1' }
            @{ Local='logo.png';              Repo='logo.png' }
            @{ Local='logo.svg';              Repo='logo.svg' }
            @{ Local='ren-shops.json';        Repo='ren-shops.json' }
            @{ Local='.github/workflows/update-news.yml'; Repo='.github/workflows/update-news.yml' }
        )
        foreach ($t in $syncTargets) {
            $p = Join-Path $PSScriptRoot $t.Local
            if (Test-Path $p) {
                Publish-FileToGitHub -LocalFile $p -RepoPath $t.Repo -Token $token -Repo $repo -CommitMsg "sync $($t.Repo)" | Out-Null
            }
        }

        $repoParts = $repo.Split('/')
        $pagesUrl = "https://$($repoParts[0]).github.io/$($repoParts[1])/"
        Write-Host "[發佈] 已上傳 → $pagesUrl" -ForegroundColor Green
    } catch {
        Write-Host "[發佈] 上傳失敗: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 每次都推 GitHub（Publish-FileToGitHub 已內建 409/422 衝突自動重試 6 次）
# 因為實測 GitHub Actions cron 在免費版會被嚴重 throttle，
# 本機 Task Scheduler 才是 10 分鐘準時更新的主力。
Publish-ToGitHub -LocalFile $outFile
if ($OpenBrowser) { Start-Process $outFile }

try { Stop-Transcript | Out-Null } catch { }
