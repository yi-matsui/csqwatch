# ============================================================
# Build-Manual.ps1 : README と docs/*.md から説明書 app/manual.html (1 冊) を作る
#   Author: yuichi
#
#   Windows 11 標準の PowerShell 5.1 だけで動きます (インストール不要)。
#   MD を直したら、tools\build_manual.bat をダブルクリックして作り直してください。
#
#   このツールの MD 変換は、CsqWatch の文書で使っている書式だけに対応した簡易版です。
#     対応: 見出し (#〜######)、段落、箇条書き (- / * / 1.) とその入れ子、表、
#           コードブロック (```)、インラインのコード・太字 (**)・リンク・画像
#     非対応: 引用 (>)、斜体、脚注、HTML タグの直書き など
#   文書で新しい書式を使うときは、ここも直してください。
#
#   出力は外部ファイルに頼らない 1 ファイルの HTML です (画像も埋め込み)。
#   Edge などで file:// のまま開けます。
# ============================================================
$ErrorActionPreference = 'Stop'
$ToolDir = $PSScriptRoot
if (-not $ToolDir) { $ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = Split-Path -Parent $ToolDir
$Out  = Join-Path (Join-Path $Root 'app') 'manual.html'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 説明書に入れる順番: キー、MD のパス (リポジトリの一番上から)、目次での見出し
$Docs = @(
    @{ Key = 'readme';           Path = 'README.md';                Label = 'はじめに・使い方' },
    @{ Key = 'architecture';     Path = 'docs/architecture.md';     Label = '設計メモ' },
    @{ Key = 'functions';        Path = 'docs/functions.md';        Label = '関数表' },
    @{ Key = 'at-commands';      Path = 'docs/at-commands.md';      Label = 'AT コマンドの対応範囲' },
    @{ Key = 'at-command-table'; Path = 'docs/at-command-table.md'; Label = 'AT コマンド表' },
    @{ Key = 'deploy';           Path = 'docs/deploy-via-git.md';   Label = 'Git 経由で社内 PC に導入する' }
)
# MD のパス / ファイル名 → キー (MD どうしのリンクを、説明書の中の節へ付け替えるのに使う)
$FileKey = @{}
foreach ($d in $Docs) {
    $FileKey[$d.Path] = $d.Key
    $FileKey[[System.IO.Path]::GetFileName($d.Path)] = $d.Key
}

# 変換中の状態 (MatchEvaluator からも見えるように script スコープに置く)
$script:DocKey  = ''
$script:DocDir  = ''
$script:Codes   = $null
$script:Heads   = $null
$C1 = [string][char]1
$C2 = [string][char]2

# ---------------- 文字列の小道具 ----------------
function ConvertTo-HtmlText {
    param([string]$s)
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# GitHub と同じ考え方の見出し ID (小文字化、記号を除く、空白は -)。日本語は残す
function Get-Slug {
    param([string]$s)
    $t = [regex]::Replace($s.Trim().ToLowerInvariant(), '[^\w\- ]', '')
    return $t.Replace(' ', '-')
}

# 見出しの文字列から MD の記号を除いた素の文字列 (ID と目次に使う)
function Get-PlainText {
    param([string]$s)
    $t = $s.Replace('**', '').Replace('`', '')
    $t = [regex]::Replace($t, '!?\[([^\]]*)\]\([^)]*\)', '$1')
    return $t
}

function Get-Indent {
    param([string]$l)
    return ($l.Length - $l.TrimStart(' ').Length)
}

# ---------------- リンク・画像 ----------------
# MD のフォルダ (リポジトリの一番上なら $Root そのもの)
function Get-DocBase {
    if ($script:DocDir) { return (Join-Path $Root $script:DocDir) }
    return $Root
}

function Resolve-Link {
    param([string]$url)
    if ($url -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') { return $url }               # http: https: など
    if ($url.StartsWith('#')) {                                              # 同じ文書の中
        $frag = [System.Uri]::UnescapeDataString($url.Substring(1))
        return '#' + $script:DocKey + '-' + (Get-Slug $frag)
    }
    $file = $url; $frag = ''
    $p = $url.IndexOf('#')
    if ($p -ge 0) { $file = $url.Substring(0, $p); $frag = [System.Uri]::UnescapeDataString($url.Substring($p + 1)) }
    $file = [System.Uri]::UnescapeDataString($file)
    $full = [System.IO.Path]::GetFullPath((Join-Path (Get-DocBase) $file))
    $rel  = $full.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
    $k = $FileKey[$rel]
    if (-not $k) { $k = $FileKey[[System.IO.Path]::GetFileName($rel)] }
    if ($k) {                                                                # ほかの MD → 説明書の中の節
        if ($frag) { return '#' + $k + '-' + (Get-Slug $frag) }
        return '#doc-' + $k
    }
    return '../' + $rel                                                      # LICENSE など (app/ から見た相対パス)
}

function Get-ImageSrc {
    param([string]$src)
    $file = [System.Uri]::UnescapeDataString($src)
    $full = [System.IO.Path]::GetFullPath((Join-Path (Get-DocBase) $file))
    if (-not (Test-Path -LiteralPath $full)) { return $src }
    $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
    $mime = 'application/octet-stream'
    if ($ext -eq '.png') { $mime = 'image/png' }
    elseif ($ext -eq '.jpg' -or $ext -eq '.jpeg') { $mime = 'image/jpeg' }
    elseif ($ext -eq '.gif') { $mime = 'image/gif' }
    elseif ($ext -eq '.svg') { $mime = 'image/svg+xml' }
    return 'data:' + $mime + ';base64,' + [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($full))
}

# ---------------- インライン (行の中) ----------------
function ConvertFrom-Inline {
    param([string]$s)
    # 1. コード `...` を退避 (中身は書式として解釈しない)
    $script:Codes = New-Object System.Collections.Generic.List[string]
    $s = [regex]::Replace($s, '`([^`]+)`', [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $script:Codes.Add('<code>' + (ConvertTo-HtmlText $m.Groups[1].Value) + '</code>')
        return $C1 + ($script:Codes.Count - 1) + $C2
    })
    # 2. 残りを HTML 用に逃がす
    $s = ConvertTo-HtmlText $s
    # 3. 画像 ![alt](src)
    $s = [regex]::Replace($s, '!\[([^\]]*)\]\(([^)\s]+)\)', [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $src = Get-ImageSrc ([System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value))
        return '<img alt="' + $m.Groups[1].Value + '" src="' + (ConvertTo-HtmlText $src) + '">'
    })
    # 4. リンク [text](url)
    $s = [regex]::Replace($s, '\[([^\]]+)\]\(([^)\s]+)\)', [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $href = Resolve-Link ([System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value))
        return '<a href="' + (ConvertTo-HtmlText $href) + '">' + $m.Groups[1].Value + '</a>'
    })
    # 5. 太字 **...**
    $s = [regex]::Replace($s, '\*\*(.+?)\*\*', '<strong>$1</strong>')
    # 6. コードを戻す
    $s = [regex]::Replace($s, ([regex]::Escape($C1) + '(\d+)' + [regex]::Escape($C2)), [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        return $script:Codes[[int]$m.Groups[1].Value]
    })
    return $s
}

# ---------------- ブロック (段落・見出し・箇条書き・表・コード) ----------------
function Test-ListMarker {
    param([string]$l)
    return ($l -match '^([-*]|\d+\.) +\S')
}

function Test-TableStart {
    param([string[]]$lines, [int]$i)
    if ($i + 1 -ge $lines.Count) { return $false }
    return ($lines[$i].StartsWith('|') -and ($lines[$i + 1] -match '^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$'))
}

function Test-BlockStart {
    param([string[]]$lines, [int]$i)
    $l = $lines[$i]
    if ($l -match '^#{1,6} ') { return $true }
    if ($l.TrimStart().StartsWith('```')) { return $true }
    if (Test-ListMarker $l) { return $true }
    if (Test-TableStart $lines $i) { return $true }
    return $false
}

function Split-TableRow {
    param([string]$row)
    $r = $row.Trim()
    if ($r.StartsWith('|')) { $r = $r.Substring(1) }
    if ($r.EndsWith('|') -and -not $r.EndsWith('\|')) { $r = $r.Substring(0, $r.Length - 1) }
    $cells = [regex]::Split($r, '(?<!\\)\|')
    $outCells = @()
    foreach ($c in $cells) { $outCells += $c.Trim().Replace('\|', '|') }
    return ,$outCells
}

function ConvertFrom-Blocks {
    param([string[]]$lines, [bool]$Tight = $false)
    $sb = New-Object System.Text.StringBuilder
    $n = $lines.Count
    $i = 0
    while ($i -lt $n) {
        $l = $lines[$i]

        # 空行
        if ($l.Trim() -eq '') { $i++; continue }

        # コードブロック ```
        if ($l.TrimStart().StartsWith('```')) {
            $ind = Get-Indent $l
            $i++
            $code = New-Object System.Collections.Generic.List[string]
            while ($i -lt $n -and -not $lines[$i].TrimStart().StartsWith('```')) {
                $c = $lines[$i]
                if ((Get-Indent $c) -ge $ind) { $c = $c.Substring([Math]::Min($ind, $c.Length)) } else { $c = $c.TrimStart() }
                $code.Add($c)
                $i++
            }
            $i++   # 閉じの ```
            [void]$sb.Append('<pre><code>' + (ConvertTo-HtmlText ($code -join "`n")) + "</code></pre>`n")
            continue
        }

        # 見出し
        $m = [regex]::Match($l, '^(#{1,6}) +(.*?)\s*#*\s*$')
        if ($m.Success) {
            $lv = $m.Groups[1].Value.Length
            $text = $m.Groups[2].Value
            $plain = Get-PlainText $text
            $id = $script:DocKey + '-' + (Get-Slug $plain)
            $script:Heads.Add(@{ Level = $lv; Id = $id; Text = $plain })
            [void]$sb.Append('<h' + $lv + ' id="' + (ConvertTo-HtmlText $id) + '">' + (ConvertFrom-Inline $text) + '</h' + $lv + ">`n")
            $i++
            continue
        }

        # 表
        if (Test-TableStart $lines $i) {
            $head = Split-TableRow $l
            $i += 2
            [void]$sb.Append("<table>`n<thead><tr>")
            foreach ($c in $head) { [void]$sb.Append('<th>' + (ConvertFrom-Inline $c) + '</th>') }
            [void]$sb.Append("</tr></thead>`n<tbody>`n")
            while ($i -lt $n -and $lines[$i].TrimStart().StartsWith('|')) {
                [void]$sb.Append('<tr>')
                foreach ($c in (Split-TableRow $lines[$i])) { [void]$sb.Append('<td>' + (ConvertFrom-Inline $c) + '</td>') }
                [void]$sb.Append("</tr>`n")
                $i++
            }
            [void]$sb.Append("</tbody>`n</table>`n")
            continue
        }

        # 箇条書き (- / * / 1.)
        if (Test-ListMarker $l) {
            $ordered = ($l -match '^\d+\.')
            $tag = 'ul'
            $startAttr = ''
            if ($ordered) {
                $tag = 'ol'
                $first = [int]([regex]::Match($l, '^(\d+)').Groups[1].Value)
                if ($first -ne 1) { $startAttr = ' start="' + $first + '"' }
            }
            [void]$sb.Append('<' + $tag + $startAttr + ">`n")
            while ($i -lt $n) {
                $mk = [regex]::Match($lines[$i], '^([-*]|\d+\.)( +)(.*)$')
                if (-not $mk.Success) { break }
                if ((($mk.Groups[1].Value -match '^\d') -ne $ordered)) { break }     # 種類が変わったら別の箇条書き
                $col = $mk.Groups[1].Length + $mk.Groups[2].Length
                $item = New-Object System.Collections.Generic.List[string]
                $item.Add($mk.Groups[3].Value)
                $hasBlank = $false
                $i++
                while ($i -lt $n) {
                    $c = $lines[$i]
                    if ($c.Trim() -eq '') {
                        # 空行のあとが字下げされていれば、同じ項目の続き
                        $j = $i
                        while ($j -lt $n -and $lines[$j].Trim() -eq '') { $j++ }
                        if ($j -lt $n -and (Get-Indent $lines[$j]) -ge $col) {
                            $hasBlank = $true
                            while ($i -lt $j) { $item.Add(''); $i++ }
                            continue
                        }
                        break
                    }
                    $ind = Get-Indent $c
                    if ($ind -ge $col) { $item.Add($c.Substring($col)); $i++; continue }
                    if ($ind -eq 0 -and (Test-BlockStart $lines $i)) { break }
                    if ($ind -gt 0) { $item.Add($c.TrimStart()); $i++; continue }
                    # 字下げなしの行: 段落の続き (怠惰な継続行)
                    if ($item[$item.Count - 1].Trim() -ne '') { $item.Add($c); $i++; continue }
                    break
                }
                $inner = ConvertFrom-Blocks -lines ($item.ToArray()) -Tight (-not $hasBlank)
                [void]$sb.Append('<li>' + $inner.TrimEnd() + "</li>`n")
                # 空行をはさんで同じ種類の項目が続くなら、同じ箇条書き
                $j = $i
                while ($j -lt $n -and $lines[$j].Trim() -eq '') { $j++ }
                if ($j -gt $i -and $j -lt $n -and (Test-ListMarker $lines[$j]) -and (($lines[$j] -match '^\d+\.') -eq $ordered)) { $i = $j }
            }
            [void]$sb.Append('</' + $tag + ">`n")
            continue
        }

        # 段落
        $para = New-Object System.Collections.Generic.List[string]
        $para.Add($l.Trim())
        $i++
        while ($i -lt $n -and $lines[$i].Trim() -ne '' -and -not (Test-BlockStart $lines $i)) {
            $para.Add($lines[$i].Trim())
            $i++
        }
        $html = ConvertFrom-Inline ($para -join "`n")
        if ($Tight) { [void]$sb.Append($html + "`n") } else { [void]$sb.Append('<p>' + $html + "</p>`n") }
    }
    return $sb.ToString()
}

function ConvertFrom-MdFile {
    param([hashtable]$Doc)
    $script:DocKey = $Doc.Key
    $script:DocDir = [System.IO.Path]::GetDirectoryName($Doc.Path)
    $script:Heads  = New-Object System.Collections.Generic.List[object]
    $text = [System.IO.File]::ReadAllText((Join-Path $Root $Doc.Path), [System.Text.Encoding]::UTF8)
    $text = $text.TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
    return ConvertFrom-Blocks -lines ($text -split "`n")
}

# ---------------- 組み立て ----------------
$Css = @'
:root { --fg:#1f2328; --sub:#59636e; --line:#d1d9e0; --bg:#ffffff; --code:#f6f8fa; --accent:#0969da; --head:#0b1120; }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
       font-family:"Yu Gothic UI","Meiryo UI","Meiryo",sans-serif; font-size:15px; line-height:1.75; }
header.top { background:var(--head); color:#f8fafc; padding:18px 24px; }
header.top h1 { margin:0; font-size:1.4rem; color:#38bdf8; }
header.top p { margin:4px 0 0; font-size:.85rem; color:#94a3b8; }
main { max-width:980px; margin:0 auto; padding:16px 24px 64px; }
nav.toc { border:1px solid var(--line); border-radius:8px; padding:12px 20px; margin:16px 0 32px; background:#fbfcfd; }
nav.toc h2 { margin:0 0 6px; font-size:1.05rem; border:0; }
nav.toc ol { margin:0; padding-left:1.4em; }
nav.toc ol ol { padding-left:1.2em; font-size:.92rem; }
nav.toc a { text-decoration:none; }
section.doc { border-top:3px solid var(--head); padding-top:8px; margin-top:48px; }
h1,h2,h3,h4 { line-height:1.4; scroll-margin-top:12px; }
h1 { font-size:1.6rem; }
h2 { font-size:1.3rem; border-bottom:1px solid var(--line); padding-bottom:4px; margin-top:2em; }
h3 { font-size:1.12rem; margin-top:1.6em; }
a { color:var(--accent); }
code { font-family:Consolas,"BIZ UDGothic","MS Gothic",monospace; font-size:.9em; background:var(--code); padding:.1em .35em; border-radius:4px; }
pre { background:var(--code); border:1px solid var(--line); border-radius:6px; padding:12px 14px; overflow-x:auto; line-height:1.5; }
pre code { background:none; padding:0; font-size:.88em; }
table { border-collapse:collapse; margin:12px 0; display:block; overflow-x:auto; max-width:100%; }
th, td { border:1px solid var(--line); padding:6px 10px; vertical-align:top; }
th { background:#f0f3f6; text-align:left; white-space:nowrap; }
img { max-width:100%; border:1px solid var(--line); border-radius:6px; }
.back { display:inline-block; margin-top:8px; font-size:.85rem; }
@media print {
  header.top { background:none; color:#000; border-bottom:2px solid #000; }
  header.top h1 { color:#000; }
  nav.toc { break-after:page; }
  section.doc { break-before:page; border-top:0; margin-top:0; }
  .back { display:none; }
  a { color:inherit; text-decoration:none; }
  pre, table, img { break-inside:avoid; }
}
'@

$toc = New-Object System.Text.StringBuilder
$sections = New-Object System.Text.StringBuilder
foreach ($d in $Docs) {
    $src = Join-Path $Root $d.Path
    if (-not (Test-Path -LiteralPath $src)) { Write-Host ('見つかりません: ' + $d.Path) -ForegroundColor Yellow; continue }
    $body = ConvertFrom-MdFile $d
    $sub = New-Object System.Text.StringBuilder
    foreach ($h in $script:Heads) {
        if ($h.Level -eq 2) { [void]$sub.Append('<li><a href="#' + (ConvertTo-HtmlText $h.Id) + '">' + (ConvertTo-HtmlText $h.Text) + '</a></li>') }
    }
    [void]$toc.Append('<li><a href="#doc-' + $d.Key + '">' + (ConvertTo-HtmlText $d.Label) + '</a>')
    if ($sub.Length -gt 0) { [void]$toc.Append('<ol>' + $sub.ToString() + '</ol>') }
    [void]$toc.Append("</li>`n")
    [void]$sections.Append('<section class="doc" id="doc-' + $d.Key + "`">`n")
    [void]$sections.Append('<p class="back"><a href="#toc">▲ 目次へ</a>　(元原稿: ' + (ConvertTo-HtmlText $d.Path) + ")</p>`n")
    [void]$sections.Append($body)
    [void]$sections.Append("</section>`n")
}

$today = (Get-Date).ToString('yyyy-MM-dd')
$page = @"
<!DOCTYPE html>
<!-- CsqWatch 説明書 (tools/Build-Manual.ps1 で生成。直接編集せず、元の MD を直して作り直すこと)   Author: yuichi -->
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CsqWatch 説明書</title>
<style>
$Css
</style>
</head>
<body>
<header class="top">
  <h1>CsqWatch 説明書</h1>
  <p>Author: yuichi ／ 作成 $today ／ README と docs の MD から生成(Ctrl+F で検索できます)</p>
</header>
<main>
<nav class="toc" id="toc">
<h2>目次</h2>
<ol>
$($toc.ToString())</ol>
</nav>
$($sections.ToString())</main>
</body>
</html>
"@

$page = $page.Replace("`r`n", "`n").Replace("`n", "`r`n")
[System.IO.File]::WriteAllText($Out, $page, (New-Object System.Text.UTF8Encoding($false)))
$kb = [int]((Get-Item -LiteralPath $Out).Length / 1024)
Write-Host ('作成しました: app\manual.html  (' + $kb + ' KB)')
