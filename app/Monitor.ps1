# ============================================================
# Monitor.ps1 : CsqWatch 本体 (AT コマンド機器の信号監視。収集 + CSV 保存 + data.js 出力)
#   Author: yuichi
#   使い方:  Monitor.bat  (実機)   /  Monitor.bat -Mock  (疑似データ)
#   ・シリアル I/O は AtIo.exe に任せます (AT コマンドは引数で渡す)
#   ・Web サーバは使いません。index.html が data.js を読みます
#   ・設定は Config.ps1 だけで変えられます
#   ・試験ログ: logs\test_yyyyMMdd.log (コマンド・応答・デバッグ情報)
#   ・入口は Monitor.bat だけ。動いていなければ監視を始め、動いていれば画面を前面に出すだけ
#   ・多重起動防止: 2 つ目は起動しない。起動中の情報は logs\monitor_running.txt
#   ・画面は社外監視とは別のブラウザ・専用プロファイルで開く (Browser.ps1)
#   ・社外監視 (VPN) の窓が最優先。Monitor は CPU 優先度「通常以下」で動く
# ============================================================
param(
    [switch]$Mock,
    [int]$IntervalSec = 0
)

$ErrorActionPreference = 'Continue'
$Dir = $PSScriptRoot
if (-not $Dir) { $Dir = Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location -LiteralPath $Dir
if (-not (Test-Path -LiteralPath (Join-Path $Dir 'Config.ps1'))) {
    Copy-Item -LiteralPath (Join-Path $Dir 'Config.sample.ps1') -Destination (Join-Path $Dir 'Config.ps1')
    Write-Host 'Config.ps1 を Config.sample.ps1 から作成しました。COM 番号などを確認してください。' -ForegroundColor Yellow
}
. (Join-Path $Dir 'Config.ps1')
. (Join-Path $Dir 'Common.ps1')
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $RssiMax) { $RssiMax = 55 }      # Config.ps1 に無ければ IsatPhone 2 の値
if ($null -eq $DeviceName) { $DeviceName = '' }   # 画面の見出しに出す機器名
if (-not $AtIoExe) { $AtIoExe = 'AtIo.exe' }      # 旧 Config.ps1 ($IsatIoExe) のままでも動くように

if ($IntervalSec -le 0) {
    if ($Mock) { $IntervalSec = $MockPollSec } else { $IntervalSec = $PollSec }
}

