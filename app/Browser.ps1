# ============================================================
# Browser.ps1 : 監視画面 (index.html) を開く
#   Author: yuichi
#   最優先は社外監視 (VPN) の窓。それに影響を与えないことを第一にする。
#   ・社外監視とは別のブラウザで開く (閉じる窓を取り違えないように)
#   ・専用プロファイルで起動し、社外監視のブラウザとはプロセスを分ける
#     (こちらが重くなっても落ちても巻き込まない。Cookie・ログインも共有しない)
#   ・監視画面がすでに開いていれば、新しく開かずにその窓を前面に出す (窓を増やさない)
#   ・このスクリプトはブラウザを閉じたり、監視画面以外の窓を操作したりしない
#
#   Config.ps1 で指定できる項目 (書かなければ既定値)
#     $Browser       = 'auto'       # auto / chrome / edge / firefox
#                                   #   auto は chrome → edge の順に探す
#                                   #   firefox は他の業務 (BH スペアナ) で使うので auto には含めない
#     $DashboardSize = '1280,860'   # 窓の大きさ (幅,高さ)  ※ chrome / edge のみ
#     $DashboardPos  = ''           # 窓の位置 (x,y)。例 '1920,0' で 2 枚目のモニター  ※ chrome / edge のみ
# ============================================================

function Find-BrowserExe {
    param([string]$Name)
    $exe = @{ chrome = 'chrome.exe'; edge = 'msedge.exe'; firefox = 'firefox.exe' }[$Name]
    if (-not $exe) { return $null }

    # 1. レジストリの App Paths
    $keys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + $exe,
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + $exe,
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\' + $exe
    )
    foreach ($k in $keys) {
        try {
            $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).'(default)'
            if ($v) { $v = $v.Trim('"'); if (Test-Path -LiteralPath $v) { return $v } }
        } catch { }
    }

    # 2. 標準のインストール先
    $pf  = $env:ProgramFiles
    $pfx = ${env:ProgramFiles(x86)}
    $loc = $env:LOCALAPPDATA
    $cand = @{
        chrome  = @("$pf\Google\Chrome\Application\chrome.exe", "$pfx\Google\Chrome\Application\chrome.exe", "$loc\Google\Chrome\Application\chrome.exe")
        edge    = @("$pfx\Microsoft\Edge\Application\msedge.exe", "$pf\Microsoft\Edge\Application\msedge.exe")
        firefox = @("$pf\Mozilla Firefox\firefox.exe", "$pfx\Mozilla Firefox\firefox.exe")
    }[$Name]
    foreach ($c in $cand) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# Firefox の専用プロファイルに、初回の案内などを出さない設定を書く
function Initialize-FirefoxProfile {
    param([string]$Prof)
    if (-not (Test-Path -LiteralPath $Prof)) { New-Item -ItemType Directory -Path $Prof -Force | Out-Null }
    $uj = Join-Path $Prof 'user.js'
    if (Test-Path -LiteralPath $uj) { return }
    $lines = @(
        'user_pref("browser.aboutwelcome.enabled", false);',
        'user_pref("browser.shell.checkDefaultBrowser", false);',
        'user_pref("browser.startup.homepage_override.mstone", "ignore");',
        'user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);',
        'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
        'user_pref("browser.sessionstore.resume_from_crash", false);',
        'user_pref("browser.tabs.warnOnClose", false);'
    )
    [System.IO.File]::WriteAllLines($uj, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# 専用プロファイルで動いているブラウザの「本体」プロセスを探す (子プロセスは除く)
#   コマンドラインに専用プロファイルのパスを含むものだけを見るので、
#   社外監視 (VPN) のブラウザは対象にならない。
function Find-DashboardProcess {
    param([string]$Exe, [string]$Prof)
    $name = [System.IO.Path]::GetFileName($Exe)
    try {
        $ps = Get-CimInstance Win32_Process -Filter ("Name='" + $name + "'") -ErrorAction Stop
    } catch { return $null }
    foreach ($p in $ps) {
        $cl = [string]$p.CommandLine
        if (-not $cl) { continue }
        if ($cl.IndexOf($Prof, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($cl -match '--type=' -or $cl -match '-contentproc') { continue }   # 描画などの子プロセス
        return $p.ProcessId
    }
    return $null
}

# 戻り値: 'OK ...' または 'NG ...' (呼び出し側でログに書く)
function Open-Dashboard {
    param([string]$Dir, [string]$Browser = 'auto', [string]$Size = '', [string]$Pos = '')
    if (-not $Browser) { $Browser = 'auto' }
    if (-not $Size)    { $Size = '1280,860' }
    $Browser = $Browser.ToLower()

    $order = @($Browser)
    if ($Browser -eq 'auto') { $order = @('chrome', 'edge') }

    $name = $null; $exe = $null
    foreach ($b in $order) {
        $e = Find-BrowserExe $b
        if ($e) { $name = $b; $exe = $e; break }
    }
    if (-not $exe) { return ('NG ブラウザが見つかりません (指定=' + $Browser + ')') }

    $url  = ([System.Uri](Join-Path $Dir 'index.html')).AbsoluteUri
    $prof = Join-Path $Dir ('profile_' + $name)

    # すでに開いていれば、その窓を前面に出す (プロセス ID で指定するので、他の窓は動かさない)
    $bpid = Find-DashboardProcess $exe $prof
    if ($bpid) {
        try {
            $ws = New-Object -ComObject WScript.Shell
            if ($ws.AppActivate([int]$bpid)) { return ('OK ' + $name + '  既存の画面を前面に表示 (pid=' + $bpid + ')') }
        } catch { }
        # 前面に出せなかったとき (窓だけ閉じてプロセスが残っている場合など) は、新しく開く
    }

    if ($name -eq 'firefox') {
        Initialize-FirefoxProfile $prof
        # Firefox にはタブなしの窓がないので、通常の窓 (別プロセス・別窓) で開く
        $argStr = '-profile "' + $prof + '" -no-remote -new-instance "' + $url + '"'
    } else {
        $argStr = '--user-data-dir="' + $prof + '" --no-first-run --no-default-browser-check --app="' + $url + '" --window-size=' + $Size
        if ($Pos) { $argStr += ' --window-position=' + $Pos }
    }

    try {
        Start-Process -FilePath $exe -ArgumentList $argStr -ErrorAction Stop
        $note = ''
        if ($Browser -ne 'auto' -and $Browser -ne $name) { $note = '  (指定=' + $Browser + ')' }
        return ('OK ' + $name + '  ' + $exe + $note)
    } catch {
        return ('NG ' + $name + ' の起動に失敗: ' + $_.Exception.Message)
    }
}
