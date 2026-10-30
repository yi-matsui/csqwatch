# 関数表

Author: yuichi(作成 2026-10-21)

CsqWatch のスクリプトと画面に含まれる関数の一覧です。設計の考え方は [architecture.md](architecture.md) を参照してください。

## ファイルの関係

```
Monitor.bat ──► Monitor.ps1 ──┬─ . Config.ps1      (設定)
                              ├─ . Common.ps1      (Invoke-At → AtIo.exe)
                              └─ . Browser.ps1     (Open-Dashboard → ブラウザ)
Probe.bat   ──► Probe.ps1   ──┬─ . Config.ps1
                              └─ . Common.ps1
Merge.bat   ──► Merge.ps1   ──── . Config.ps1      ($LogDir だけ使う)
index.html  ──► data.js・trend.js (Monitor.ps1 が書き出す)
build.bat   ──► AtIo.cs → AtIo.exe
tools\build_manual.bat ──► Build-Manual.ps1 ──► README.md + docs\*.md → app\manual.html
```

`. ファイル名` は PowerShell のドットソース(同じスコープに読み込む)です。

## Monitor.ps1(収集の本体)

| 関数 | 引数 | 戻り値 | 役割 | 呼び出し元 |
|---|---|---|---|---|
| `Write-TestLog` | `Level`(区分)、`Msg`(内容) | なし | 試験ログ `logs\test_YYYYMMDD.log` に 1 行追記する。日時はミリ秒まで。内容の改行は ` \| ` に置き換える。書き込みの失敗は無視する(監視を止めない) | ほぼすべて |
| `Show-Dashboard` | なし | なし | `Open-Dashboard` を呼び、結果を試験ログに書く。開けなければコンソールに案内を出す | 起動時、二重起動時 |
| `Test-InnerException` | `Ex`(例外)、`Type`(型) | 真偽値 | 例外とその内側の例外をたどり、指定の型が含まれるかを調べる。Mutex の放棄(`AbandonedMutexException`)の判定に使う | 二重起動の確認 |
| `Format-Response` | `Res`(応答) | 文字列 | ログ用に応答を整える。PowerShell 5.1 の「発生場所 …」などの飾りと `AtIo.exe : ` の前置きを除く。AT の応答(`+CSQ:` など)は残す。空なら `(空応答)` | `Invoke-AtLog`、`Invoke-Poll` |
| `Invoke-AtLog` | `Cmd`、`Wait`(秒)、`After`(後続コマンド)、`During`(通話中のコマンド)、`DuringEvery`(秒)。後ろ 3 つは省略可 | 応答(整形前) | `Invoke-At` を包み、送信(`CMD`)・応答と所要時間(`RSP`)を試験ログに残す。`AtIo.exe` が残っていれば `WARN` | `Invoke-Poll`、`Invoke-TestCall` |
| `Get-CsvPath` | `d`(日時) | パス | その月の CSV のパス `logs\csq_YYYYMM.csv` を返す | `Add-CsvLine`、`Import-History` |
| `Add-CsvLine` | `d`(日時)、`line`(1 行) | なし | CSV に 1 行追記する。ファイルがなければ見出し付きで作る。失敗したら(Excel で開いている場合など)警告を出し、試験ログに `ERR` | `Invoke-Poll`、`Invoke-TestCall` |
| `Import-History` | なし | なし | 起動時に、先月と今月の CSV から `$HistoryHours` 時間以内の行を読んでグラフの履歴を復元する。新しい CSV がなければ旧名 `isat_YYYYMM.csv` を読む。3 列目が `N/A`・`取得失敗` の行は取得失敗として扱う | 起動時 |
| `Write-Data` | なし | なし | 画面用の `data.js` を書き出す(一時ファイルに書いてから置き換え)。履歴は、取得失敗を `null`、端末の圏外(99)を `0` にする。発信試験のタイムテーブル・取り込みの状態・今日の結果も入れる | 起動時、`Invoke-Poll`、`Invoke-TestCall`、`Receive-CallTable` |
| `Invoke-Poll` | なし | なし | 1 回分の取得。COM ポート一覧の確認 → `AT+CSQ` → `AT+CREG?` → `$Extras` の順に送り、解析して CSV・試験ログ・`data.js` に反映し、コンソールに 1 行表示する | メインループ |

### Monitor.ps1 の発信試験の関数