$LogPath = Join-Path $Dir $LogDir
if (-not (Test-Path -LiteralPath $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
$DataJs    = Join-Path $Dir 'data.js'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom   = New-Object System.Text.UTF8Encoding($true)

# ---------------- 試験ログ ----------------
#   書式: 日時(ミリ秒)  区分  内容
#   区分: INFO 起動・設定 / CMD 送信 / RSP 応答 / DBG 解析結果・状態 / WARN 注意 / ERR エラー
#   1 行ごとに書き込んで閉じるので、強制終了や再起動の直前まで残ります
function Write-TestLog {
    param([string]$Level, [string]$Msg)
    try {
        $p = Join-Path $LogPath ('test_' + (Get-Date).ToString('yyyyMMdd') + '.log')
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') + '  ' + $Level.PadRight(4) + '  ' + ($Msg -replace "`r?`n", ' | ')
        [System.IO.File]::AppendAllText($p, $line + "`r`n", $Utf8Bom)
    } catch { }
}

# 予期しないエラーで止まる直前に内容を残す (止まる動作はこれまでと同じ)
trap {
    Write-TestLog 'ERR' ('UNHANDLED ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage)
    break
}

# ---------------- 監視画面を開く ----------------
#   社外監視 (VPN) とは別のブラウザ・別のプロセスで開く。詳細は Browser.ps1
. (Join-Path $Dir 'Browser.ps1')
function Show-Dashboard {
    $r = Open-Dashboard -Dir $Dir -Browser $Browser -Size $DashboardSize -Pos $DashboardPos
    if ($r.StartsWith('OK')) {
        Write-TestLog 'INFO' ('監視画面を表示: ' + $r.Substring(3))
    } else {
        Write-TestLog 'WARN' ('監視画面を開けませんでした: ' + $r.Substring(3))
        Write-Host '監視画面を開けませんでした。Config.ps1 の $Browser を確認してください。' -ForegroundColor Yellow
    }
}

# ---------------- 多重起動の防止 ----------------
#   輪番運用で窓が見当たらず再度起動された場合に、2 つ目を起動させない。
#   別のユーザーでログオンして起動しようとした場合も止める (Global 名前空間)。
#   本番と -Mock は別扱い (Mock の試験中も本番は止めない)。
function Test-InnerException {
    param($Ex, [type]$Type)
    while ($Ex) { if ($Ex -is $Type) { return $true }; $Ex = $Ex.InnerException }
    return $false
}
$MutexName = 'Global\CsqWatch'
if ($Mock) { $MutexName += '_Mock' }
$LockInfo = Join-Path $LogPath 'monitor_running.txt'
$got = $false
$why = ''
try {
    $script:Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    try {
        $got = $script:Mutex.WaitOne(0)
    } catch {
        if (Test-InnerException $_.Exception ([System.Threading.AbandonedMutexException])) {
            $got = $true
            Write-TestLog 'WARN' '前回の Monitor は正常終了していません (Mutex の放棄を検出)'
        } else { throw }
    }
} catch {
    $got = $false
    $why = $_.Exception.Message      # 別ユーザーが起動中のときはアクセス拒否になる
}
if (-not $got) {
    # すでに監視は動いている。監視画面を前面に出す (閉じていれば開く) だけで、数秒で閉じる。
    # 輪番で画面が見当たらないときも、Monitor.bat を押せばよい。
    $who = '(不明)'
    try { $who = [System.IO.File]::ReadAllText($LockInfo, $Utf8Bom).Trim() } catch { }
    Write-Host ''
    Write-Host ' 監視はすでに動いています。監視画面を前面に出します。' -ForegroundColor Cyan
    Write-Host (' 動作中: ' + $who) -ForegroundColor Cyan
    Write-Host ' (この窓は 5 秒後に自動で閉じます)' -ForegroundColor Cyan
    $msg = '多重起動を検出 (監視は開始せず、画面のみ表示)  pid=' + $PID + '  user=' + $env:USERNAME + '  動作中=' + $who
    if ($why) { $msg += '  詳細=' + $why }
    Write-TestLog 'WARN' $msg
    Show-Dashboard
    Start-Sleep -Seconds 5
    exit 3            # Monitor.bat はこの終了コードのとき pause せずに閉じる
}
try {
    $info = 'pid=' + $PID + '  開始=' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  user=' + $env:USERNAME + '  PC=' + $env:COMPUTERNAME
    if ($Mock) { $info += '  (MOCK)' }
    [System.IO.File]::WriteAllText($LockInfo, $info, $Utf8Bom)
} catch { }
try { $Host.UI.RawUI.WindowTitle = 'CsqWatch 稼働中 (閉じないでください)' } catch { }
# 社外監視 (VPN) の窓を優先させるため、Monitor の CPU 優先度を「通常以下」にする。
# 子プロセスの AtIo.exe もこの優先度を引き継ぐ。処理は軽いので取得には影響しない。
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }

# ログ用に応答を整える。PowerShell 5.1 が外部プログラムのエラー出力に付ける
# 「発生場所 ... + CategoryInfo ...」などの飾りを除き、AtIo.exe の出力だけを残す。
# (判定には元の応答を使うので、ここでの整形は判定に影響しない)
function Format-Response {
    param($Res)
    $lines = ([string]$Res) -split "`r?`n" | Where-Object {
        # AT の応答 (+CSQ: など) は残す。飾りは「+ の後に空白が続く行」「+ CategoryInfo」など
        $_ -notmatch '^\+\s{2,}' -and
        $_ -notmatch '^\s+\+ (CategoryInfo|FullyQualifiedErrorId)' -and
        $_ -notmatch '^\s*(発生場所|場所 |At )'
    }
    $txt = (($lines | ForEach-Object { $_ -replace '^AtIo\.exe : ', '' }) -join "`n").Trim()
    if (-not $txt) { $txt = '(空応答)' }
    return $txt
}

# Invoke-At を包んで、送信・応答・所要時間・AtIo の残留を記録する
function Invoke-AtLog {
    param([string]$Cmd, [int]$Wait, [string]$After = '')
    $left = @(Get-Process -Name 'AtIo' -ErrorAction SilentlyContinue).Count
    if ($left -gt 0) { Write-TestLog 'WARN' ('AtIo.exe が残っています: ' + $left + ' 個') }
    $info = $Cmd + '  wait=' + $Wait + 's'
    if ($After) { $info += '  after=' + $After }
    Write-TestLog 'CMD' $info
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($After) { $res = Invoke-At $Cmd $Wait $After } else { $res = Invoke-At $Cmd $Wait }
    $sw.Stop()
    Write-TestLog 'RSP' ($Cmd + '  ' + $sw.ElapsedMilliseconds + 'ms  ' + (Format-Response $res))
    return $res
}

$History = New-Object System.Collections.ArrayList
$Current = @{ LastUpdate = '--'; CsqOk = $true; Rssi = 0; Dbm = 'N/A'; Ber = 99; RegStatus = '初期化中'; Extras = @() }
$LastCallKey = ''
$PollCount = 0

# ---------------- CSV ----------------
function Get-CsvPath {
    param([datetime]$d)
    return (Join-Path $LogPath ('csq_' + $d.ToString('yyyyMM') + '.csv'))
}

function Add-CsvLine {
    param([datetime]$d, [string]$line)
    try {
        $p = Get-CsvPath $d
        if (-not (Test-Path -LiteralPath $p)) {
            [System.IO.File]::WriteAllText($p, "Timestamp,RSSI,Level,BER,RegStatus,Notes`r`n", $Utf8Bom)
            Write-TestLog 'INFO' ('CSV 新規作成: ' + $p)
        }
        [System.IO.File]::AppendAllText($p, $line + "`r`n", $Utf8Bom)
    } catch {
        Write-Host ('CSV 書き込み失敗 (Excel で開いていませんか?): ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-TestLog 'ERR' ('CSV 書き込み失敗: ' + $_.Exception.Message)
    }
}

function Import-History {
    $p = Get-CsvPath (Get-Date)
    if (-not (Test-Path -LiteralPath $p)) {
        # 名称変更 (IsatMon → CsqWatch) 前の CSV があれば、そこから復元する (読むだけ)
        $old = Join-Path $LogPath ('isat_' + (Get-Date).ToString('yyyyMM') + '.csv')
        if (-not (Test-Path -LiteralPath $old)) { return }
        $p = $old
        Write-TestLog 'INFO' ('旧名の CSV から履歴を復元: ' + $old)
    }
    $lines = Get-Content -LiteralPath $p -Encoding UTF8 | Select-Object -Last 200
    foreach ($l in $lines) {
        $c = $l -split ','
        $v = 0
        if ($c.Length -ge 4 -and [int]::TryParse($c[1], [ref]$v)) {
            $ok = -not ($c[2] -eq 'N/A' -or $c[2] -eq '取得失敗')   # 3 列目で取得失敗を見分ける
            [void]$History.Add(@{ t = $c[0]; r = $v; ok = $ok })
        }
    }
    while ($History.Count -gt $HistoryMax) { $History.RemoveAt(0) }
    $lastT = '--'
    if ($History.Count -gt 0) { $lastT = $History[$History.Count - 1].t }
    Write-TestLog 'INFO' ('履歴読込: ' + $History.Count + ' 件  最終=' + $lastT)
}

# ---------------- data.js (画面用) ----------------
function Write-Data {
    $hist = @()
    foreach ($h in $History) {
        $r = $h.r
        if ($h.ok -eq $false) { $r = $null }   # 取得失敗はグラフを途切れさせる
        elseif ($r -eq 99)    { $r = 0 }       # 端末が返した圏外 (99) は 0 で描く
        $hist += @{ t = $h.t; r = $r }
    }
    $obj = @{
        mock        = [bool]$Mock
        intervalSec = $IntervalSec
        rssiMax     = $RssiMax
        deviceName  = $DeviceName
        current     = $Current
        history     = $hist
    }
    $json = ConvertTo-Json -InputObject $obj -Depth 5 -Compress
    $tmp  = $DataJs + '.tmp'
    try {
        [System.IO.File]::WriteAllText($tmp, ('window.CSQ_DATA = ' + $json + ';'), $Utf8NoBom)
    } catch {
        Write-TestLog 'ERR' ('data.js.tmp 書き込み失敗: ' + $_.Exception.Message)
    }
    $mvErr = $null
    Move-Item -LiteralPath $tmp -Destination $DataJs -Force -ErrorAction SilentlyContinue -ErrorVariable mvErr
    if ($mvErr) { Write-TestLog 'WARN' ('data.js 置き換え失敗: ' + $mvErr[0].Exception.Message) }
}

# ---------------- 1 回分の取得 ----------------
function Invoke-Poll {
    $script:PollCount++
    $now    = Get-Date
    $nowStr = $now.ToString('yyyy-MM-dd HH:mm:ss')
    $rssi = 99; $ber = 99; $dbm = '取得失敗'; $reg = '不明'; $note = 'Periodic'; $code = '-'; $csqOk = $false

    $ports = ([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object) -join ','
    if (-not $ports) { $ports = '(なし)' }
    $ws = [int]((Get-Process -Id $PID).WorkingSet64 / 1MB)
    Write-TestLog 'DBG' ('POLL #' + $PollCount + '  ports=' + $ports + '  mem=' + $ws + 'MB')
    if (-not $Mock -and ($ports -split ',') -notcontains $Port) {
        Write-TestLog 'WARN' ($Port + ' が見つかりません (USB 切断・スリープの可能性)')
    }

    # 信号強度 AT+CSQ -> +CSQ: <rssi>,<ber>
    $csq = Invoke-AtLog 'AT+CSQ' 3
    $m = [regex]::Match($csq, '\+CSQ:\s*(\d+)\s*,\s*(\d+)')
    if ($m.Success) {
        $rssi = [int]$m.Groups[1].Value
        $ber  = [int]$m.Groups[2].Value
        $csqOk = $true          # 端末が値を返した (99 なら端末自身が「圏外・測定不能」と報告)
        # Inmarsat の rssi は GSM の dBm 換算が使えないので、生の値を「値 / 最大値」で表示する
        if ($rssi -eq 99) { $dbm = '圏外' } else { $dbm = [string]$rssi + ' / ' + $RssiMax }
        if ($rssi -ne 99 -and $rssi -gt $RssiMax) { Write-TestLog 'WARN' ('rssi=' + $rssi + ' が目盛りの最大値 ' + $RssiMax + ' を超えています ($RssiMax を確認)') }
    } else {
        $note = 'CSQ no response'
        if ($csq -match 'IO Error') {
            $reg  = 'ポートエラー'
            $note = ((Format-Response $csq) -split "`n")[0]
        }
        Write-TestLog 'WARN' 'CSQ 解析失敗'
    }

    # 登録状態 AT+CREG? -> +CREG: <n>,<stat>
    $creg = Invoke-AtLog 'AT+CREG?' 3
    $m = [regex]::Match($creg, '\+CREG:\s*\d+\s*,\s*(\d+)')
    if ($m.Success) {
        $code = $m.Groups[1].Value
        if ($RegText.ContainsKey($code)) { $reg = $RegText[$code] } else { $reg = '未登録 (' + $code + ')' }
    } else {
        Write-TestLog 'WARN' 'CREG 解析失敗'
    }
    # 応答に +CREG: が 2 行以上あれば、非同期通知が紛れ込んでいる
    $cregN = ([regex]::Matches($creg, '\+CREG:')).Count
    if ($cregN -gt 1) { Write-TestLog 'WARN' ('CREG 応答に +CREG: が ' + $cregN + ' 行 (非同期通知の混入)') }

    # 追加カード (Config.ps1 の $Extras)
    $extraVals = @()
    foreach ($e in $Extras) {
        $r  = Invoke-AtLog $e.Cmd 3
        $mm = [regex]::Match($r, $e.Regex)
        $val = 'N/A'
        if ($mm.Success) { $val = $mm.Groups[1].Value } else { Write-TestLog 'WARN' ($e.Name + ' 解析失敗') }
        $extraVals += @{ name = $e.Name; value = $val }
    }

    Write-TestLog 'DBG' ('解析結果  ok=' + $csqOk + '  rssi=' + $rssi + '  ber=' + $ber + '  creg=' + $code + '  reg=' + $reg + '  note=' + $note)

    $regCsv  = $reg  -replace ',', ' '
    $noteCsv = $note -replace ',', ' '
    Add-CsvLine $now ($nowStr + ',' + $rssi + ',' + $dbm + ',' + $ber + ',' + $regCsv + ',' + $noteCsv)

    [void]$History.Add(@{ t = $nowStr; r = $rssi; ok = $csqOk })
    while ($History.Count -gt $HistoryMax) { $History.RemoveAt(0) }

    $script:Current = @{ LastUpdate = $nowStr; CsqOk = $csqOk; Rssi = $rssi; Dbm = $dbm; Ber = $ber; RegStatus = $reg; Extras = $extraVals }
    Write-Data
    Write-Host ($nowStr + '  CSQ=' + $dbm + '  BER=' + $ber + '  ' + $reg)
}

# ---------------- 定時試験発信 ----------------
function Invoke-TestCall {
    param([datetime]$now)
    Write-Host ($now.ToString('HH:mm') + '  試験発信 ' + $TestNumber + ' (' + $CallDuration + ' 秒)')
    Write-TestLog 'INFO' ('試験発信 開始  ' + $TestNumber + '  ' + $CallDuration + 's')
    $callRes = Invoke-AtLog ('ATD' + $TestNumber + ';') $CallDuration 'ATH'
    Write-TestLog 'INFO' '試験発信 終了'
    Add-CsvLine $now ($now.ToString('yyyy-MM-dd HH:mm:ss') + ',,,,,TestCall ' + $TestNumber)
}

# ---------------- メイン ----------------
$modeText = $Port + ' @' + $BaudRate
if ($Mock) { $modeText = 'MOCK' }

$bootStr = '?'
try { $bootStr = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { }
$ioStr = '?'
try {
    $io = Get-Item -LiteralPath (Join-Path $Dir 'AtIo.exe') -ErrorAction Stop
    $ioStr = $io.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ' ' + $io.Length + 'B'
} catch { }
Write-TestLog 'INFO' ('START  pid=' + $PID + '  ps=' + $PSVersionTable.PSVersion + '  user=' + $env:USERNAME + '  boot=' + $bootStr)
Write-TestLog 'INFO' ('設定  mode=' + $modeText + '  interval=' + $IntervalSec + 's  CallTimes=' + ($CallTimes -join ',') + '  CallDuration=' + $CallDuration + 's  Device=' + $DeviceName + '  RssiMax=' + $RssiMax + '  Extras=' + @($Extras).Count + '  AtIo=' + $ioStr)

Import-History
Write-Data
Write-Host '===================================================='
Write-Host (' CsqWatch   device=' + $DeviceName + '   mode=' + $modeText + '  interval=' + $IntervalSec + 's')
Write-Host (' 画面 : ' + (Join-Path $Dir 'index.html'))
Write-Host ' 終了 : Ctrl+C'
Write-Host '===================================================='
if ($OpenDashboard -ne $false) { Show-Dashboard }   # Config.ps1 で $OpenDashboard = $false にすると開かない

# Ctrl+C で止めたときも finally が動き、STOP をログに残す。
# (× ボタンで閉じた・PC の再起動・強制終了では残らない → STOP が無ければ外部要因)
try {
    $next = Get-Date
    while ($true) {
        $now = Get-Date
        $key = $now.ToString('yyyyMMdd_HHmm')
        if (($CallTimes -contains $now.ToString('HH:mm')) -and ($LastCallKey -ne $key)) {
            $LastCallKey = $key
            Invoke-TestCall $now
            $next = Get-Date                     # 発信の直後に 1 回取得する
        }
        if ($now -ge $next) {
            $late = [int]($now - $next).TotalSeconds
            if ($late -gt 10) { Write-TestLog 'WARN' ('周期遅れ ' + $late + 's (スリープ・処理詰まりの可能性)') }
            Invoke-Poll
            $next = (Get-Date).AddSeconds($IntervalSec)
        }
        Start-Sleep -Seconds 1
    }
} finally {
    Write-TestLog 'INFO' ('STOP  pid=' + $PID + '  polls=' + $PollCount)
    try { Remove-Item -LiteralPath $LockInfo -Force -ErrorAction SilentlyContinue } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
}
