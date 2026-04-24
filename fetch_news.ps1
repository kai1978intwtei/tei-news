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
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
        $action = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -WorkingDirectory (Split-Path $PSCommandPath)

        # 早上 07:00 + 下午 14:00 各一次（每天兩趟）
        $trigger1 = New-ScheduledTaskTrigger -Daily -At 7am
        $trigger2 = New-ScheduledTaskTrigger -Daily -At 2pm

        $settings = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -RunOnlyIfNetworkAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger @($trigger1, $trigger2) `
            -Settings $settings `
            -Principal $principal | Out-Null

        Write-Host '[setup] 已設定每日 07:00 與 14:00 自動執行（工作排程器）' -ForegroundColor Green
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
    @{ Name='NYT World';      Url='https://rss.nytimes.com/services/xml/rss/nyt/World.xml';                                      Lang='en'; Weight=1.1 }
    @{ Name='NYT Business';   Url='https://rss.nytimes.com/services/xml/rss/nyt/Business.xml';                                   Lang='en'; Weight=1.1 }
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
    @{ Name='Toray';              Url='https://news.google.com/rss/search?q=Toray+(carbon+fiber+OR+carbon+composite+OR+Torayca)&hl=en-US&gl=US&ceid=US:en';                            Lang='en'; Weight=1.2 }
    @{ Name='Hexcel';             Url='https://news.google.com/rss/search?q=Hexcel+(carbon+OR+composite+OR+HexTow+OR+HexPly+OR+prepreg)&hl=en-US&gl=US&ceid=US:en';                  Lang='en'; Weight=1.2 }
    @{ Name='Teijin';             Url='https://news.google.com/rss/search?q=Teijin+(carbon+fiber+OR+Tenax+OR+composite+OR+Sereebo)&hl=en-US&gl=US&ceid=US:en';                       Lang='en'; Weight=1.2 }
    @{ Name='Mitsubishi Chemical';Url='https://news.google.com/rss/search?q=%22Mitsubishi+Chemical%22+(carbon+fiber+OR+Grafil+OR+DIALEAD+OR+Pyrofil)&hl=en-US&gl=US&ceid=US:en';      Lang='en'; Weight=1.2 }
    @{ Name='SGL Carbon';         Url='https://news.google.com/rss/search?q=%22SGL+Carbon%22+(carbon+fiber+OR+composite+OR+SIGRAFIL)&hl=en-US&gl=US&ceid=US:en';                     Lang='en'; Weight=1.1 }
    @{ Name='Solvay / Syensqo';   Url='https://news.google.com/rss/search?q=(Solvay+OR+Syensqo)+(carbon+OR+composite+OR+prepreg+OR+thermoset)&hl=en-US&gl=US&ceid=US:en';            Lang='en'; Weight=1.1 }
    @{ Name='Formosa / TAIRYFIL'; Url='https://news.google.com/rss/search?q=(%22Formosa+Plastics%22+OR+TAIRYFIL)+(carbon+fiber+OR+composite)&hl=en-US&gl=US&ceid=US:en';             Lang='en'; Weight=1.1 }
    @{ Name='Hyosung';            Url='https://news.google.com/rss/search?q=Hyosung+(carbon+fiber+OR+TANSOME+OR+TANFOCUS+OR+composite)&hl=en-US&gl=US&ceid=US:en';                  Lang='en'; Weight=1.1 }
    @{ Name='DowAksa';            Url='https://news.google.com/rss/search?q=DowAksa+(carbon+fiber+OR+composite)&hl=en-US&gl=US&ceid=US:en';                                           Lang='en'; Weight=1.0 }
    @{ Name='中國碳纖維業者';      Url='https://news.google.com/rss/search?q=(%22Jilin+Chemical+Fiber%22+OR+%22Zhongfu+Shenying%22+OR+%22Sinofibers%22)+carbon&hl=en-US&gl=US&ceid=US:en'; Lang='en'; Weight=1.0 }
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
$all = New-Object System.Collections.Generic.List[object]
foreach ($src in $Sources) {
    $items = Get-RssItems $src
    foreach ($it in $items) {
        $pub = Parse-Date $it.Pub
        if ($pub -and ((Get-Date).ToUniversalTime() - $pub).TotalHours -gt 24) { continue }
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

# URL 域名黑名單（電商／產品站）
$BadDomains = @(
    'amazon\.', 'ebay\.', 'walmart\.', 'aliexpress\.', 'alibaba\.',
    'etsy\.', 'shopee\.', 'lazada\.', 'wish\.com',
    'aplusme', 'bikesdirect\.', 'competitivecyclist',
    'backcountry\.', 'rei\.com', 'dickssportinggoods',
    'monoprice\.', 'vevor\.', 'temu\.',
    'gsm\w*arena', 'notebookcheck\.'  # 科技產品評測站
)

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
            })
        }
    }
    if ($all.Count -eq 0) { return ,@() }
    $unique = @($all | Group-Object Link | ForEach-Object { $_.Group | Select-Object -First 1 })
    $sorted = @($unique | Where-Object { $_.Pub -is [datetime] } | Sort-Object Pub -Descending)

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
$mfgPicked = Get-SecondaryPanel -sources $ManufacturerSources -maxItems 12 -days 90 -descCap 180 -requireSignals $MarketSignalPatterns
Write-Host ("  → 挑出 {0} 則製造商新聞" -f $mfgPicked.Count)

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
Add-PanelImages $appPicked '市場情報'
Add-PanelImages $fiberPicked '超級纖維'

