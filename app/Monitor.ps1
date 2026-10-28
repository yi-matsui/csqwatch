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
#   ・発信試験: 24 個のタイムテーブル (CallTable.json、画面で編集)。結果は logs\call_yyyyMM.csv
#   ・評価トレンド: $TrendDays 日分を 15 分ごとにまとめた trend.js。変化のコメントは logs\events.csv
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

# 受信グラフに残す点数。$HistoryHours (既定 72 時間 = 3 日) と取得周期から決める (上限 3000 点)。
# 旧版の Config.ps1 の $HistoryMax (30 など) は使わない。
if (-not $HistoryHours -or [double]$HistoryHours -le 0) { $HistoryHours = 72 }
$HistoryMax = [int][Math]::Min(3000, [Math]::Ceiling([double]$HistoryHours * 3600 / [Math]::Max(1, $IntervalSec)) + 1)

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
    param([string]$Cmd, [int]$Wait, [string]$After = '', [string]$During = '', [int]$DuringEvery = 5)
    $left = @(Get-Process -Name 'AtIo' -ErrorAction SilentlyContinue).Count
    if ($left -gt 0) { Write-TestLog 'WARN' ('AtIo.exe が残っています: ' + $left + ' 個') }
    $info = $Cmd + '  wait=' + $Wait + 's'
    if ($After) { $info += '  after=' + $After }
    if ($After -and $During) { $info += '  during=' + $During + ' every ' + $DuringEvery + 's' }
    Write-TestLog 'CMD' $info
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($After) { $res = Invoke-At $Cmd $Wait $After $During $DuringEvery } else { $res = Invoke-At $Cmd $Wait }
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
    # 先月と今月の CSV から、$HistoryHours 時間以内の行を読んでグラフの履歴を復元する。
    # 名称変更 (IsatMon → CsqWatch) 前の isat_YYYYMM.csv も、同じ月の csq_ がなければ読む (読むだけ)
    $now = Get-Date
    $cutoff = $now.AddHours(-[double]$HistoryHours).ToString('yyyy-MM-dd HH:mm:ss')
    $files = @()
    foreach ($d in @($now.AddMonths(-1), $now)) {
        $p = Get-CsvPath $d
        if (-not (Test-Path -LiteralPath $p)) {
            $old = Join-Path $LogPath ('isat_' + $d.ToString('yyyyMM') + '.csv')
            if (Test-Path -LiteralPath $old) { $p = $old; Write-TestLog 'INFO' ('旧名の CSV から履歴を復元: ' + $old) } else { continue }
        }
        $files += $p
    }
    foreach ($p in $files) {
        foreach ($l in (Get-Content -LiteralPath $p -Encoding UTF8)) {
            $c = $l -split ','
            $v = 0
            if ($c.Length -ge 4 -and [int]::TryParse($c[1], [ref]$v) -and $c[0] -ge $cutoff) {
                $ok = -not ($c[2] -eq 'N/A' -or $c[2] -eq '取得失敗')   # 3 列目で取得失敗を見分ける
                [void]$History.Add(@{ t = $c[0]; r = $v; ok = $ok })
            }
        }
    }
    while ($History.Count -gt $HistoryMax) { $History.RemoveAt(0) }
    $lastT = '--'
    if ($History.Count -gt 0) { $lastT = $History[$History.Count - 1].t }
    Write-TestLog 'INFO' ('履歴読込: ' + $History.Count + ' 件 (' + $HistoryHours + ' 時間以内、最大 ' + $HistoryMax + ' 点)  最終=' + $lastT)
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
    # 発信試験: タイムテーブル・反映の状態・今日の結果
    $todayStr = (Get-Date).ToString('yyyy-MM-dd')
    $todayRes = @($script:CallResults | Where-Object { $_.t.StartsWith($todayStr) })
    $okN = @($todayRes | Where-Object { $_.result -eq '成功' }).Count
    $call = @{
        enabled         = $script:CallTable.enabled
        durationSec     = $script:CallTable.durationSec
        savedAt         = $script:CallTable.savedAt
        slots           = @($script:CallTable.slots)
        duringEverySec  = [int]$CallDuringEverySec
        appliedAt       = $script:CallTableInfo.appliedAt
        source          = $script:CallTableInfo.source
        error           = $script:CallTableInfo.error
        errorAt         = $script:CallTableInfo.errorAt
        rejectedSavedAt = $script:CallTableInfo.rejectedSavedAt
        inbox           = [string]$script:CallInbox
        today           = $todayRes
        todayTotal      = $todayRes.Count
        todayOk         = $okN
    }
    $obj = @{
        call        = $call
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

# ---------------- 発信試験 (24 個のタイムテーブル) ----------------
#   タイムテーブルは app\CallTable.json。監視画面の「発信試験」で編集し、「保存」で
#   csqwatch_calltable.json がダウンロードフォルダに保存される。Monitor はそれを 5 秒ごとに探して取り込む。
#   試験 1 回の流れ: 発信直前の AT+CSQ → ATD<番号>; (通話中も AT+CSQ) → ATH → 切断直後の AT+CSQ
#   成否は ATD の応答で判定する (OK なら成功。ERROR / +CME ERROR / BUSY / NO CARRIER などは失敗)。
$CallTablePath = Join-Path $Dir 'CallTable.json'
$CallHistDir   = Join-Path $LogPath 'calltable_history'
if ($null -eq $CallDuringEverySec) { $CallDuringEverySec = 5 }
if ($null -eq $CallNumberAllow)    { $CallNumberAllow = @() }
$script:CallTable     = $null
$script:CallTableInfo = @{ appliedAt = ''; source = ''; error = ''; errorAt = ''; rejectedSavedAt = '' }
$script:CallResults   = New-Object System.Collections.ArrayList
$script:InboxCheckAt  = [datetime]::MinValue
$script:InboxDone     = @{}

# 画面で保存したタイムテーブルを探すフォルダ (既定はダウンロードフォルダ)
function Get-CallInbox {
    if ($CallTableInbox) { return [string]$CallTableInbox }
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    $h = $env:USERPROFILE
    if (-not $h) { $h = $HOME }
    return (Join-Path $h 'Downloads')
}

# 初期のタイムテーブル: 各時の 01 分、番号は $TestNumber、すべて OFF。
# 旧版の $CallTimes があれば、その時刻の行を ON にして発信試験を有効にする。
function New-DefaultCallTable {
    $slots = @()
    for ($h = 0; $h -lt 24; $h++) {
        $slots += [ordered]@{ hour = $h; time = ('{0:D2}:01' -f $h); number = [string]$TestNumber; on = $false }
    }
    $en = $false
    foreach ($ct in @($CallTimes)) {
        if ([string]$ct -match '^([01]\d|2[0-3]):([0-5]\d)$') {
            $h = [int]$Matches[1]
            $slots[$h].time = [string]$ct
            $slots[$h].on = $true
            $en = $true
        }
    }
    $dur = 20
    if ($CallDuration) { $dur = [int]$CallDuration }
    return [ordered]@{ version = 1; enabled = $en; durationSec = $dur; savedAt = ''; slots = $slots }
}

# JSON から読んだタイムテーブルを確かめて、決まった形にする。おかしければ例外 (理由つき)
function ConvertTo-CallTable {
    param($Obj)
    if ($null -eq $Obj -or $null -eq $Obj.slots) { throw 'タイムテーブルの形式が正しくありません (slots がない)' }
    $in = @($Obj.slots)
    if ($in.Count -ne 24) { throw ('行の数が 24 ではありません (' + $in.Count + ' 行)') }
    $dur = 20
    if ($null -ne $Obj.durationSec -and [string]$Obj.durationSec -ne '') { $dur = [int]$Obj.durationSec }
    if ($dur -lt 5 -or $dur -gt 120) { throw ('呼出秒数は 5〜120 にしてください (' + $dur + ')') }
    $slots = @()
    $seen = @{}
    for ($h = 0; $h -lt 24; $h++) {
        $s = $in[$h]
        $row = '' + $h + ' 時の行'
        $time = ([string]$s.time).Trim()
        if ($time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw ($row + ': 時刻が正しくありません (' + $time + ')') }
        $num = ([string]$s.number).Trim() -replace '[\s\-]', ''
        $on = ($s.on -eq $true)
        if ($on) {
            if ($num -notmatch '^\+?\d{3,20}$') { throw ($row + ': 着信番号が正しくありません (' + $num + ')') }
            if (@($CallNumberAllow).Count -gt 0 -and @($CallNumberAllow) -notcontains $num) {
                throw ($row + ': 許可されていない番号です (' + $num + ')。Config.ps1 の $CallNumberAllow を確認してください')
            }
            if ($seen.ContainsKey($time)) { throw ($row + ': 時刻 ' + $time + ' が ' + $seen[$time] + ' 時の行と重なっています') }
            $seen[$time] = $h
        }
        $slots += [ordered]@{ hour = $h; time = $time; number = $num; on = $on }
    }
    return [ordered]@{ version = 1; enabled = ($Obj.enabled -eq $true); durationSec = $dur; savedAt = [string]$Obj.savedAt; slots = $slots }
}

function Save-CallTable {
    try {
        $json = ConvertTo-Json -InputObject $script:CallTable -Depth 5
        [System.IO.File]::WriteAllText($CallTablePath, $json, $Utf8NoBom)
    } catch {
        Write-TestLog 'ERR' ('CallTable.json を保存できません: ' + $_.Exception.Message)
    }
}

function Get-CallTableSummary {
    $t = $script:CallTable
    $on = @($t.slots | Where-Object { $_.on })
    $times = ($on | ForEach-Object { $_.time }) -join ','
    return ('有効=' + $t.enabled + '  ON=' + $on.Count + '  呼出=' + $t.durationSec + 's  通話中測定=' + $CallDuringEverySec + 's  時刻=' + $times)
}

function Import-CallTable {
    if (Test-Path -LiteralPath $CallTablePath) {
        try {
            $obj = [System.IO.File]::ReadAllText($CallTablePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $script:CallTable = ConvertTo-CallTable $obj
            Write-TestLog 'INFO' ('タイムテーブル読込: ' + (Get-CallTableSummary))
        } catch {
            # 壊れたファイルは上書きせずに残し、発信試験は止めておく
            $script:CallTable = New-DefaultCallTable
            $script:CallTable.enabled = $false
            $script:CallTableInfo.error = 'CallTable.json を読めません。発信試験は停止中です: ' + $_.Exception.Message
            $script:CallTableInfo.errorAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Write-TestLog 'WARN' $script:CallTableInfo.error
        }
    } else {
        $script:CallTable = New-DefaultCallTable
        Save-CallTable
        Write-TestLog 'INFO' ('タイムテーブルを新規作成: ' + (Get-CallTableSummary))
    }
}

# 画面で保存されたタイムテーブル (csqwatch_calltable*.json) を探して取り込む。
# 取り込んだファイルは logs\calltable_history\ へ移す (誰がいつ変えたかの記録にもなる)。
function Receive-CallTable {
    $dirs = @($script:CallInbox, $Dir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    $files = @()
    foreach ($d in $dirs) {
        $files += @(Get-ChildItem -LiteralPath $d -Filter 'csqwatch_calltable*.json' -File -ErrorAction SilentlyContinue)
    }
    $files = @($files | Where-Object { -not $script:InboxDone.ContainsKey($_.FullName + '|' + $_.LastWriteTime.Ticks) } | Sort-Object LastWriteTime)
    if ($files.Count -eq 0) { return }
    $newest = $files[$files.Count - 1]
    if (-not (Test-Path -LiteralPath $CallHistDir)) { New-Item -ItemType Directory -Path $CallHistDir -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $ok = $false
    $obj = $null
    try {
        $obj = [System.IO.File]::ReadAllText($newest.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $tbl = ConvertTo-CallTable $obj
        $script:CallTable = $tbl
        Save-CallTable
        $script:CallTableInfo = @{ appliedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); source = $newest.Name; error = ''; errorAt = ''; rejectedSavedAt = '' }
        Write-TestLog 'INFO' ('タイムテーブルを取り込み: ' + $newest.FullName + '  savedAt=' + $tbl.savedAt + '  ' + (Get-CallTableSummary))
        Write-Host ((Get-Date).ToString('HH:mm:ss') + '  タイムテーブルを更新しました  ' + (Get-CallTableSummary)) -ForegroundColor Cyan
        $ok = $true
    } catch {
        $script:CallTableInfo.error = 'タイムテーブルを取り込めませんでした: ' + $_.Exception.Message
        $script:CallTableInfo.errorAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $script:CallTableInfo.rejectedSavedAt = ''
        if ($obj -and $obj.savedAt) { $script:CallTableInfo.rejectedSavedAt = [string]$obj.savedAt }
        Write-TestLog 'WARN' ($script:CallTableInfo.error + '  file=' + $newest.FullName)
        Write-Host $script:CallTableInfo.error -ForegroundColor Yellow
    }
    foreach ($f in $files) {
        $script:InboxDone[$f.FullName + '|' + $f.LastWriteTime.Ticks] = $true
        $suffix = ''
        if (-not $ok -and $f.FullName -eq $newest.FullName) { $suffix = '.rejected' }
        if ($f.FullName -ne $newest.FullName) { $suffix = '.old' }
        try {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $CallHistDir ($stamp + '_' + $f.Name + $suffix)) -Force -ErrorAction Stop
        } catch {
            Write-TestLog 'WARN' ('取り込んだファイルを移動できません (そのまま残します): ' + $f.FullName + '  ' + $_.Exception.Message)
        }
    }
    Write-Data
}

# 応答から最初の +CSQ: <rssi>,<ber> を取り出す (なければ $null)
function Get-CsqValue {
    param([string]$Res)
    $m = [regex]::Match($Res, '\+CSQ:\s*(\d+)\s*,\s*(\d+)')
    if (-not $m.Success) { return $null }
    return @{ r = [int]$m.Groups[1].Value; b = [int]$m.Groups[2].Value }
}

# 発信の応答を判定する。AtIo.exe の区切り行 (--- during / --- after) で、ATD の応答・通話中・切断を分ける。
#
# IsatPhone 2 は、通話中に次の独自の通知を自分から送ってくる (公開資料なし。実機の記録から推定):
#   +SKCPI: <呼>,<段階>,<音>,<回線>[,...]   呼の進み具合 (他社の +CPI 相当)
#        段階 0=発信 4=回線割当 3=呼の処理中 5=経過通知 2=相手を呼出 6=応答 1=切断
#        段階 5 で <音>=1 のときは、相手が鳴っている (網が呼出音を流している)。
#        2026-10-28 の実機の記録で、相手の呼出音が鳴っていた回に ALERT (段階 2) は出ず、5 / 音=1 が出ていた。
#   +SKCCSI: <呼>,<向き>,<状態>,<種別>,<多者>,<理由>,"番号",<型>   通話の状態 (+CLCC 相当)
#        状態 2=発信中 6=切断。切断のときの <理由> は ITU-T Q.850 の理由番号と思われる
#   +SKGPSPOSI: <0|1>   GPS の位置 (1=あり 0=なし と思われる。Inmarsat 端末は発信に GPS の位置が要る)
#   +CIEV: 2,<0-5>      表示器の変化。2 番はアンテナ表示と思われる
#
# 判定の順:
#   1. COM のエラー                                  → 失敗
#   2. ATD の最初の結果が OK でない (ERROR/BUSY など) → 失敗
#   3. こちらの ATH より前に切断の通知 (SKCCSI 状態 6 / SKCPI 段階 1) → 失敗 (切断理由つき)
#      ただし、経過通知 (呼出音) 以降まで進んでから理由 16/18/19 で切れたものは、呼が成立していたので成功
#   4. ATH より前に NO CARRIER / BUSY など             → 失敗 (呼出中に終了)
#   5. 独自通知はあるのに回線割当 (段階 4 以降) まで進んでいない → 失敗 (回線未確立)
#   6. それ以外                                       → 成功
#   独自通知を出さない機器では、3・5 は働かず、これまでどおり ATD の応答で判定する。
$CallStageName = @{ '0' = '発信'; '4' = '回線割当'; '3' = '呼の処理中'; '5' = '経過通知'; '2' = '相手を呼出(呼出音)'; '6' = '応答'; '1' = '切断' }
$CallStageRank = @{ '0' = 1; '4' = 2; '3' = 3; '5' = 4; '2' = 5; '6' = 6 }
# ITU-T Q.850 の主な理由番号
$Q850Text = @{
    '1' = '番号が存在しない'; '3' = '経路なし'; '16' = '通常の切断'; '17' = '話中'; '18' = '応答なし(端末)'
    '19' = '応答なし(呼出済み)'; '20' = '加入者不在'; '21' = '拒否'; '22' = '番号変更'; '27' = '相手側故障'
    '28' = '番号の形式誤り'; '29' = 'サービス拒否'; '31' = '正常、その他'; '34' = '回線なし'; '38' = '網の故障'
    '41' = '一時的な障害'; '42' = '交換機の輻輳'; '44' = '指定回線なし'; '47' = '資源不足'; '50' = '未契約のサービス'
    '57' = '許可されていない'; '58' = '利用できない'; '63' = 'サービス不可'; '65' = '未実装のサービス'
    '79' = '未実装'; '102' = 'タイマー満了'; '111' = 'プロトコル誤り'; '127' = '相互接続、その他'
}

function Get-CallJudgement {
    param([string]$Res)
    $j = @{ result = '失敗'; code = ''; samples = @(); stage = ''; cause = ''; causeText = ''; gps = ''; ciev = @(); notify = $false }
    $afterIdx = $Res.IndexOf('--- after ')
    $callPart = $Res
    if ($afterIdx -ge 0) { $callPart = $Res.Substring(0, $afterIdx) }

    # 独自通知 (ATH より前の部分だけを見る)
    $stages = @([regex]::Matches($callPart, '\+SKCPI:\s*\d+\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)'))
    $rel    = [regex]::Match($callPart, '\+SKCCSI:\s*\d+\s*,\s*\d+\s*,\s*6\s*,\s*\d+\s*,\s*\d+\s*,\s*(\d*)')
    $relCpi = [regex]::Match($callPart, '\+SKCPI:\s*\d+\s*,\s*1\s*,')
    $j.notify = ($stages.Count -gt 0 -or $rel.Success)
    $best = ''; $bestRank = 0; $tch = $false
    foreach ($m in $stages) {
        $st = $m.Groups[1].Value
        if ($st -eq '5' -and $m.Groups[2].Value -eq '1') { $st = '2' }   # 経過通知 + 呼出音 = 相手を呼出中
        if ($m.Groups[3].Value -eq '1') { $tch = $true }
        if ($CallStageRank.ContainsKey($st) -and $CallStageRank[$st] -gt $bestRank) { $best = $st; $bestRank = $CallStageRank[$st] }
    }
    if ($best) { $j.stage = $CallStageName[$best] }
    $relIdx = -1
    if ($rel.Success) {
        $relIdx = $rel.Index
        $j.cause = $rel.Groups[1].Value
        if ($Q850Text.ContainsKey($j.cause)) { $j.causeText = $Q850Text[$j.cause] }
    }
    if ($relCpi.Success -and ($relIdx -lt 0 -or $relCpi.Index -lt $relIdx)) { $relIdx = $relCpi.Index }
    $gps = @([regex]::Matches($callPart, '\+SKGPSPOSI:\s*(\d)') | ForEach-Object { $_.Groups[1].Value })
    if ($gps.Count -gt 0) { $j.gps = ($gps -join '→') }
    $j.ciev = @([regex]::Matches($callPart, '\+CIEV:\s*2\s*,\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })

    # 通話中の AT+CSQ (切断の通知より後のものは、通話中に数えない)
    $segs = [regex]::Split($callPart, '--- during [^\r\n]*')
    $atd = $segs[0]
    $pos = $segs[0].Length
    for ($k = 1; $k -lt $segs.Count; $k++) {
        $segStart = $callPart.IndexOf($segs[$k], $pos)
        if ($segStart -ge 0) { $pos = $segStart }
        if ($relIdx -ge 0 -and $pos -ge $relIdx) { break }
        $v = Get-CsqValue $segs[$k]
        if ($v) { $j.samples += $v }
    }

    $first = [regex]::Match($atd, '(?m)^(OK|ERROR|\+CM[ES] ERROR:[^\r\n]*|NO CARRIER|BUSY|NO ANSWER|NO DIALTONE)\s*$')
    $end   = [regex]::Match($callPart, '(?m)^(NO CARRIER|BUSY|NO ANSWER|NO DIALTONE)\s*$')
    $stageNote = ''
    if ($j.stage) { $stageNote = ' / 到達: ' + $j.stage }
    if ($Res -match 'IO Error') {
        $j.code = ((Format-Response $Res) -split "`n")[0]
    } elseif (-not $first.Success) {
        $j.code = '応答なし'
    } elseif ($first.Groups[1].Value -ne 'OK') {
        $j.code = $first.Groups[1].Value.Trim()
    } elseif ($relIdx -ge 0 -and $bestRank -ge 4 -and @('16', '18', '19') -contains $j.cause) {
        # 呼出音まで進んだあと、相手側・網側で通常どおり切れた (応答なしで呼出が終わった など) → 呼は成立していた
        $j.result = '成功'
        $j.code = '呼出後に切断 理由' + $j.cause + ' (' + $j.causeText + ')' + $stageNote
    } elseif ($relIdx -ge 0) {
        $c = '切断'
        if ($j.cause) { $c += ' 理由' + $j.cause }
        if ($j.causeText) { $c += ' (' + $j.causeText + ')' }
        $j.code = $c + $stageNote
    } elseif ($afterIdx -ge 0 -and $end.Success) {
        $j.code = $end.Groups[1].Value + ' (呼出中に終了)' + $stageNote
    } elseif ($j.notify -and -not ($tch -or $bestRank -ge 2)) {
        $j.code = '回線未確立' + $stageNote
    } else {
        $j.result = '成功'
        $j.code = 'OK' + $stageNote
    }
    return $j
}

function Get-CallCsvPath {
    param([datetime]$d)
    return (Join-Path $LogPath ('call_' + $d.ToString('yyyyMM') + '.csv'))
}

$CallCsvHeader = 'Timestamp,Slot,Time,Number,Result,Code,RssiBefore,BerBefore,RssiDuringAvg,RssiDuringMin,BerDuringMax,DuringSamples,RssiAfter,BerAfter,DurationSec,Stage,Cause,CauseText,GpsPos,CievMin'

function Add-CallCsvLine {
    param([datetime]$d, [string]$line)
    try {
        $p = Get-CallCsvPath $d
        if (-not (Test-Path -LiteralPath $p)) {
            [System.IO.File]::WriteAllText($p, $CallCsvHeader + "`r`n", $Utf8Bom)
            Write-TestLog 'INFO' ('発信試験 CSV 新規作成: ' + $p)
        } else {
            # 列を足す前の見出しなら、見出しの行だけ新しいものに置き換える (データの行はそのまま)
            $all = [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)
            if ($all.Count -gt 0 -and $all[0].TrimStart([char]0xFEFF) -ne $CallCsvHeader) {
                $all[0] = $CallCsvHeader
                [System.IO.File]::WriteAllLines($p, $all, $Utf8Bom)
                Write-TestLog 'INFO' ('発信試験 CSV の見出しを更新: ' + $p)
            }
        }
        [System.IO.File]::AppendAllText($p, $line + "`r`n", $Utf8Bom)
    } catch {
        Write-Host ('発信試験 CSV 書き込み失敗 (Excel で開いていませんか?): ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-TestLog 'ERR' ('発信試験 CSV 書き込み失敗: ' + $_.Exception.Message)
    }
}

# 値が無いときは空欄、ある値はそのまま (CSV と画面で共通)
function Get-Cell { param($v) if ($null -eq $v) { return '' } return [string]$v }

# 起動時に、今日の発信試験の結果を CSV から読み戻す (画面の「今日の結果」のため)
function Import-CallResults {
    $p = Get-CallCsvPath (Get-Date)
    if (-not (Test-Path -LiteralPath $p)) { return }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    foreach ($l in (Get-Content -LiteralPath $p -Encoding UTF8)) {
        if (-not $l.StartsWith($today)) { continue }
        $c = $l -split ','
        if ($c.Count -lt 15) { continue }
        $x = @{
            t = $c[0]; slot = [int]$c[1]; time = $c[2]; number = $c[3]; result = $c[4]; code = $c[5]
            rb = $c[6]; bb = $c[7]; rdAvg = $c[8]; rdMin = $c[9]; bdMax = $c[10]; n = $c[11]; ra = $c[12]; ba = $c[13]; dur = $c[14]
            stage = ''; cause = ''; causeText = ''; gps = ''; cievMin = ''
        }
        if ($c.Count -ge 20) { $x.stage = $c[15]; $x.cause = $c[16]; $x.causeText = $c[17]; $x.gps = $c[18]; $x.cievMin = $c[19] }
        [void]$script:CallResults.Add($x)
    }
    Write-TestLog 'INFO' ('今日の発信試験の結果を読込: ' + $script:CallResults.Count + ' 件')
}

function Invoke-TestCall {
    param($Slot, [datetime]$now)
    $num = [string]$Slot.number
    $dur = [int]$script:CallTable.durationSec
    $nowStr = $now.ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host ($now.ToString('HH:mm') + '  試験発信 ' + $num + ' (' + $dur + ' 秒)')
    Write-TestLog 'INFO' ('試験発信 開始  ' + $Slot.hour + ' 時の行  ' + $Slot.time + '  ' + $num + '  ' + $dur + 's')

    # 1. 発信直前
    $before = Get-CsqValue (Invoke-AtLog 'AT+CSQ' 3)
    # 2. 発信 (通話中も AT+CSQ)・切断
    $during = ''
    if ([int]$CallDuringEverySec -gt 0) { $during = 'AT+CSQ' }
    $res = [string](Invoke-AtLog ('ATD' + $num + ';') $dur 'ATH' $during ([int]$CallDuringEverySec))
    # 3. 切断直後
    $after = Get-CsqValue (Invoke-AtLog 'AT+CSQ' 3)

    $j = Get-CallJudgement $res
    $rs = @($j.samples | Where-Object { $_.r -ne 99 } | ForEach-Object { $_.r })
    $bs = @($j.samples | Where-Object { $_.b -ne 99 } | ForEach-Object { $_.b })
    $rdAvg = $null; $rdMin = $null; $bdMax = $null
    if ($rs.Count -gt 0) {
        $rdAvg = [Math]::Round((($rs | Measure-Object -Average).Average), 1)
        $rdMin = ($rs | Measure-Object -Minimum).Minimum
    }
    if ($bs.Count -gt 0) { $bdMax = ($bs | Measure-Object -Maximum).Maximum }
    $rb = $null; $bb = $null; $ra = $null; $ba = $null
    if ($before) { $rb = $before.r; $bb = $before.b }
    if ($after)  { $ra = $after.r;  $ba = $after.b }

    $r = @{
        t = $nowStr; slot = [int]$Slot.hour; time = [string]$Slot.time; number = $num; result = $j.result; code = $j.code
        rb = (Get-Cell $rb); bb = (Get-Cell $bb); rdAvg = (Get-Cell $rdAvg); rdMin = (Get-Cell $rdMin); bdMax = (Get-Cell $bdMax)
        n = [string]@($j.samples).Count; ra = (Get-Cell $ra); ba = (Get-Cell $ba); dur = [string]$dur
        stage = $j.stage; cause = $j.cause; causeText = $j.causeText; gps = $j.gps; cievMin = ''
    }
    if (@($j.ciev).Count -gt 0) { $r.cievMin = [string](($j.ciev | Measure-Object -Minimum).Minimum) }
    [void]$script:CallResults.Add($r)
    $codeCsv = $j.code -replace ',', ' '
    Add-CallCsvLine $now (($nowStr, $r.slot, $r.time, $num, $r.result, $codeCsv, $r.rb, $r.bb, $r.rdAvg, $r.rdMin, $r.bdMax, $r.n, $r.ra, $r.ba, $r.dur,
                            $r.stage, $r.cause, $r.causeText, ($r.gps -replace ',', ' '), $r.cievMin) -join ',')
    Add-CsvLine $now ($nowStr + ',,,,,TestCall ' + $num + ' ' + $j.result)
    Write-TestLog 'INFO' ('試験発信 終了  ' + $j.result + '  ' + $j.code + '  直前=' + $r.rb + '/' + $r.bb + '  通話中(平均/最小/ber最大/回数)=' + $r.rdAvg + '/' + $r.rdMin + '/' + $r.bdMax + '/' + $r.n + '  直後=' + $r.ra + '/' + $r.ba + '  到達=' + $r.stage + '  理由=' + $r.cause + ' ' + $r.causeText + '  GPS=' + $r.gps + '  CIEV最小=' + $r.cievMin)
    if ($j.gps -match '0') { Write-TestLog 'WARN' ('発信中に GPS の位置が 0 になりました (SKGPSPOSI=' + $j.gps + ')') }
    if ($during -and $j.result -eq '成功' -and @($j.samples).Count -eq 0 -and -not $j.notify) {
        Write-TestLog 'WARN' '通話中の AT+CSQ に応答がありません (機器が通話中に AT コマンドを受け付けない可能性)'
    }
    Write-Host ($now.ToString('HH:mm') + '  試験発信 ' + $j.result + ' (' + $j.code + ')  rssi 直前=' + $r.rb + ' 通話中=' + $r.rdAvg + ' 直後=' + $r.ra)
    Write-Data
}

# ---------------- 評価トレンド (trend.js) と変化のコメント ----------------
#   監視はふだんの受信グラフ (3 分ごとの全点、既定 3 日)。評価用には $TrendDays 日分 (既定 7 日) を
#   15 分ごとにまとめた trend.js を 10 分ごとに作る (data.js は軽いまま)。
#   変化のコメント (同軸を抜いた・衛星出力 UP など) は logs\events.csv。画面の「コメントを追加」で
#   保存した csqwatch_event*.json を取り込んで追記する。events.csv をメモ帳で直接直してもよい。
$TrendJs   = Join-Path $Dir 'trend.js'
$EventsCsv = Join-Path $LogPath 'events.csv'
if (-not $TrendDays -or [int]$TrendDays -le 0) { $TrendDays = 7 }
$TrendBucketMin = 15
$script:TrendAt = [datetime]::MinValue

# 期間内の月の一覧 (月をまたいでも読めるように)
function Get-TrendMonths {
    param([datetime]$From, [datetime]$To)
    $m = New-Object DateTime($From.Year, $From.Month, 1)
    $list = @()
    while ($m -le $To) { $list += $m; $m = $m.AddMonths(1) }
    return $list
}

function Read-TrendLines {
    param([string]$Prefix, [datetime]$From, [datetime]$To, [string]$OldPrefix = '')
    $fromStr = $From.ToString('yyyy-MM-dd HH:mm:ss')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($m in (Get-TrendMonths $From $To)) {
        $p = Join-Path $LogPath ($Prefix + $m.ToString('yyyyMM') + '.csv')
        if (-not (Test-Path -LiteralPath $p) -and $OldPrefix) { $p = Join-Path $LogPath ($OldPrefix + $m.ToString('yyyyMM') + '.csv') }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($l in [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)) {
            if ($l.Length -ge 19 -and $l.Substring(0, 19) -ge $fromStr -and $l[0] -match '\d') { $out.Add($l) }
        }
    }
    return $out
}

function Read-Events {
    param([datetime]$From)
    $list = @()
    if (-not (Test-Path -LiteralPath $EventsCsv)) { return $list }
    $fromStr = $From.ToString('yyyy-MM-dd HH:mm')
    foreach ($l in [System.IO.File]::ReadAllLines($EventsCsv, [System.Text.Encoding]::UTF8)) {
        $l = $l.TrimStart([char]0xFEFF)
        $i = $l.IndexOf(',')
        if ($i -lt 16) { continue }
        $ts = $l.Substring(0, $i).Trim()
        if ($ts -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}') { continue }   # 見出しの行など
        if ($ts.Substring(0, 16) -lt $fromStr) { continue }
        $rest = $l.Substring($i + 1)
        $id = ''
        $j = $rest.LastIndexOf(',')
        # 3 列目 (Id。画面から足したときの保存日時) があれば外す。メモ帳で足した行は Id が空でもよい
        if ($j -ge 0) {
            $tail = $rest.Substring($j + 1).Trim()
            if ($tail -eq '' -or $tail -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') { $id = $tail; $rest = $rest.Substring(0, $j) }
        }
        $list += @{ t = $ts.Substring(0, 16); text = $rest.Trim(); id = $id }
    }
    return $list
}

function Write-Trend {
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $now = Get-Date
        $s = $now.AddDays(-[int]$TrendDays)
        $start = New-Object DateTime($s.Year, $s.Month, $s.Day, $s.Hour, ([int][Math]::Floor($s.Minute / $TrendBucketMin) * $TrendBucketMin), 0)
        $count = [int][Math]::Ceiling(($now - $start).TotalMinutes / $TrendBucketMin)
        $sum = New-Object double[] $count; $n = New-Object int[] $count
        $mn = New-Object int[] $count; $mx = New-Object int[] $count; $bm = New-Object int[] $count
        $fail = New-Object int[] $count; $outN = New-Object int[] $count
        for ($k = 0; $k -lt $count; $k++) { $mn[$k] = 999; $mx[$k] = -1; $bm[$k] = -1 }

        foreach ($l in (Read-TrendLines 'csq_' $start $now 'isat_')) {
            $c = $l -split ','
            if ($c.Count -lt 4) { continue }
            $ts = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($c[0], 'yyyy-MM-dd HH:mm:ss', $null, 0, [ref]$ts)) { continue }
            $k = [int][Math]::Floor(($ts - $start).TotalMinutes / $TrendBucketMin)
            if ($k -lt 0 -or $k -ge $count) { continue }
            $r = 0
            if (-not [int]::TryParse($c[1], [ref]$r)) { continue }          # 発信試験の印の行 (RSSI が空) は数えない
            if ($c[2] -eq 'N/A' -or $c[2] -eq '取得失敗') { $fail[$k]++; continue }
            if ($r -eq 99) { $outN[$k]++; continue }
            $sum[$k] += $r; $n[$k]++
            if ($r -lt $mn[$k]) { $mn[$k] = $r }
            if ($r -gt $mx[$k]) { $mx[$k] = $r }
            $b = 0
            if ([int]::TryParse($c[3], [ref]$b) -and $b -ne 99 -and $b -gt $bm[$k]) { $bm[$k] = $b }
        }
        $buckets = New-Object System.Collections.Generic.List[object]
        for ($k = 0; $k -lt $count; $k++) {
            $t = $start.AddMinutes($k * $TrendBucketMin).ToString('yyyy-MM-dd HH:mm')
            if ($n[$k] -gt 0) {
                $buckets.Add(@{ t = $t; a = [Math]::Round($sum[$k] / $n[$k], 1); lo = $mn[$k]; hi = $mx[$k]; b = $(if ($bm[$k] -ge 0) { $bm[$k] } else { $null }); f = $fail[$k]; o = $outN[$k] })
            } else {
                $buckets.Add(@{ t = $t; a = $null; lo = $null; hi = $null; b = $null; f = $fail[$k]; o = $outN[$k] })
            }
        }

        $calls = New-Object System.Collections.Generic.List[object]
        foreach ($l in (Read-TrendLines 'call_' $start $now)) {
            $c = $l -split ','
            if ($c.Count -lt 15) { continue }
            $x = @{ t = $c[0].Substring(0, 16); slot = $c[1]; result = $c[4]; code = $c[5]; rb = $c[6]; bb = $c[7]; rdAvg = $c[8]; rdMin = $c[9]; bdMax = $c[10]; ra = $c[12]; ba = $c[13]; stage = ''; cause = ''; gps = '' }
            if ($c.Count -ge 20) { $x.stage = $c[15]; $x.cause = $c[16]; $x.gps = $c[18] }
            $calls.Add($x)
        }

        $obj = @{
            made = $now.ToString('yyyy-MM-dd HH:mm:ss'); days = [int]$TrendDays; bucketMin = $TrendBucketMin
            start = $start.ToString('yyyy-MM-dd HH:mm'); rssiMax = $RssiMax
            buckets = $buckets.ToArray(); calls = $calls.ToArray(); events = @(Read-Events $start)
        }
        $json = ConvertTo-Json -InputObject $obj -Depth 4 -Compress
        $tmp = $TrendJs + '.tmp'
        [System.IO.File]::WriteAllText($tmp, ('window.CSQ_TREND = ' + $json + ';'), $Utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $TrendJs -Force -ErrorAction Stop
        $script:TrendAt = $now
        Write-TestLog 'DBG' ('trend.js 更新  ' + $count + ' 区間  発信試験 ' + $calls.Count + ' 件  コメント ' + @($obj.events).Count + ' 件  ' + $sw.ElapsedMilliseconds + 'ms')
    } catch {
        Write-TestLog 'WARN' ('trend.js を作れませんでした: ' + $_.Exception.Message)
    }
}

# 画面で保存されたコメント (csqwatch_event*.json) を取り込み、events.csv に追記する
function Receive-Events {
    $dirs = @($script:CallInbox, $Dir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    $files = @()
    foreach ($d in $dirs) { $files += @(Get-ChildItem -LiteralPath $d -Filter 'csqwatch_event*.json' -File -ErrorAction SilentlyContinue) }
    $files = @($files | Where-Object { -not $script:InboxDone.ContainsKey($_.FullName + '|' + $_.LastWriteTime.Ticks) } | Sort-Object LastWriteTime)
    if ($files.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $CallHistDir)) { New-Item -ItemType Directory -Path $CallHistDir -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $added = 0
    foreach ($f in $files) {
        $script:InboxDone[$f.FullName + '|' + $f.LastWriteTime.Ticks] = $true
        $suffix = ''
        try {
            $o = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $t = ([string]$o.t).Trim()
            if ($t -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$') { throw ('日時の形式が正しくありません (' + $t + ')') }
            $text = (([string]$o.text) -replace "[`r`n]+", ' ' -replace ',', '、').Trim()
            if (-not $text) { throw 'コメントが空です' }
            if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
            $id = ([string]$o.id).Trim()
            if (-not (Test-Path -LiteralPath $EventsCsv)) {
                [System.IO.File]::WriteAllText($EventsCsv, "Timestamp,Text,Id`r`n", $Utf8Bom)
            }
            [System.IO.File]::AppendAllText($EventsCsv, ($t + ',' + $text + ',' + $id + "`r`n"), $Utf8Bom)
            Write-TestLog 'INFO' ('コメントを追加: ' + $t + '  ' + $text)
            Write-Host ((Get-Date).ToString('HH:mm:ss') + '  コメントを追加しました: ' + $t + '  ' + $text) -ForegroundColor Cyan
            $added++
        } catch {
            $suffix = '.rejected'
            Write-TestLog 'WARN' ('コメントを取り込めませんでした: ' + $_.Exception.Message + '  file=' + $f.FullName)
        }
        try {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $CallHistDir ($stamp + '_' + $f.Name + $suffix)) -Force -ErrorAction Stop
        } catch {
            Write-TestLog 'WARN' ('取り込んだコメントのファイルを移動できません: ' + $f.FullName)
        }
    }
    if ($added -gt 0) { Write-Trend }
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
Write-TestLog 'INFO' ('設定  mode=' + $modeText + '  interval=' + $IntervalSec + 's  history=' + $HistoryHours + 'h/' + $HistoryMax + '点  trend=' + $TrendDays + '日  Device=' + $DeviceName + '  RssiMax=' + $RssiMax + '  Extras=' + @($Extras).Count + '  AtIo=' + $ioStr)

Import-History
$script:CallInbox = Get-CallInbox
Write-TestLog 'INFO' ('タイムテーブルの受け取り先: ' + $script:CallInbox)
Import-CallTable
Import-CallResults
Write-Data
Write-Trend
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
        # 画面で保存されたタイムテーブルを 5 秒ごとに探す
        if (($now - $script:InboxCheckAt).TotalSeconds -ge 5) {
            $script:InboxCheckAt = $now
            Receive-CallTable
            Receive-Events
        }
        # 評価トレンドは 10 分ごとに作り直す
        if (($now - $script:TrendAt).TotalMinutes -ge 10) { Write-Trend }
        # 発信試験 (同じ分に 2 度は発信しない)
        if ($script:CallTable.enabled -and ($LastCallKey -ne $key)) {
            $hm = $now.ToString('HH:mm')
            $slot = $null
            foreach ($s in $script:CallTable.slots) { if ($s.on -and $s.time -eq $hm) { $slot = $s; break } }
            if ($slot) {
                $LastCallKey = $key
                Invoke-TestCall $slot $now
                Write-Trend                      # 試験の結果をすぐトレンドにも出す
                $next = Get-Date                 # 発信の直後に 1 回取得する
            }
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
