# ============================================================
# Merge.ps1 : 過去のデータを、今のデータの保存先 ($LogDir) にまとめる
#   Author: yuichi
#   使い方:  Merge.bat                       (フォルダを選ぶ画面が出ます)
#            Merge.bat "D:\old\logs" "E:\pc2\app\logs"   (フォルダを並べて指定)
#   ・Monitor を止めてから使います (動いていると止まります)
#   ・まとめるもの: 受信ログ csq_YYYYMM.csv (旧名 isat_YYYYMM.csv も)、発信試験 call_YYYYMM.csv、
#     変化のコメント events.csv、試験ログ test_YYYYMMDD.log
#   ・同じ行は 1 つにし、日時の順に並べ直します。同じ日時で中身が違う行は両方残し、件数を報告します
#     (別の端末のデータを混ぜていないかの目安)
#   ・書き換える前のファイルは <保存先>\merge_backup\<日時>\ に残します
#   ・まず「何件増えるか」を表示し、Y で確定するまで何も書き換えません
#   ・読むだけのフォルダ (元のデータ) は変更しません
# ============================================================
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Source = @(),
    [string]$Dest = '',
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Dir = $PSScriptRoot
if (-not $Dir) { $Dir = Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location -LiteralPath $Dir
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

# Monitor.ps1 と同じ見出し (列を足したら両方を直すこと)
$CsqHeader  = 'Timestamp,RSSI,Level,BER,RegStatus,Notes'
$CallHeader = 'Timestamp,Slot,Time,Number,Result,Code,RssiBefore,BerBefore,RssiDuringAvg,RssiDuringMin,BerDuringMax,DuringSamples,RssiAfter,BerAfter,DurationSec,Stage,Cause,CauseText,GpsPos,CievMin,Try'
$EvHeader   = 'Timestamp,Text,Id'
$CallCols   = ($CallHeader -split ',').Count

# ---- 保存先 (Config.ps1 の $LogDir。Monitor と同じ決め方) ----
if (-not $Dest) {
    $LogDir = 'logs'
    $cfg = Join-Path $Dir 'Config.ps1'
    if (Test-Path -LiteralPath $cfg) { . $cfg }
    if (-not $LogDir) { $LogDir = 'logs' }
    if ([System.IO.Path]::IsPathRooted([string]$LogDir)) { $Dest = [string]$LogDir } else { $Dest = Join-Path $Dir $LogDir }
}
if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
$Dest = (Resolve-Path -LiteralPath $Dest).ProviderPath.TrimEnd('\', '/')

# ---- Monitor が動いていないこと (動いていると CSV に書き足すので、まとめられない) ----
foreach ($name in @('Global\CsqWatch', 'Global\CsqWatch_Mock')) {
    $m = $null
    try { $m = [System.Threading.Mutex]::OpenExisting($name) } catch { $m = $null }
    if ($m) {
        $m.Dispose()
        Write-Host 'Monitor が動いています。Monitor を止めてから、もう一度 Merge.bat を実行してください。' -ForegroundColor Yellow
        exit 3
    }
}

# ---- 元のフォルダ ----
$Source = @($Source | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().Trim('"') })
if ($Source.Count -eq 0) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $fd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fd.Description = 'まとめたい過去のデータのフォルダ (logs など) を選んでください'
        if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Source = @($fd.SelectedPath) }
    } catch {
        $s = Read-Host '過去のデータのフォルダを入力してください'
        if ($s) { $Source = @($s.Trim().Trim('"')) }
    }
}
if ($Source.Count -eq 0) { Write-Host '何も選ばれませんでした。'; exit 0 }

Write-Host ('保存先 : ' + $Dest)
$files = @()
foreach ($s in $Source) {
    if (-not (Test-Path -LiteralPath $s)) { Write-Host ('見つかりません: ' + $s) -ForegroundColor Yellow; continue }
    $full = (Resolve-Path -LiteralPath $s).ProviderPath.TrimEnd('\', '/')
    if ($full -eq $Dest) { Write-Host ('保存先と同じフォルダなので飛ばします: ' + $full) -ForegroundColor Yellow; continue }
    Write-Host ('元     : ' + $full)
    $files += @(Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.FullName -notmatch '[\\/](calltable_history|merge_backup)[\\/]' -and
        -not $_.FullName.StartsWith($Dest + [System.IO.Path]::DirectorySeparatorChar) -and
        $_.Name -match '^((csq|isat|call)_\d{6}\.csv|events\.csv|test_\d{8}\.log)$'
    })
}
if ($files.Count -eq 0) { Write-Host 'まとめるファイルが見つかりませんでした (csq_/isat_/call_YYYYMM.csv、events.csv、test_*.log)。'; exit 0 }

