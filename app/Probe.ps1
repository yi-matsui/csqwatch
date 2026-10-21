# ============================================================
# Probe.ps1 : 機器が対応している AT コマンドを調べる
#   Author: yuichi
#   probe_commands.txt のコマンドを順に送り、応答を probe_*.txt に保存します。
#   使い方:  Probe.bat   (Monitor.bat は止めておくこと。COM ポートは 1 本しか使えません)
# ============================================================
param(
    [switch]$Mock,
    [string]$ListFile = 'probe_commands.txt'
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

if (-not (Test-Path -LiteralPath (Join-Path $Dir $ListFile))) {
    Write-Host ($ListFile + ' が見つかりません。') -ForegroundColor Red
    exit 1
}

$cmds = @(Get-Content -LiteralPath (Join-Path $Dir $ListFile) -Encoding UTF8 |
    ForEach-Object { $_.Trim() } |
    Where-Object { ($_ -ne '') -and (-not $_.StartsWith('#')) })

$sb = New-Object System.Text.StringBuilder
$summary = @()
[void]$sb.AppendLine('# Probe ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  port=' + $Port + ' baud=' + $BaudRate + ' mock=' + [bool]$Mock)
Write-Host ('対象: ' + $Port + ' @' + $BaudRate + '  コマンド数: ' + $cmds.Count)

foreach ($c in $cmds) {
    $r = (Invoke-At $c 5).Trim()
    if ($r -eq '') { $status = 'NO RESPONSE' }
    elseif ($r -match 'IO Error') { $status = 'IO ERROR' }
    elseif ($r -match '(?m)^OK\s*$') { $status = 'OK' }
    elseif ($r -match 'ERROR') { $status = 'ERROR' }
    else { $status = 'OTHER' }

    $summary += ($status.PadRight(12) + $c)
    Write-Host ($status.PadRight(12) + $c)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('> ' + $c + '    [' + $status + ']')
    [void]$sb.AppendLine($r)
}

[void]$sb.AppendLine('')
[void]$sb.AppendLine('# ---- summary ----')
foreach ($s in $summary) { [void]$sb.AppendLine($s) }

$outFile = Join-Path $Dir ('probe_' + (Get-Date).ToString('yyyyMMdd_HHmmss') + '.txt')
[System.IO.File]::WriteAllText($outFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
Write-Host ''
Write-Host ('結果を保存しました: ' + $outFile)