| 関数 | 引数 | 戻り値 | 役割 | 呼び出し元 |
|---|---|---|---|---|
| `Get-CallInbox` | なし | パス | 画面で保存したタイムテーブルを探すフォルダ。`$CallTableInbox`、なければダウンロードフォルダ(`shell:Downloads`)、それも取れなければ `%USERPROFILE%\Downloads` | 起動時 |
| `New-DefaultCallTable` | なし | タイムテーブル | 初期のタイムテーブル(各時 01 分・番号 `$TestNumber`・すべて OFF)。旧版の `$CallTimes` の時刻の行は ON にして有効にする | `Import-CallTable` |
| `ConvertTo-CallTable` | `Obj`(JSON から読んだもの) | タイムテーブル | 24 行・時刻の形式・ON の行の時刻の重なり・番号の形式・通話時間・回数・間隔・ON の時刻どうしの間隔(1 つの試験の長さ以上)・`$CallNumberAllow` を確かめて、決まった形にする。おかしければ理由つきの例外 | `Import-CallTable`、`Receive-CallTable` |
| `Save-CallTable` | なし | なし | 今のタイムテーブルを `CallTable.json` に書く | `Import-CallTable`、`Receive-CallTable` |
| `Get-CallSeqSec` | `Dur`、`Repeat`、`IntervalMin` | 秒 | 1 つの時刻の試験(連続発信)にかかる秒数のめやす(回数 × (通話時間 + 30) + (回数 − 1) × 間隔) | `ConvertTo-CallTable` |
| `Get-CallTableSummary` | なし | 文字列 | 試験ログ用の要約(有効・ON の数・通話時間・回数・間隔・時刻) | 各所 |
| `Import-CallTable` | なし | なし | 起動時に `CallTable.json` を読む。なければ初期のものを作る。壊れていれば上書きせず、発信試験を止めておく | 起動時 |
| `Receive-CallTable` | なし | なし | 受け取り先と `app\` から `csqwatch_calltable*.json` を探し、最も新しいものを確かめて取り込む。取り込んだファイルは `logs\calltable_history\` へ移す | メインループ(5 秒ごと) |
| `Get-CsqValue` | `Res`(応答) | `@{ r; b }` または `$null` | 応答から最初の `+CSQ: <rssi>,<ber>` を取り出す | `Invoke-TestCall`、`Get-CallJudgement` |
| `Get-CallJudgement` | `Res`(発信の応答) | `@{ result; code; samples; stage; cause; causeText; gps; ciev; notify }` | 区切り行(`--- during` / `--- after`)で応答を分け、`ATH` より前の部分から、`ATD` の応答・独自通知(`+SKCPI` の段階、`+SKCCSI` の切断と理由、`+SKGPSPOSI`、`+CIEV: 2`)を読んで成否を決める。通話中の `AT+CSQ` の値は、切断の通知より前のものだけを取り出す。段階の名前は `$CallStageName`、理由番号の意味は `$Q850Text` | `Invoke-TestCall` |
| `Get-CallCsvPath` | `d`(日時) | パス | その月の発信試験の CSV `logs\call_YYYYMM.csv` | `Add-CallCsvLine`、`Import-CallResults` |
| `Add-CallCsvLine` | `d`、`line` | なし | 発信試験の CSV に 1 行追記する(なければ見出し付きで作る。列を足す前の見出しなら、見出しの行だけ置き換える) | `Invoke-TestCall` |
| `Get-Cell` | `v` | 文字列 | 値がなければ空欄、あればそのままの文字列(CSV と画面で共通) | `Invoke-TestCall` |
| `Import-CallResults` | なし | なし | 起動時に、今日の発信試験の結果を CSV から読み戻す | 起動時 |
| `Invoke-TestCall` | `Slot`(タイムテーブルの行)、`now`(日時)、`Try`、`Total`(何回目か) | なし | 発信試験 1 回分。直前の `AT+CSQ` → `ATD<番号>;`(通話中も `AT+CSQ`)→ `ATH` → 直後の `AT+CSQ`。判定して、発信試験の CSV・取得結果の CSV(印)・試験ログ・`data.js` に反映する | メインループ |

### Monitor.ps1 の評価トレンドとコメントの関数

| 関数 | 引数 | 戻り値 | 役割 | 呼び出し元 |
|---|---|---|---|---|
| `Get-TrendMonths` | `From`、`To` | 月の一覧 | 期間にかかる月を並べる(月をまたいで CSV を読むため) | `Read-TrendLines` |
| `Read-TrendLines` | `Prefix`、`From`、`To`、`OldPrefix` | 行の並び | 期間内の CSV の行を集める(`csq_` / `call_`。受信ログは旧名 `isat_` も読む) | `Write-Trend` |
| `ConvertTo-EventTime` | `s`(日時の文字列) | `yyyy-MM-dd HH:mm` か `$null` | コメントの日時をそろえる(`/` 区切り・1 桁の時分・全角数字・秒つきも読む) | `ConvertFrom-EventLine`、`Receive-Events` |
| `ConvertFrom-EventLine` | `l`(events.csv の 1 行) | `{ t, text, id }` か `$null` | events.csv の 1 行を読む(見出しや読めない行は `$null`) | `Read-Events`、`Receive-Events` |
| `Read-Events` | `From` | コメントの並び | `logs\events.csv` から期間内のコメントを日時の順に読む | `Write-Trend` |
| `Watch-EventsCsv` | なし | なし | `events.csv` の更新日時を見て、メモ帳などで直されたらすぐ `Write-Trend` を呼ぶ | メインループ(5 秒ごと) |
| `Write-Trend` | なし | なし | `$TrendDays` 日分の受信ログを 15 分ごとにまとめ(平均・最小・最大・BER の最大・取得失敗・圏外)、発信試験の結果とコメントを添えて `trend.js` に書き出す | 起動時、メインループ(10 分ごと)、発信試験のあと、`Receive-Events` |
| `Receive-Events` | なし | なし | 受け取り先と `app\` から `csqwatch_event*.json` を探し、確かめて `events.csv` に書く。`old`(元の日時と内容)があればその行を置き換え、`del` があれば消す。取り込んだファイルは `logs\calltable_history\` へ移す | メインループ(5 秒ごと) |

### Merge.ps1(過去のデータのまとめ)

| 関数 | 引数 | 戻り値 | 役割 |
|---|---|---|---|
| `Read-DataLines` | `Path` | 行の配列 | CSV の中から、数字で始まるデータの行だけを読む(見出し・BOM を除く) |
| `Format-CallLine` | `l` | 行 | 列の足りない旧版の発信試験の行に空の列を足し、今の列の数にそろえる |
| `Format-EventLine` | `l` | 行か `$null` | コメントの日時を `yyyy-MM-dd HH:mm` にそろえる |
| `Get-Key` | `Kind`、`l` | 文字列 | 並べ替えと重複判定の鍵(受信ログ・発信試験は日時 19 文字、コメントは日時 + 内容) |
| `Add-Plan` | `Target`、`Kind`、`Header`、`Lines`、`From` | なし | まとめる先のファイルごとに、元の行を集める |

関数以外の流れ:保存先を決める(`Config.ps1` の `$LogDir`)→ Monitor が動いていれば止まる → 元のフォルダを選ぶ → ファイルを探して行を月ごとに振り分ける → 保存先と合わせて件数を出す → `Y` で、書き換える前のファイルを `merge_backup\` に残してから書く → `merge_report_日時.txt`。

### Monitor.ps1 の関数以外の処理(上から順に)

| 処理 | 内容 |
|---|---|
| 設定の読み込み | `Config.ps1` がなければ `Config.sample.ps1` からコピー。`Config.ps1`・`Common.ps1` を読み込む。`$RssiMax`・`$DeviceName`・`$AtIoExe`・`$HistoryHours` が未設定なら既定値を入れる。グラフの点の数(`$HistoryMax`)を `$HistoryHours` と取得周期から決める |
| `trap` | 予期しないエラーで止まる直前に `ERR UNHANDLED`(行番号付き)を試験ログに残す |
| 二重起動の確認 | Mutex `Global\CsqWatch` を取る。取れなければ監視画面を前面に出し、5 秒後に終了コード `3` で終わる |
| 起動の準備 | `monitor_running.txt` を書く。窓のタイトルを「CsqWatch 稼働中」にする。CPU 優先度を「通常以下」にする |
| 起動記録 | `START`(PID・PowerShell の版・PC の起動時刻)と設定値を試験ログに残す |
| 起動時の読み込み | 取得結果の履歴(`Import-History`)、受け取り先(`Get-CallInbox`)、タイムテーブル(`Import-CallTable`)、今日の発信試験の結果(`Import-CallResults`) |
| メインループ | 1 秒ごとに時刻を確認する。5 秒ごとにタイムテーブルの取り込みを確かめ(`Receive-CallTable`)、発信試験が有効で ON の行の時刻なら試験を始め(同じ分には 1 度だけ。`$script:CallSeq` に回数・次の時刻を持つ)、次の時刻が来るたびに 1 回ずつ発信する(発信のあいだは取得を続ける)。周期ごとに取得する。周期が 10 秒を超えて遅れたら `WARN`(スリープの兆候) |
| `finally` | 止めたとき(Ctrl+C を含む)に `STOP` を残し、`monitor_running.txt` を消し、Mutex を解放する |

## Common.ps1(AT コマンド送信の共通部)

| 関数 | 引数 | 戻り値 | 役割 | 呼び出し元 |
|---|---|---|---|---|
| `Invoke-At` | `Cmd`、`Wait`(秒、既定 3)、`After`・`During`・`DuringEvery`(省略可。`During` は `After` があるときだけ渡す) | 応答の文字列 | `AtIo.exe <Port> <Baud> <Cmd> <Wait> [After] [During] [DuringEvery]` を呼び、標準出力と標準エラー出力をまとめて返す。`-Mock` のときは `Get-MockResponse` を返す。呼び出しに失敗したら `IO Error: …` を返す | `Invoke-AtLog`、`Probe.ps1` |
| `Get-MockResponse` | `Cmd`、`Wait`、`After`、`During`、`DuringEvery` | 応答の文字列 | `-Mock` 用の疑似応答。`ATD` には `AtIo.exe` と同じ区切り行と、IsatPhone 2 の独自通知を実機の記録に似せて返す(7 割成功。1 割は途中で GPS 状態が 0 になり網から理由 31 で切断、`ATD` は `OK`。残りは呼出中の `NO CARRIER`・`BUSY`・`+CME ERROR`。通話中は rssi が 3〜10 下がる)。`AT+CSQ` は rssi 20〜50(IsatPhone 2 の実測付近)でゆらぐ値、`AT+CREG?` は rssi が 25 未満なら探索中。ほかに `AT+COPS?`・`AT+CBC`(実機の IsatPhone 2 では使用禁止)・`AT`・`ATH`。それ以外は `ERROR` | `Invoke-At` |

## Browser.ps1(監視画面を開く)

| 関数 | 引数 | 戻り値 | 役割 | 呼び出し元 |
|---|---|---|---|---|
| `Find-BrowserExe` | `Name`(`chrome` / `edge` / `firefox`) | パス、なければ `$null` | レジストリの App Paths と標準のインストール先から、ブラウザの実行ファイルを探す | `Open-Dashboard` |
| `Initialize-FirefoxProfile` | `Prof`(プロファイルのフォルダ) | なし | Firefox の専用プロファイルを作り、初回の案内などを出さない設定(`user.js`)を書く | `Open-Dashboard` |
| `Find-DashboardProcess` | `Exe`、`Prof` | プロセス ID、なければ `$null` | 専用プロファイルで動いているブラウザの本体プロセスを探す(コマンドラインにプロファイルのパスを含み、子プロセスではないもの)。社外監視のブラウザは対象にならない | `Open-Dashboard` |
| `Open-Dashboard` | `Dir`、`Browser`(既定 `auto`)、`Size`、`Pos` | `OK …` または `NG …` | ブラウザを選び、すでに開いていればそのプロセスの窓を前面に出す(`AppActivate`)。なければ専用プロファイル・アプリモードで `index.html` を開く | `Show-Dashboard` |

## Probe.ps1(対応コマンドの調査)

関数はありません。上から順に次の処理を行います。

| 処理 | 内容 |
|---|---|
| 準備 | `Config.ps1`・`Common.ps1` を読み込み、`probe_commands.txt`(または `-ListFile`)から `#` で始まらない行を読む |
| 送信と判定 | 1 コマンドずつ `Invoke-At`(待ち 5 秒)で送り、`NO RESPONSE` / `IO ERROR` / `OK` / `ERROR` / `OTHER` に分ける |
| 保存 | 生の応答と一覧を `probe_YYYYMMDD_HHMMSS.txt`(UTF-8 BOM 付き)に保存する |