# ---- 読み込み ----
function Read-DataLines {
    param([string]$Path)
    $out = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($l in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $l = $l.TrimStart([char]0xFEFF).TrimEnd()
        if ($l.Length -ge 10 -and [char]::IsDigit($l[0])) { $out.Add($l) }
    }
    return $out.ToArray()
}

# 列の足りない古い発信試験の行は、空の列を足して今の形にそろえる
function Format-CallLine {
    param([string]$l)
    $n = ($l -split ',').Count
    if ($n -lt $CallCols) { $l += (',' * ($CallCols - $n)) }
    return $l
}

# コメントの日時をそろえる (2026/10/28 9:30 → 2026-10-28 09:30)
function Format-EventLine {
    param([string]$l)
    $i = $l.IndexOf(',')
    if ($i -lt 0) { return $null }
    $m = [regex]::Match($l.Substring(0, $i).Trim('"', ' '), '^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[ T]+(\d{1,2}):(\d{1,2})')
    if (-not $m.Success) { return $null }
    $t = '{0}-{1:D2}-{2:D2} {3:D2}:{4:D2}' -f $m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, [int]$m.Groups[4].Value, [int]$m.Groups[5].Value
    return ($t + $l.Substring($i))
}

# 行の鍵 (重複の判定と並べ替え): 受信ログ・発信試験は日時 19 文字、コメントは日時 + 内容
function Get-Key {
    param([string]$Kind, [string]$l)
    if ($Kind -eq 'events') {
        $p = $l -split ','
        return ($p[0] + '|' + $p[1])
    }
    return $l.Substring(0, [Math]::Min(19, $l.Length))
}

# まとめる先ごとに、元の行を集める
$plan = [ordered]@{}
function Add-Plan {
    param([string]$Target, [string]$Kind, [string]$Header, $Lines, [string]$From)
    if (-not $plan.Contains($Target)) { $plan[$Target] = @{ kind = $Kind; header = $Header; src = New-Object System.Collections.Generic.List[string]; from = @() } }
    foreach ($l in $Lines) { $plan[$Target].src.Add($l) }
    $plan[$Target].from += $From
}
$logCopies = @()
foreach ($f in $files) {
    if ($f.Name -match '^(csq|isat|call)_\d{6}\.csv$') {
        # 月別のファイルは、ファイル名ではなく各行の日時の月へ振り分ける
        $kind = 'csq'; $hdr = $CsqHeader
        if ($f.Name.StartsWith('call_')) { $kind = 'call'; $hdr = $CallHeader }
        $byMonth = @{}
        foreach ($l in @(Read-DataLines $f.FullName)) {
            if ($l -notmatch '^(\d{4})-(\d{2})-\d{2} ') { continue }
            if ($kind -eq 'call') { $l = Format-CallLine $l }
            $mon = $Matches[1] + $Matches[2]
            if (-not $byMonth.ContainsKey($mon)) { $byMonth[$mon] = New-Object System.Collections.Generic.List[string] }
            $byMonth[$mon].Add($l)
        }
        foreach ($mon in $byMonth.Keys) { Add-Plan ($kind + '_' + $mon + '.csv') $kind $hdr $byMonth[$mon] $f.FullName }
    } elseif ($f.Name -eq 'events.csv') {
        $ls = @(Read-DataLines $f.FullName | ForEach-Object { Format-EventLine $_ } | Where-Object { $_ })
        Add-Plan 'events.csv' 'events' $EvHeader $ls $f.FullName
    } else {
        $logCopies += $f
    }
}