# ---------- 5b. 翻譯英文內容為中文（主新聞 + 碳纖維新聞）----------
$allToTranslate = New-Object System.Collections.Generic.List[object]
foreach ($p in $picked)       { [void]$allToTranslate.Add($p) }
foreach ($p in $carbonPicked) { [void]$allToTranslate.Add($p) }
foreach ($p in $mfgPicked)    { [void]$allToTranslate.Add($p) }
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
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="1800">
<title>TEi Composites · 國際新聞 · $dateStr</title>
<style>
 * { box-sizing: border-box; }
 body { margin:0; min-height:100vh; color:#1a1d24; line-height:1.5;
        font-family:"Microsoft JhengHei","PingFang TC",-apple-system,"Segoe UI",sans-serif;
        background:linear-gradient(135deg,#c9d6ff 0%,#e2dbf5 50%,#ffd8e5 100%);
        background-attachment:fixed; }
 .wrap { max-width:1320px; margin:28px auto; padding:28px;
         background:rgba(255,255,255,0.72);
         backdrop-filter:blur(28px) saturate(180%);
         -webkit-backdrop-filter:blur(28px) saturate(180%);
         border-radius:22px; box-shadow:0 12px 48px rgba(60,50,110,0.14);
         border:1px solid rgba(255,255,255,0.5); }
 header { display:flex; align-items:center; gap:16px; margin-bottom:22px;
          padding-bottom:18px; border-bottom:1px solid rgba(0,0,0,0.06); }
 header .logo { height:52px; width:auto; flex-shrink:0; }
 header .logo-placeholder { height:52px; min-width:52px; border-radius:10px;
          background:linear-gradient(135deg,#3a3a3a,#1a1a1a); color:#fff;
          display:flex; align-items:center; justify-content:center;
          font-weight:800; font-size:22px; letter-spacing:0.04em; padding:0 14px; }
 header .brand-text { display:flex; flex-direction:column; gap:2px; }
 header h1 { font-size:22px; margin:0; font-weight:700; letter-spacing:-0.01em; line-height:1.2; }
 header .sub { color:#666; font-size:12.5px; }

 /* 頁籤導覽 */
 .tabs { display:flex; gap:6px; padding:8px; margin:0 0 18px; border-radius:12px;
         background:rgba(255,255,255,0.85); backdrop-filter:blur(12px);
         box-shadow:0 2px 10px rgba(0,0,0,0.06); flex-wrap:wrap;
         position:sticky; top:10px; z-index:50; }
 .tab { padding:9px 16px; border-radius:8px; font-size:14px; font-weight:600;
        color:#555; cursor:pointer; border:none; background:transparent;
        font-family:inherit; transition:all .15s; display:inline-flex; align-items:center; gap:6px; }
 .tab em { font-style:normal; font-weight:400; font-size:12px;
           color:#999; padding:1px 7px; border-radius:99px; background:#f0f0f4; }
 .tab:hover { background:#f4f6fa; color:#222; }
 .tab.active { background:#0891b2; color:#fff; box-shadow:0 2px 8px rgba(8,145,178,0.3); }
 .tab.active em { background:rgba(255,255,255,0.25); color:#fff; }

 .hero-row { display:grid; grid-template-columns:1.5fr 1fr; gap:14px; margin-bottom:14px; }

 /* 碳纖維專屬 grid（獨立區塊用） */
 .carbon-grid { display:grid; grid-template-columns:repeat(2, 1fr); gap:10px; }
 .carbon-section .carbon-item { background:#fff; border-radius:10px; padding:14px 18px;
                                 box-shadow:0 1px 6px rgba(0,0,0,0.05);
                                 transition:transform .15s, box-shadow .15s; }
 .carbon-section .carbon-item:hover { transform:translateY(-2px); box-shadow:0 6px 14px rgba(0,0,0,0.08); }
 .grid { display:grid; grid-template-columns:repeat(3,1fr); gap:14px; }

 .card { background:#fff; border-radius:14px; overflow:hidden;
         box-shadow:0 2px 10px rgba(0,0,0,0.05);
         transition:transform .18s, box-shadow .18s; }
 .card:hover { transform:translateY(-2px); box-shadow:0 8px 20px rgba(0,0,0,0.1); }
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
 .list h3 .sub, .carbon h3 .sub { font-size:11px; color:#999; font-weight:400; }
 .list-item { border-bottom:1px solid #eee; padding:10px 0; }
 .list-item:last-of-type { border-bottom:none; padding-bottom:0; }
 .list-item summary { display:flex; gap:12px; align-items:flex-start; }
 .list-thumb { width:68px; height:68px; flex-shrink:0; border-radius:8px;
               background-size:cover; background-position:center; }
 .list-caption { flex:1; min-width:0; }
 .list-caption h4 { font-size:13.5px; margin:0 0 5px; line-height:1.4; font-weight:600; color:#1a1d24;
                    display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
 .list-caption .meta { font-size:11px; color:#666; display:flex; align-items:center; gap:6px; flex-wrap:wrap; }

 /* Carbon Fiber 右側面板 */
 .carbon { padding:18px 18px 14px; display:flex; flex-direction:column; min-height:0; }
 .carbon-list { overflow-y:auto; flex:1; min-height:0; margin:0 -8px; padding:0 8px 4px; }
 .carbon-list::-webkit-scrollbar { width:5px; }
 .carbon-list::-webkit-scrollbar-thumb { background:rgba(0,0,0,0.15); border-radius:3px; }
 .carbon-list::-webkit-scrollbar-track { background:transparent; }
 .carbon-item { border-bottom:1px solid #eee; padding:8px 0; }
 .carbon-item:last-of-type { border-bottom:none; }
 .carbon-item summary { display:flex; gap:10px; align-items:flex-start; }
 .carbon-badge { flex-shrink:0; font-size:10px; font-weight:700; padding:2px 6px;
                 background:linear-gradient(135deg,#2a2a2a,#555); color:#fff;
                 border-radius:4px; letter-spacing:0.04em; margin-top:2px; }
 .carbon-line { flex:1; min-width:0; }
 .carbon-line h4 { font-size:12.5px; margin:0 0 3px; line-height:1.4; font-weight:600; color:#1a1d24;
                   display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
 .carbon-line .meta { font-size:10.5px; color:#666; }
 .carbon-empty { font-size:12px; color:#999; padding:20px 4px; text-align:center; }
 .carbon-item .detail { padding:10px 4px 4px; background:transparent; border-top:1px dashed #ddd; margin-top:8px; font-size:12px; }

 /* Tile */
 .tile-img { width:100%; aspect-ratio:16/9; background-size:cover; background-position:center; }
 .tile-body { padding:12px 14px 14px; }
 .tile-body h3 { font-size:14.5px; margin:8px 0 6px; line-height:1.45; font-weight:600; color:#1a1d24;
                 display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
 .tile-body .meta { font-size:11.5px; color:#666; }

 /* 複材應用／超級纖維面板 */
 .panel-section { margin-top:34px; }
 .panel-title { font-size:18px; margin:0 0 14px; font-weight:700;
                display:flex; align-items:baseline; gap:10px; flex-wrap:wrap;
                padding-bottom:10px; border-bottom:3px solid transparent; }
 .app-section .panel-title   { border-bottom-color:#0891b2; }
 .fiber-section .panel-title { border-bottom-color:#d97706; }
 .mfg-section .panel-title   { border-bottom-color:#6d4aff; }
 .panel-title .sub { font-size:12.5px; color:#666; font-weight:400; letter-spacing:0.02em; }
 .mini-grid { display:grid; grid-template-columns:repeat(3, 1fr); gap:12px; }
 .mini-tile { background:#fff; border-radius:10px; overflow:hidden;
              box-shadow:0 1px 6px rgba(0,0,0,0.05); transition:transform .15s, box-shadow .15s; }
 .mini-tile:hover { transform:translateY(-2px); box-shadow:0 6px 14px rgba(0,0,0,0.08); }
 .mini-img { width:100%; aspect-ratio:16/9; background-size:cover; background-position:center;
             position:relative; overflow:hidden; }
 .img-overlay { position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
                color:rgba(255,255,255,0.95); font-size:16px; font-weight:700; text-align:center;
                padding:16px; letter-spacing:0.03em; text-shadow:0 2px 10px rgba(0,0,0,0.35);
                background:linear-gradient(135deg, rgba(0,0,0,0.15), rgba(0,0,0,0.0) 50%); }
 .mini-body { padding:10px 13px 12px; }
 .mini-body h4 { font-size:13.5px; margin:0 0 5px; line-height:1.45; font-weight:600; color:#1a1d24;
                 display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
 .mini-body .meta { font-size:11px; color:#666; }

 .tags { display:flex; gap:6px; align-items:center; }
 .tag { font-size:10.5px; padding:2px 9px; border-radius:999px;
        color:#fff; font-weight:600; letter-spacing:0.03em; }
 .tag.tiny { font-size:10px; padding:1px 7px; }
 .lang { font-size:10px; padding:1px 6px; border-radius:3px;
         background:rgba(0,0,0,0.08); color:#555; font-weight:600; }
 .lang.dark { background:rgba(255,255,255,0.25); color:#fff; }

 /* Detail expansion */
 .detail { padding:14px 18px 18px; background:#fafafa; border-top:1px solid #eee;
           font-size:13.5px; color:#333; }
 .detail p { margin:0 0 10px; line-height:1.65; }
 .read-more-group { display:flex; gap:10px; align-items:center; margin-top:4px; flex-wrap:wrap; }
 .read-more { display:inline-block; padding:6px 12px;
              background:#5b87e0; color:#fff !important; font-size:12.5px;
              font-weight:600; border-radius:6px; text-decoration:none;
              transition:background .15s; }
 .read-more:hover { background:#4870c8; text-decoration:none; }
 .read-more-alt { color:#888; font-size:12px; text-decoration:none;
                  padding:4px 8px; border:1px solid #ddd; border-radius:5px;
                  transition:color .15s, border-color .15s; }
 .read-more-alt:hover { color:#333; border-color:#aaa; text-decoration:none; }
 .carbon-item .read-more { padding:4px 10px; font-size:11.5px; }
 .carbon-item .read-more-alt { font-size:11px; padding:3px 7px; }
 .detail a { color:#5b87e0; text-decoration:none; font-weight:600; font-size:13px; }
 .detail a:hover { text-decoration:underline; }
 .hero .detail { padding:16px 26px 22px; }

 footer { margin-top:22px; padding-top:14px; border-top:1px solid rgba(0,0,0,0.07);
          text-align:center; font-size:11.5px; color:#777; }

 @media (max-width:1000px) {
   .hero-row { grid-template-columns:1fr; }
   .carbon-grid { grid-template-columns:1fr; }
   .grid { grid-template-columns:repeat(2,1fr); }
   .hero { min-height:320px; }
   .hero > summary { min-height:320px; }
 }
 @media (max-width:600px) {
   .grid { grid-template-columns:1fr; }
   .wrap { padding:16px; margin:12px; border-radius:16px; }
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
    <button type="button" class="tab" data-tab="main">國際要聞 <em>$($picked.Count)</em></button>
    <button type="button" class="tab" data-tab="carbon">碳纖維即時 <em>$($carbonPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="mfg">碳纖製造商 <em>$($mfgPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="app">市場情報 <em>$($appPicked.Count)</em></button>
    <button type="button" class="tab" data-tab="fiber">超級纖維 <em>$($fiberPicked.Count)</em></button>
  </nav>

  <section class="hero-row" data-group="main">
    $heroHtml
    $listHtml
  </section>

  <section class="grid" data-group="main">
    $gridBody
  </section>

  $carbonHtml

  $mfgHtml

  $appHtml

  $fiberHtml

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
    # 把單一本地檔案推到 GitHub repo（PUT /contents/<path>）
    param([string]$LocalFile, [string]$RepoPath, [string]$Token, [string]$Repo, [string]$CommitMsg)
    $apiBase = "https://api.github.com/repos/$Repo/contents"
    $headers = @{
        Authorization = "token $Token"
        'User-Agent'  = 'TEi-News-Publisher'
        Accept        = 'application/vnd.github+json'
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($LocalFile)
        $b64   = [Convert]::ToBase64String($bytes)

        $sha = $null
        try {
            $existing = Invoke-RestMethod -Uri "$apiBase/$RepoPath" -Headers $headers -Method Get -ErrorAction Stop
            $sha = $existing.sha
            # 內容相同就不推
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
        Write-Host ("  [失敗] {0}: {1}" -f $RepoPath, $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
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

        # 同步腳本／LOGO／workflow（供 Actions 使用）
        $syncTargets = @(
            @{ Local='fetch_news.ps1'; Repo='fetch_news.ps1' }
            @{ Local='logo.png';       Repo='logo.png' }
            @{ Local='logo.svg';       Repo='logo.svg' }
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

Publish-ToGitHub -LocalFile $outFile
if ($OpenBrowser) { Start-Process $outFile }