## AtIo.cs(シリアル I/O、C#)

| メソッド・定義 | 役割 |
|---|---|
| `Main(string[] args)` | 引数を読み、COM ポートを 8N1・DTR/RTS ON で開く。`ATE0V1` を送って応答を捨て、コマンドを送り、受信した応答をそのまま標準出力へ出す。`DuringCmd` があれば、`Cmd` の終端行を受けてから一定間隔で送り、区切り行(`--- during` / `--- after`)を出す。終了コード `0` 正常 / `1` 引数不足 / `2` I/O エラー |
| `IsHelp(string a)` | `-HELP` / `--HELP` / `-H` / `-?` / `/?` / `/HELP` かどうか(大文字小文字は区別しない) |
| `Final`(正規表現) | 応答の終端行(`OK` / `ERROR` / `NO CARRIER` / `BUSY` / `NO ANSWER` / `NO DIALTONE` / `+CME ERROR:` / `+CMS ERROR:`)を、受信済みの全文から探す |
| `CallEnd`(正規表現) | 通話が終わったことを示す行(`NO CARRIER` / `BUSY` / `NO ANSWER` / `NO DIALTONE`)。`DuringCmd` ありのとき、これを受けたら待ちを打ち切る |
| `HelpText`(定数) | `-HELP` で表示する使い方 |