# ---- 計画 (何件増えるか) ----
$results = @()
foreach ($target in $plan.Keys) {
    $p = $plan[$target]
    $destPath = Join-Path $Dest $target
    $cur = Read-DataLines $destPath
    if ($p.kind -eq 'call') { $cur = @($cur | ForEach-Object { Format-CallLine $_ }) }
    if ($p.kind -eq 'events') { $cur = @($cur | ForEach-Object { Format-EventLine $_ } | Where-Object { $_ }) }
    $seenLine = New-Object 'System.Collections.Generic.HashSet[string]'
    $byKey = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    $n = 0; $added = 0; $dup = 0; $conflict = 0
    foreach ($pair in @(@{ l = $cur; own = $true }, @{ l = $p.src; own = $false })) {
        foreach ($l in $pair.l) {
            $k = Get-Key $p.kind $l
            if ($p.kind -eq 'events') {
                # コメントは日時と内容が同じなら同じもの (Id の違いは見ない。保存先のものを残す)
                if ($byKey.ContainsKey($k)) { if (-not $pair.own) { $dup++ }; continue }
                $byKey[$k] = $l
            } else {
                if (-not $seenLine.Add($l)) { if (-not $pair.own) { $dup++ }; continue }
                # 同じ日時で中身が違う (発信の印の行は除く) → 両方残して数える
                $isMark = ($p.kind -eq 'csq' -and $l -match 'TestCall')
                if (-not $isMark) {
                    if ($byKey.ContainsKey($k) -and -not $pair.own) { $conflict++ }
                    $byKey[$k] = $true
                }
            }
            $rows.Add(@{ k = $k; i = $n; l = $l }); $n++
            if (-not $pair.own) { $added++ }
        }
    }
    $results += @{ target = $target; path = $destPath; header = $p.header; before = @($cur).Count; added = $added; dup = $dup; conflict = $conflict; rows = $rows; from = $p.from }
}

$copyPlan = @()
foreach ($f in $logCopies) {
    $to = Join-Path $Dest $f.Name
    if (Test-Path -LiteralPath $to) {
        if ((Get-FileHash -LiteralPath $to).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $k = 1
        do { $to = Join-Path $Dest ($base + '_merged' + $k + '.log'); $k++ } while (Test-Path -LiteralPath $to)
    }
    $copyPlan += @{ from = $f.FullName; to = $to }
}

$report = New-Object System.Collections.Generic.List[string]
$report.Add('CsqWatch データのまとめ  ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$report.Add('保存先: ' + $Dest)
foreach ($s in $Source) { $report.Add('元    : ' + $s) }
$report.Add('')
$report.Add('ファイル            今まで   増える   重複   同じ日時で中身が違う')
foreach ($r in $results) {
    $report.Add(('{0,-18} {1,7} {2,8} {3,6} {4,8}' -f $r.target, $r.before, $r.added, $r.dup, $r.conflict))
}
foreach ($c in $copyPlan) { $report.Add('試験ログを追加      ' + [System.IO.Path]::GetFileName($c.to) + '  (' + $c.from + ')') }
$changed = @($results | Where-Object { $_.added -gt 0 })
if ($changed.Count -eq 0 -and $copyPlan.Count -eq 0) {
    $report | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host 'すべて保存先にあります。書き換えるものはありません。' -ForegroundColor Green
    exit 0
}
$report | ForEach-Object { Write-Host $_ }
if (@($results | Where-Object { $_.conflict -gt 0 }).Count -gt 0) {
    Write-Host ''
    Write-Host '「同じ日時で中身が違う」行があります。別の端末・別の PC のデータを混ぜていないか確認してください (両方残します)。' -ForegroundColor Yellow
}
Write-Host ''
if (-not $Yes) {
    $a = Read-Host 'この内容でまとめますか? (Y で実行)'
    if ($a -ne 'Y' -and $a -ne 'y') { Write-Host '取りやめました。何も変更していません。'; exit 0 }
}

# ---- 実行 (書き換える前のファイルは merge_backup へ) ----
$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$bk = Join-Path (Join-Path $Dest 'merge_backup') $stamp
New-Item -ItemType Directory -Path $bk -Force | Out-Null
foreach ($r in $changed) {
    if (Test-Path -LiteralPath $r.path) { Copy-Item -LiteralPath $r.path -Destination (Join-Path $bk $r.target) -Force }
    $sorted = @($r.rows | Sort-Object { $_.k }, { $_.i } | ForEach-Object { $_.l })
    $tmp = $r.path + '.merge_tmp'
    [System.IO.File]::WriteAllText($tmp, ($r.header + "`r`n" + ($sorted -join "`r`n") + "`r`n"), $Utf8Bom)
    Move-Item -LiteralPath $tmp -Destination $r.path -Force
}
foreach ($c in $copyPlan) { Copy-Item -LiteralPath $c.from -Destination $c.to }
$report.Add('')
$report.Add('書き換える前のファイル: ' + $bk)
$rp = Join-Path $Dest ('merge_report_' + $stamp + '.txt')
[System.IO.File]::WriteAllLines($rp, $report, $Utf8Bom)
Write-Host ''
Write-Host ('まとめました。書き換える前のファイルは ' + $bk + ' にあります。') -ForegroundColor Green
Write-Host ('記録: ' + $rp)
Write-Host 'Monitor を起動すると、まとめたデータでグラフと評価トレンドを作り直します。'
exit 0
