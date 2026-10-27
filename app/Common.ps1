# ============================================================
# Common.ps1 : AT コマンド送信の共通部 (通常は編集不要)
#   Author: yuichi
#   Monitor.ps1 と Probe.ps1 から読み込まれます。
#   -Mock のときは AtIo.exe を呼ばず、疑似応答を返します。
# ============================================================

$script:MockCsq = 37      # IsatPhone 2 の実測 (37〜38) 付近から始める

function Get-MockResponse {
    param([string]$Cmd, [int]$Wait = 3, [string]$After = '', [string]$During = '', [int]$DuringEvery = 5)
    if ($Cmd -match '^ATD') {
        # 発信試験の疑似応答。AtIo.exe と同じ区切り行 (--- during / --- after) を出す。
        # 8 割は成功、残りは途中の NO CARRIER・BUSY・+CME ERROR。通話中は rssi が少し下がる (干渉の模擬)。
        Start-Sleep -Seconds ([Math]::Min($Wait, 2))
        $dice = Get-Random -Minimum 0 -Maximum 100
        if ($dice -lt 5)  { return "`r`n+CME ERROR: 600`r`n" }
        if ($dice -lt 10) { return "`r`nBUSY`r`n" }
        $out = "`r`nOK`r`n"
        if ($During) {
            $n = [Math]::Max(1, [int][Math]::Floor(($Wait - 2) / [Math]::Max(2, $DuringEvery)))
            if ($dice -lt 20) { $n = 1 }
            for ($k = 0; $k -lt $n; $k++) {
                $r = $script:MockCsq - (Get-Random -Minimum 3 -Maximum 11)
                if ($r -lt 5) { $r = 5 }
                $b = Get-Random -Minimum 0 -Maximum 6
                $out += "`r`n--- during $During`r`n`r`n+CSQ: $r,$b`r`n`r`nOK`r`n"
            }
        }
        if ($dice -lt 20) { $out += "`r`nNO CARRIER`r`n" }
        if ($After) {
            if ($During) { $out += "`r`n--- after $After`r`n" }
            $out += "`r`nOK`r`n"
        }
        return $out
    }
    if ($Cmd -match '^AT\+CSQ$') {
        $n = $script:MockCsq + (Get-Random -Minimum -3 -Maximum 4)
        if ($n -lt 20) { $n = 20 }
        if ($n -gt 50) { $n = 50 }
        $script:MockCsq = $n
        return "`r`n+CSQ: $n,0`r`n`r`nOK`r`n"
    }
    if ($Cmd -match '^AT\+CREG\?$') {
        $st = 1
        if ($script:MockCsq -lt 25) { $st = 2 }
        return "`r`n+CREG: 0,$st`r`n`r`nOK`r`n"
    }
    if ($Cmd -match '^AT\+COPS\?$') { return "`r`n+COPS: 0,0,`"Inmarsat`"`r`n`r`nOK`r`n" }
    if ($Cmd -match '^AT\+CBC$')    { return "`r`n+CBC: 0,85,4012`r`n`r`nOK`r`n" }
    if ($Cmd -match '^(AT|ATH)$')   { return "`r`nOK`r`n" }
    return "`r`nERROR`r`n"
}

# AtIo.exe <Port> <Baud> <Cmd> <WaitSec> [AfterCmd] [DuringCmd] [DuringEverySec] を呼んで、応答テキストを返す
#   During は After と一緒のときだけ渡す (通話中に繰り返し送るコマンド。発信試験の AT+CSQ)
function Invoke-At {
    param([string]$Cmd, [int]$Wait = 3, [string]$After = '', [string]$During = '', [int]$DuringEvery = 5)
    if ($Mock) { return (Get-MockResponse $Cmd $Wait $After $During $DuringEvery) }
    try {
        $exeName = $AtIoExe
        if (-not $exeName) { $exeName = 'AtIo.exe' }
        $exe = Join-Path $Dir $exeName
        $a = @($Port, [string]$BaudRate, $Cmd, [string]$Wait)
        if ($After -ne '') {
            $a += $After
            if ($During -ne '') { $a += $During; $a += [string]$DuringEvery }
        }
        $out = & $exe @a 2>&1 | Out-String
        return $out
    } catch {
        return ('IO Error: ' + $_.Exception.Message)
    }
}