## index.html(画面、JavaScript)

| 関数 | 役割 |
|---|---|
| `$(id)` | `document.getElementById` の短縮 |
| `setBadge(text, cls)` | 右上の状態表示(`LIVE` / `STALE` / `NO DATA` など)を変える |
| `initChart()` | グラフ(Chart.js)を作り、`loadData` を 3 秒ごとに呼ぶように設定する。横軸のラベルは「時刻」と「月/日」の 2 段。スクロールと「最新へ」ボタンの処理も割り当てる |
| `stickyYAxis`(Chart.js のプラグイン) | 描画のたびにグラフの左端(縦軸の目盛り)を `chartYAxis` の canvas に写し、横スクロールしても目盛りが左に残るようにする |
| `isAtEnd()` | 受信グラフが右端(最新)を表示しているか |
| `md(s)` / `hm(s)` | 日時の文字列から「月/日」・「時:分」を取り出す(横軸のラベル用) |
| `loadData()` | `<script src="data.js?t=…">` を差し替えて読み込み、読めたら `render` を呼ぶ。読めなければ `NO DATA` |
| `render(d)` | `window.CSQ_DATA` からカード・見出し(機器名)・グラフ・発信試験の欄を更新する。取得失敗は `--` と赤の `取得失敗`、端末の 99 は `圏外 (99)`。グラフの縦軸は `rssiMax` に合わせる。最終更新が周期の 2 倍 + 10 秒より古ければ `STALE` |
| `renderCall(c)` | 発信試験の欄を描く。有効/停止・ON の数・今日の成功数、取り込みの状態(「反映済み」・取り込めなかった理由)、24 行の表(今日の結果・応答と切断理由と到達段階・GPS・表示器の最小・rssi と BER の直前/通話中/直後・差) |
| `openEditor()` / `closeEditor()` | タイムテーブルの編集欄を開く・閉じる(表示側の表と切り替える) |
| `editorRows()` | 編集欄の 24 行の入力欄(ON・時刻・番号)をまとめて返す |
| `saveEditor()` | 編集欄の内容を確かめ(Monitor と同じ確認)、確認の画面を出してから `csqwatch_calltable.json` をダウンロードとして保存する。保存した `savedAt` を覚えて、取り込まれたかを見る |
| `initCall()` | 発信試験の欄のボタンに処理を割り当てる |
| `eventLines`(Chart.js のプラグイン) | グラフを描いたあとに、変化のコメントを黄色の縦線とラベルで重ねる(`chart.$events`)。受信グラフと評価トレンドの両方で使う |
| `setLiveEvents()` | 受信グラフの各点の時刻と照らして、コメントの縦線の位置を決める |
| `initTrend()` | 評価トレンドのグラフを作り、期間の切り替え・コメントの追加のボタンを割り当て、`loadTrend` を 1 分ごとに呼ぶ |
| `loadTrend()` | `<script src="trend.js?t=…">` を差し替えて読み込み、`renderTrend` を呼ぶ |
| `renderTrend(d)` | 選んだ期間を切り出し、CSQ の平均・最小〜最大の帯・BER の最大・発信試験の点・コメントの縦線を描く。期間の要約、時間帯別の成功率、コメントの一覧も出す |
| `openEvent(e)` | コメントの入力欄を開く。`e` が空なら追加(日時は空。「今」ボタンで今の時刻)、一覧の行なら直す・消す |
| `normTime(s)` | 入力された日時を `YYYY-MM-DD HH:MM` にそろえる(`/` 区切り・1 桁の時分・全角数字も可)。読めなければ空 |
| `saveEvent(del)` | コメントを確かめ(未来の日時は不可)、`csqwatch_event.json`(`t`・`text`・`id`、直すときは `old`、消すときは `del`)をダウンロードとして保存する。取り込まれたかを `trend.js` で確かめる |
| `toMin(s)` | 日時の文字列を分に直す(位置の計算用) |
| `esc` / `pad2` / `nowText` / `hhmm` / `setCallMsg` | 文字の置き換え・ゼロ埋め・現在日時・時刻だけ取り出す・欄の上のメッセージ |

