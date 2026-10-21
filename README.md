# **CsqWatch**

Author: yuichi(Yuichi Matsui, JH0VEQ)

## AT コマンドで話せる通信機器の受信状態(`AT+CSQ`)を監視する小さなツールです。
Windows 11 に最初から入っているものだけで動き、インターネットにつながらない環境で使います。

使っているのは 3GPP TS 27.007 の標準 AT コマンド(`AT+CSQ`・`AT+CREG?`・`ATD`/`ATH`)だけなので、衛星電話・携帯電話モジュールなど、AT コマンドで話せる機器ならおおむね動きます。機器ごとの違い(信号の目盛りの最大値など)は設定で合わせます。

**動作確認済みの機器**: Inmarsat IsatPhone 2(2026-10-14、実機で確認)。機器ごとの注意は「[機器ごとの注意](#機器ごとの注意)」を参照してください。

C# で書いているのは「AT コマンドを 1 つ送って応答を返す」`AtIo.exe` だけです。
どのコマンドを送り、結果をどう解釈し、どう表示するかは、PowerShell・設定ファイル・HTML 側にあります。
C# を書ける人がいなくても保守できる構成です。

## 評価版のイメージ

* まずは基本動作を確認するための最小機能を目指す。

![dashboard](docs/dashboard.png)

## 将来の構想

* 最小動作ができた時点で本格的な表示に作り直す。

![FutureDashboard](docs/FutureDashboard.png)

## 特長

- **Web サーバ不要** — `index.html` をダブルクリックで開くだけ。収集側が `data.js` を書き出し、画面がそれを読みます
- **AT コマンドは外出し** — 追加したい項目は設定ファイルに 1 行足すだけ
- **実機なしで試せる** — 疑似データの `-Mock` モード
- **対応コマンドの調査ツール** — `Probe.bat` が機器の対応状況を一覧にします
- **止まったことに気づける** — 更新が止まると、画面右上が **STALE**(赤)になります
- **完全オフライン** — Chart.js を同梱しています
- **社外監視の窓を邪魔しない** — 画面は社外監視 (VPN) とは別のブラウザ・別のプロセスで開き、Monitor 自身も CPU 優先度「通常以下」で動きます
- **入口は `Monitor.bat` ひとつ** — 監視が止まっていれば始め、動いていれば監視画面を前面に出すだけ。何度押しても、監視が二重に動くことも、画面の窓が増えることもありません
- **試験ログ** — 送ったコマンド・生の応答・所要時間・解析結果などを 1 行ずつ記録し、不具合解析とデータ取得の検証に使えます

## 仕組み

```
[AT コマンド機器] ──COM── AtIo.exe ◀── Monitor.ps1 ──┬─▶ data.js        ◀── index.html (別ブラウザの専用窓)
                          (I/O だけ)   (収集ループ)    ├─▶ logs/csq_YYYYMM.csv     (取得結果)
                                                       └─▶ logs/test_YYYYMMDD.log   (試験ログ)
```

`AtIo.exe` は AT コマンド 1 回ごとに起動し、COM ポートを「開く → 送受信 → 閉じる」で終わります。COM ポートを開きっぱなしにはしません。

設計の詳細は [docs/architecture.md](docs/architecture.md)、関数ごとの役割は [docs/functions.md](docs/functions.md)、AT コマンドの対応範囲と調べ方は [docs/at-commands.md](docs/at-commands.md) を参照してください。

## 動作環境

Windows 11(Windows PowerShell 5.1 と .NET Framework 4.x が標準で入っています)。追加のインストールは不要です。

## 運用する人へ(これだけ覚えてください)

- **監視画面が見当たらない・閉じてしまった → `Monitor.bat` をダブルクリック**
  - 監視が動いていれば、画面が前面に出る(閉じていれば開く)だけです。黒い窓は 5 秒で自動的に閉じます。
  - 監視が止まっていれば、監視を始めて画面を開きます。
- 画面右上が **STALE**(赤)のときは、監視が止まっています。同じく `Monitor.bat` を押します。
- 「CsqWatch 稼働中 (閉じないでください)」という黒い窓は閉じないでください。
- 社外監視(VPN)の窓が最優先です。監視画面はそれとは別のブラウザで開きます。
- 説明書は、監視画面の右上の **「説明書」** から開けます(`app\manual.html` をダブルクリックしても開けます)。

## クイックスタート

`app/` フォルダの中で作業します。

1. **`build.bat`** — `AtIo.exe` を作ります(Windows 標準の `csc.exe` を使用)
   - できたら `AtIo.exe -HELP` を実行すると、使い方と引数の説明が表示されます
2. **`MonitorMock.bat`** — 疑似データでダッシュボードが動くことを確認します(画面は別ブラウザの専用窓で開きます)
3. 実機につなぐ
   1. `Monitor.bat` を一度起動すると、`Config.ps1` が自動で作られます。止めて、`$Port` を実際の COM 番号に直します
   2. **`Probe.bat`** — 機器が対応している AT コマンドを調べます
   3. **`Monitor.bat`** — 実機の値で動きます

社内ネットワークなど外部につながらない PC へは、`app/` フォルダごとコピーすれば動きます。
USB メモリを使えない場合は、Git(または GitHub の ZIP)経由で導入します。手順は [docs/deploy-via-git.md](docs/deploy-via-git.md) を参照してください。

## バッチファイルの使い方

`app/` フォルダの 4 つの `.bat` は、どれもダブルクリックで動きます。コマンドプロンプトから実行してもかまいません(どこから実行しても、自分のフォルダに移動してから動きます)。
実行が終わると `pause` で止まり、「続行するには何かキーを押してください」と出るので、結果を読んでから閉じられます(`Monitor.bat` を、監視が動いているときに押した場合だけは止まらずに閉じます)。

| バッチ | 役割 | 引数 | できるもの |
|---|---|---|---|
| `build.bat` | `AtIo.cs` から `AtIo.exe` を作る | なし | `AtIo.exe` |
| `MonitorMock.bat` | 疑似データで画面を確認する(実機不要) | なし | 監視画面が開き、グラフが動く |
| `Monitor.bat` | 実機を監視する。動いていれば監視画面を前面に出す | `-Mock`、`-IntervalSec <秒>` | `logs\csq_YYYYMM.csv`、`logs\test_YYYYMMDD.log`、`data.js` |
| `Probe.bat` | 機器が対応している AT コマンドを調べる | `-Mock`、`-ListFile <ファイル名>` | `probe_日時.txt` |

### `build.bat`

- Windows に入っている `csc.exe`(.NET Framework 4.x)で `AtIo.exe` を作ります。64bit 版が見つからなければ 32bit 版を使います。
- 成功すると `BUILD OK: AtIo.exe`、失敗すると `BUILD FAILED` と表示され、その上にコンパイラのエラーが出ます。
- `AtIo.cs` を直したときも、これを実行し直します。

### `MonitorMock.bat`

- 疑似データを 3 秒ごとに作り、監視画面を開きます。画面右上は `LIVE (MOCK)` になります。
- COM ポートには触りません。最初の動作確認や、画面(`index.html`)をいじるときに使います。

### `Monitor.bat`

- 実機の値を、`Config.ps1` の周期(既定 180 秒)で取得します。監視画面も自動で開きます(開き方は「監視画面とブラウザ」を参照)。
- コンソールの窓のタイトルは「CsqWatch 稼働中 (閉じないでください)」になります。
- すでに動いているときに起動すると、2 つ目は監視を始めずに、監視画面を前面に出し(閉じていれば開き)、5 秒後に自動で閉じます。別のユーザーでログオンして起動した場合も監視は二重に動きません。
- 初回は `Config.ps1` が自動で作られます。`$Port` を実際の COM 番号に直してから使ってください。
- 引数は、コマンドプロンプトから付けて実行します(ダブルクリックでは渡せません)。

  ```
  Monitor.bat                      実機を監視 (周期は Config.ps1 の $PollSec)
  Monitor.bat -Mock                疑似データ
  Monitor.bat -IntervalSec 10      周期を 10 秒にする (動作確認用)
  ```

  ダブルクリックで引数付きにしたいときは、`Monitor.bat` のショートカットを作り、「リンク先」の末尾に ` -IntervalSec 10` のように足します。

### `Probe.bat`

- `probe_commands.txt` のコマンドを順に送り、結果を `probe_日時.txt` に保存します。`Monitor.bat` は先に止めておきます。
- `Probe.bat -ListFile 別のファイル.txt` で、別のコマンド一覧を使えます。`Probe.bat -Mock` は、実機なしの試し実行です。

### 止めかた

- `Monitor.bat` と `MonitorMock.bat` は止めるまで動き続けます。**Ctrl+C** を押すか、ウィンドウを閉じます。「バッチ ジョブを終了しますか」と聞かれたら `Y` を入力します。
- 止めたあとも、監視画面は開いたままです。更新が止まると、右上が **STALE**(赤)になります。
- 次に起動すると、同じ月の CSV から直近のグラフを復元して再開します。

## 画面の見かた

| 表示 | 意味 |
|---|---|
| Downlink RSSI に数値、Signal Level に `38 / 55` | 端末が値を返した(`/` の右は目盛りの最大値 `$RssiMax`。IsatPhone 2 は 55) |
| Downlink RSSI に `圏外 (99)` | 端末自身が「圏外・測定できない」と返した。グラフは 0 で描く |
| Downlink RSSI に `--`、Signal Level に赤の `取得失敗` | 端末から値を取れなかった(COM ポートのエラー・無応答など)。端末の圏外ではない。グラフは線が途切れる |
| 右上 **STALE**(赤) | 監視(Monitor)が止まっている |

## 監視画面とブラウザ

この PC では、社外監視(VPN 経由の衛星事業者のダッシュボード)の窓が**最優先**です。監視画面はそれに影響を与えないように開きます。

- **別のブラウザで開く** — 既定(`$Browser = 'auto'`)では Chrome → Edge の順に探します。社外監視の窓と種類が違うので、閉じる窓を取り違えにくくなります。Firefox は他の業務で使うので `auto` には含めていません。
- **別のプロセスで開く** — 専用のプロファイル(`app\profile_<ブラウザ名>`)で起動するので、社外監視のブラウザとはプロセスが分かれます。こちらが重くなっても落ちても巻き込まず、Cookie やログイン情報も共有しません。
- **窓を増やさない** — 監視画面がすでに開いていれば、新しく開かずにその窓を前面に出します。専用プロファイルで動いているブラウザのプロセスを探して前面に出すので、社外監視の窓は動かしません。
- **タブのない専用の窓** — Chrome と Edge はアプリモードで開くので、社外監視のタブに混ざりません。Firefox は通常の窓(タブ付き)ですが、別プロセス・別窓です。
- **優先度を下げる** — Monitor は CPU 優先度「通常以下」で動き、監視画面のブラウザと `AtIo.exe` もそれを引き継ぎます。
- **ネットワークを使わない** — Monitor と監視画面はローカルのファイルだけで動き、VPN の回線には何も流れません。
- このツールは、ブラウザを閉じたり、他の窓を操作したりしません。

設定は `Config.ps1` で変えます。

| 項目 | 既定値 | 意味 |
|---|---|---|
| `$Browser` | `'auto'` | `auto` / `chrome` / `edge` / `firefox` |
| `$DashboardSize` | `'1280,860'` | 窓の大きさ(幅,高さ)。Chrome・Edge のみ |
| `$DashboardPos` | `''` | 窓の位置(x,y)。例 `'1920,0'` で 2 枚目のモニターの左上。Chrome・Edge のみ |
| `$OpenDashboard` | `$true` | Monitor 起動時に監視画面を開くか |

運用側のモニターが少ないあいだは、`$DashboardPos` で社外監視の窓と重ならない位置に固定しておくと安心です。窓が開いた瞬間はその窓が前面に出るので、置き場所を決めておいてください。

画面(`index.html`)そのものは、Edge・Chrome・Firefox のどれで開いても同じように動きます。

## 試験ログ

`logs\test_YYYYMMDD.log` に、1 日 1 ファイルで記録します。1 行ごとに書き込んで閉じるので、強制終了や PC の再起動があっても直前までの記録が残ります(3 分周期で 1 日あたり 100KB 程度)。

書式は `日時(ミリ秒)  区分  内容` です。応答の中の改行は ` | ` に置き換えます。

| 区分 | 内容 |
|---|---|
| `INFO` | 起動(PID・PowerShell のバージョン・**PC の起動時刻**)、設定値、`AtIo.exe` の日付とサイズ、履歴の読込件数、試験発信の開始・終了、監視画面の表示、**停止(`STOP`)** |
| `CMD` | 送ったコマンドと待ち時間 |
| `RSP` | 応答と所要時間(ms)。PowerShell 5.1 がエラーに付ける飾り(「発生場所」など)は除く。空のときは `(空応答)` |
| `DBG` | ポーリングの番号、見えている COM ポートの一覧、メモリ使用量、解析後の値(取得できたか `ok`・rssi・ber・creg) |
| `WARN` | `AtIo.exe` の残留、COM ポートの消失、周期の遅れ(スリープの兆候)、解析失敗、`+CREG:` の非同期通知の混入、`data.js` の置き換え失敗、多重起動の検出、前回の異常終了 |
| `ERR` | CSV の書き込み失敗、予期しないエラー(行番号付き) |

```
2026-10-21 10:30:00.112  INFO  START  pid=8412  ps=5.1.22621.4391  user=xxxx  boot=2026-10-21 08:12:45
2026-10-21 10:30:00.310  DBG   POLL #1  ports=COM1,COM3,COM4  mem=62MB
2026-10-21 10:30:00.322  CMD   AT+CSQ  wait=3s
2026-10-21 10:30:01.087  RSP   AT+CSQ  765ms  +CSQ: 37,0 |  | OK
2026-10-21 10:30:01.806  DBG   解析結果  ok=True  rssi=37  ber=0  creg=1  reg=同期完了 (Registered)  note=Periodic
```

止まり方の見分け方:

| ログの最後 | 意味 |
|---|---|
| `CMD` で終わり、対応する `RSP` がない | `AtIo.exe` から戻らないうちに終了した(端末側が固まった可能性) |
| `ERR UNHANDLED ...` | スクリプトの異常終了。行番号でどこで落ちたかがわかる |
| `INFO STOP` | Ctrl+C で止めた(異常終了のときも `ERR` のあとに `STOP` が残る) |
| `RSP`・`DBG` まで正常で、`STOP` がない | 外部要因(PC の再起動・ログオフ・× ボタンで窓を閉じた)。次の `START` の `boot=` で再起動を確認できる |

起動中の Monitor の情報(PID・開始時刻・ユーザー)は `logs\monitor_running.txt` に書かれます(Ctrl+C で止めると消えます)。

### 共通の動き

- 中では `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...` を呼んでいます。ポリシーの設定を書き換えず、この起動だけ実行を許可します。組織のポリシーで禁止されている場合は、管理者に相談してください。
- `.bat` は日本語を含まない(ASCII のみ)ようにしてあります。cmd が cp932 を使うため、日本語を入れると文字化けします。

## ファイル構成

```
app/
├─ AtIo.cs            COM ポート I/O 専用。AT コマンドは引数で受け取る (触らない)
├─ build.bat            AtIo.cs → AtIo.exe
├─ Config.sample.ps1    設定のひな形。初回に Config.ps1 へ自動コピーされる
├─ Monitor.ps1          収集ループ。CSV 保存・data.js 出力・試験ログ・多重起動防止
├─ Browser.ps1          監視画面を別ブラウザ・別プロセスで開く (開いていれば前面に出す)
├─ Common.ps1           AtIo.exe の呼び出しと -Mock の疑似応答
├─ Probe.ps1            対応 AT コマンドの調査
├─ probe_commands.txt   Probe が送るコマンド一覧 (1 行 1 コマンド)
├─ index.html           画面
├─ manual.html          説明書 (README と docs を 1 冊にした HTML。tools/build_manual.py で生成)
├─ chart.umd.min.js     Chart.js 4.5.1 (同梱)
├─ *.bat                ダブルクリック用ランチャ
└─ (実行時に作られる)    logs\ (CSV・試験ログ)、data.js、profile_<ブラウザ名>\ (監視画面用プロファイル)
tools/build_manual.py   説明書 manual.html を作る道具 (開発側 PC 用)
docs/                   設計メモ(architecture.md)、関数表(functions.md)、AT コマンド表(at-command-table.md)、
                        AT コマンドの調べ方(at-commands.md)、導入手順(deploy-via-git.md)
THIRD_PARTY_LICENSES/   同梱ライブラリのライセンス
```

## よく触る場所

| やりたいこと | 場所 |
|---|---|
| 機器名(画面の見出し)・COM 番号・取得周期・定時試験発信の時刻 | `Config.ps1` |
| 信号の目盛りの最大値(グラフの縦軸) | `Config.ps1` の `$RssiMax` |
| 画面に項目(カード)を足す | `Config.ps1` の `$Extras` |
| 登録状態の表示名を変える | `Config.ps1` の `$RegText` |
| 調べたい AT コマンドを足す | `probe_commands.txt` |
| 画面の見た目 | `index.html` |
| 監視画面を開くブラウザ・窓の位置 | `Config.ps1` の `$Browser`、`$DashboardPos` |
| 止まった原因を調べる | `logs\test_YYYYMMDD.log` |

## 説明書(HTML)

MD を読めない PC でも読めるように、README と `docs/` の MD を 1 冊にまとめた `app/manual.html` を同梱しています。

- Windows 11 標準の Edge で開けます。インストールは要りません。画像も中に入っているので、1 ファイルだけで表示できます。
- 先頭の目次から各節へ飛べます。**Ctrl+F で文字を検索**でき、コピーや印刷もできます(印刷すると文書ごとに改ページします)。
- 監視画面の右上の「説明書」から開けます。
- 元原稿は MD です。**MD を直したら、開発側の PC で `python tools/build_manual.py` を実行して作り直してください**(Python と `markdown-it-py`・`mdit-py-plugins` が必要です。社内 PC には不要です)。`manual.html` を直接編集しないでください。

## 機器ごとの注意

機器によって、AT コマンドの対応範囲や値の目盛りが違います。新しい機器では、まず `Probe.bat` で対応状況を調べ、`AT+CSQ=?` の応答で目盛りの最大値を確かめてから、`Config.ps1` の `$RssiMax` と `$DeviceName` を合わせてください。

### Inmarsat IsatPhone 2(確認済み)

- `AT+CSQ` の rssi は **0〜55**、ber は 0〜15 です(`AT+CSQ=?` の応答 `(0-55,99),(0-15,99)`)。GSM の dBm 換算は使えません。`$RssiMax = 55` にします。
- **`AT+CBC` は使用禁止**です。送ると端末がしばらく無応答になり、後続のコマンドも返らなくなります。
- `AT+CGREG?`・`AT+CGATT?` は未対応(`+CME ERROR: 4`)、`AT+CLAC` も使えません(`+CME ERROR: 25`)。
- PC からの通信には、メーカーの USB ドライバーが必要です(ドライバーなしでは COM ポートが見えても通信できません)。

詳しくは [docs/at-command-table.md](docs/at-command-table.md) を参照してください。

## 旧名(IsatMon)からの移行

このツールは、以前は IsatMon という名前でした。メーカーの製品名に近い名前を避け、AT コマンド機器全般に使える名前に改めました。旧版から入れ替えるときは、次の点に注意してください。

- **旧版の監視を止めてから**入れ替えてください(二重起動防止の名前が変わったので、旧版と新版は互いを検出できません)。
- I/O 用の EXE は `IsatIo.exe` から `AtIo.exe` に変わりました。`build.bat` を実行し直してください。古い `IsatIo.exe` は削除してかまいません。
- 手元の `Config.ps1` はそのまま使えます(`$IsatIoExe` の行は使われなくなり、`AtIo.exe` を使います)。画面の見出しに機器名を出したいときは `$DeviceName = 'IsatPhone 2'` を足します。
- CSV の名前は `isat_YYYYMM.csv` から `csq_YYYYMM.csv` に変わりました。同じ月の旧 CSV があれば、起動時にそこからグラフを復元します(旧ファイルは書き換えず、そのまま残ります)。
- 画面のデータ名(`window.ISAT_DATA` → `window.CSQ_DATA`)も変わったので、`index.html` と `Monitor.ps1` は必ず両方入れ替えてください。

## 注意

- COM ポートは 1 本につき 1 プログラムだけです。`Monitor.bat` と `Probe.bat` は同時に動かさないでください(`Monitor.bat` どうしの二重起動は自動で防ぎますが、`Probe.bat` は防ぎません)。
- **IsatPhone 2 では `AT+CBC` を送らないでください**(端末が無応答になります)。`$Extras` や `probe_commands.txt` に入れないでください。
- `logs\csq_YYYYMM.csv` を Excel で開いたままにすると、その間は追記できず警告が出ます。コピーしてから開いてください。
- `.bat` は `-ExecutionPolicy Bypass` で起動します。組織のポリシーで PowerShell の実行が禁止されている場合は、管理者に相談してください。
- `.ps1` `.cs` `probe_commands.txt` は **UTF-8(BOM 付き)** で保存してください。BOM がないと、日本語環境の PowerShell 5.1 や `csc.exe` が ANSI(cp932)と誤読して文字化けします。
- 定時試験発信(`$CallTimes`)は既定で無効です。衛星電話の発信は通話料がかかります。
- 試験ログにはダイヤルした番号も記録されます。ログを公開・共有するときは番号を伏せてください。
- PC がスリープすると取得が止まります。電源設定でスリープを「なし」にしておいてください(試験ログに「周期遅れ」が出ます)。

## 検証状況

- PowerShell 7.4 + Mono 上のモック、および代役の `AtIo.exe` を使った実機経路(引数の受け渡し・COM エラーからの復帰・定時発信)で動作を確認しています。
- 2026-10-14 に、IsatPhone 2 の実機と Windows PowerShell 5.1 で `Monitor.bat`・`Probe.bat` の動作を確認しました。
- 実機でわかったこと:
  - `AT+CSQ` の rssi は **0〜55**(`AT+CSQ=?` の応答 `(0-55,99),(0-15,99)`)で、標準の 0〜31 とは別のスケールです。GSM の dBm 換算は使えないので、画面と CSV は生の値を `値 / 55` で表示し、グラフの縦軸も 0〜55 にしています(最大値は `Config.ps1` の `$RssiMax`)。
  - `AT+CBC` を送ると端末が無応答になります(使用禁止)。
  - `AT+CGREG?`・`AT+CGATT?` は未対応(`+CME ERROR: 4`)、`AT+CLAC` も使えません(`+CME ERROR: 25`)。
- 2026-10-21 に、COM の先に端末がない Windows 11 のノート PC(PowerShell 5.1)で、試験ログ・ポートエラー時の記録・二重起動の防止・Chrome での別窓表示を確認しました。
- 入口の一本化(既存の画面を前面に出す)、取得失敗と圏外の表示の区別、`STOP` の記録は、PowerShell 7.4(Linux)の `-Mock` と端末なしの経路で確認しています。**Windows 上での「既存の画面を前面に出す」動作はまだ確認していません。**

## ライセンス

[MIT License](LICENSE) — Copyright (c) 2026 Yuichi Matsui (JH0VEQ)

## 商標

Inmarsat、IsatPhone は Inmarsat(Viasat)の商標です。このツールは Inmarsat・Viasat とは関係のない、独自のツールです。その他の製品名は各社の商標です。

## サードパーティ

- [Chart.js](https://www.chartjs.org/) 4.5.1 (MIT)  ライセンスは [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES/Chart.js-LICENSE.md)
