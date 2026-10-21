# ============================================================
# Common.ps1 : AT コマンド送信の共通部 (通常は編集不要)
#   Author: yuichi
#   Monitor.ps1 と Probe.ps1 から読み込まれます。
#   -Mock のときは AtIo.exe を呼ばず、疑似応答を返します。
# ============================================================

$script:MockCsq = 37      # IsatPhone 2 の実測 (37〜38) 付近から始める

function Get-MockResponse {
    param([string]$Cmd)
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

# AtIo.exe <Port> <Baud> <Cmd> <WaitSec> [AfterCmd] を呼んで、応答テキストを返す
function Invoke-At {
    param([string]$Cmd, [int]$Wait = 3, [string]$After = '')
    if ($Mock) { return (Get-MockResponse $Cmd) }
    try {
        $exeName = $AtIoExe
        if (-not $exeName) { $exeName = 'AtIo.exe' }
        $exe = Join-Path $Dir $exeName
        $a = @($Port, [string]$BaudRate, $Cmd, [string]$Wait)
        if ($After -ne '') { $a += $After }
        $out = & $exe @a 2>&1 | Out-String
        return $out
    } catch {
        return ('IO Error: ' + $_.Exception.Message)
    }
}