`index.html` の右上の「説明書」は `manual.html` へのリンクです(別の窓で開く)。

## tools/Build-Manual.ps1(説明書の生成)

README と `docs/*.md` を 1 冊の `app/manual.html` にします。PowerShell 5.1 だけで動き、`tools\build_manual.bat` から起動します。MD の変換は、この文書で使っている書式だけに対応した簡易版です。

| 関数 | 引数 | 戻り値 | 役割 |
|---|---|---|---|
| `ConvertTo-HtmlText` | `s` | 文字列 | `&` `<` `>` `"` を HTML 用に置き換える |
| `Get-Slug` | `s` | 文字列 | 見出しから ID を作る(GitHub と同じ考え方。小文字化、記号を除く、空白は `-`。日本語は残す) |
| `Get-PlainText` | `s` | 文字列 | 見出しから MD の記号(太字の `**`、コードのバッククォート、リンク)を除く。ID と目次に使う |
| `Get-Indent` | `l`(1 行) | 数値 | 行頭の空白の数 |
| `Get-DocBase` | なし | パス | 変換中の MD があるフォルダ |
| `Resolve-Link` | `url` | URL | MD どうしのリンクを説明書の中の節(`#キー-見出しID`)に付け替える。`LICENSE` などは `app/` から見た相対パスにする |
| `Get-ImageSrc` | `src` | 文字列 | 画像を読み、`data:` 形式で HTML に埋め込む |
| `ConvertFrom-Inline` | `s` | HTML | 行の中の書式を変換する。コード(バッククォートで囲んだ部分)を先に退避してから、画像・リンク・太字の順に変換する |
| `Test-ListMarker` | `l` | 真偽値 | 箇条書きの行(`-` / `*` / `1.`)か |
| `Test-TableStart` | `lines`、`i` | 真偽値 | 表の始まり(見出し行と `---` の区切り行)か |
| `Test-BlockStart` | `lines`、`i` | 真偽値 | 見出し・コード・箇条書き・表の始まりか(段落の終わりの判定に使う) |
| `Split-TableRow` | `row` | 配列 | 表の 1 行をセルに分ける(前に `\` が付いた縦棒は、セルの区切りにしない) |
| `ConvertFrom-Blocks` | `lines`、`Tight` | HTML | 行の並びを、段落・見出し・表・コードブロック・箇条書きに分けて変換する。箇条書きの項目の中身は、字下げを外してから自分自身を呼んで変換する(入れ子に対応) |
| `ConvertFrom-MdFile` | `Doc` | HTML | MD を 1 本読み、変換する |

最後に、決まった順番で文書をつなぎ、目次と CSS を付けて `app/manual.html`(UTF-8・CRLF)に書き出します。

## バッチファイル

| ファイル | 内容 |
|---|---|
| `Monitor.bat` | `Monitor.ps1` を起動する(引数はそのまま渡す)。終了コード `3`(すでに動いている)のときは `pause` せずに閉じる |
| `MonitorMock.bat` | `Monitor.ps1 -Mock` を起動する。終了コード `3` の扱いは `Monitor.bat` と同じ |
| `Probe.bat` | `Probe.ps1` を起動する(引数はそのまま渡す) |
| `Merge.bat` | `Merge.ps1` を起動する(引数はそのまま渡す) |
| `build.bat` | Windows 標準の `csc.exe`(64bit を優先)で `AtIo.cs` から `AtIo.exe` を作る |
| `tools\build_manual.bat` | `Build-Manual.ps1` を起動して説明書 `app\manual.html` を作る |
