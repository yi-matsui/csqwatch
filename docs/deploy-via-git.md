# Git 経由で社内 PC に導入する

Author: yuichi(更新 2026-10-21)

USB メモリを持ち込めない環境向けの手順です。

```
開発側の PC ──push──► GitHub ──clone / ZIP──► 社内 PC
```

`AtIo.exe` はリポジトリに含めません。社内 PC で `build.bat` を実行して作ります(`csc.exe` は Windows 標準なので、追加のインストールは要りません)。

社内 PC に必要なものは、Windows 11 に最初から入っているものだけです(PowerShell 5.1・.NET Framework 4.x・Edge)。**インストールも管理者権限も要りません。**

## 1. GitHub に置く(開発側 PC・初回だけ)

1. GitHub で**空の**リポジトリを作ります(README や LICENSE は追加しない)。名前の例は `csqwatch` です。
2. `csqwatch-repo` フォルダの中で実行します。

   ```
   git init -b main
   git config user.name  "あなたの名前"
   git config user.email "<ID>+<ユーザー名>@users.noreply.github.com"
   git add .
   git commit -m "Initial commit"
   git remote add origin https://github.com/<ユーザー名>/csqwatch.git
   git push -u origin main
   ```

   メールアドレスを公開したくないときは、上の `users.noreply.github.com` の形(GitHub の設定画面の Email に表示されます)を使います。

3. push の前に、`git status` と `git ls-files` で次のものが**含まれていない**ことを確認します(`.gitignore` で除外済みです)。
   - `Config.ps1`(COM 番号・発信先)
   - `logs\`(CSV・試験ログ・`monitor_running.txt`)、`data.js`、`probe_日時.txt`(実機の値や機器の情報が入ります)
   - `profile_<ブラウザ名>\`(監視画面用のブラウザプロファイル)
   - `AtIo.exe`

**公開リポジトリにする場合の注意**: コミットしたものは、誰でも見られます。社内の名称・電話番号・機器の情報を、ファイルに書き込まないでください。現在のファイルには、ダミーの電話番号(`+819012345678`)しか入っていません。

## 2. 社内 PC に入れる

### 2-A. Git が入っている場合

```
git clone https://github.com/<ユーザー名>/csqwatch.git
cd csqwatch\app
build.bat
```

更新するときは、次のとおりです。

```
cd csqwatch
git pull
```

`AtIo.cs` が変わったときだけ、`app\build.bat` を実行し直します。
`Config.ps1`・`logs\`・`profile_<ブラウザ名>\`・`AtIo.exe` は Git の管理外なので、`git pull` で上書きされたり消えたりしません。

### 2-B. Git が入っていない場合(Windows 11 の標準機能だけ)

ブラウザで、リポジトリのページの **Code → Download ZIP** を選びます。コマンドで取るときは、次のとおりです。

```
curl.exe -L -o csqwatch.zip https://github.com/<ユーザー名>/csqwatch/archive/refs/heads/main.zip
Unblock-File .\csqwatch.zip
Expand-Archive .\csqwatch.zip -DestinationPath .
```

(`Unblock-File` と `Expand-Archive` は PowerShell のコマンドです。`curl.exe` はコマンドプロンプトでも使えます。)

- 展開すると `csqwatch-main` というフォルダができます。その中の `app` を使います。
- **`Unblock-File` を忘れないでください。** インターネットから取った ZIP は「ブロック」の印が付いていて、展開したファイルまで引き継ぎます。そのまま `.bat` を開くと、セキュリティの警告が出ます。ZIP のプロパティで「許可する」にチェックを入れても同じです。
- 更新するときは、**監視(`Monitor.bat`)を止めてから**、新しい ZIP を取り直し、展開した `app` の中身を前回のフォルダへ上書きコピーします。`Config.ps1`・`logs\`・`profile_<ブラウザ名>\` は ZIP に入っていないので、残ります。

### 2-C. 旧名(IsatMon)から入れ替える場合

以前の IsatMon を使っていた PC では、次の順に入れ替えます。詳しくは README の「旧名(IsatMon)からの移行」を参照してください。

1. 旧版の監視を止める(旧版と新版は、互いの二重起動を検出できません)
2. 新しい `app` の中身を上書きコピーし、`build.bat` で `AtIo.exe` を作る
3. 古い `IsatIo.exe` と、使わなくなった `Dashboard.bat`・`Dashboard.ps1`・`edge_profile\` があれば削除する
4. `Monitor.bat` で起動する(今月の旧 CSV `isat_YYYYMM.csv` からグラフを復元します)

## 3. 動作確認

```
cd app
build.bat          → BUILD OK: AtIo.exe
MonitorMock.bat    → 疑似データで画面が動く(監視画面は別のブラウザの専用窓で開く)
```

`MonitorMock.bat` を動かしたまま、もう一度 `MonitorMock.bat` を押して、窓が増えずに今の監視画面が前面に出ることも確かめてください。

そのあと、実機の手順(`Config.ps1` の `$Port`・`$DeviceName`・`$RssiMax` → `Probe.bat` → `Monitor.bat`)に進みます。

## 4. うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| `git clone` で認証を求められる | 非公開リポジトリです。公開にするか、個人アクセストークンを使います |
| 社内プロキシ経由でしか外に出られない | `git config --global http.proxy http://<プロキシ>:<ポート>` を設定します。`curl.exe` は `-x http://<プロキシ>:<ポート>` を付けます |
| `.bat` を開くとセキュリティ警告が出る | ZIP の `Unblock-File` を忘れています。展開し直してください |
| `Monitor.ps1` が「署名されていません」と出る | `.ps1` を直接実行しています。`.bat` から起動すると出ません |
| `build.bat` が `BUILD FAILED` になる | 表示の上にあるコンパイラのエラーを確認します |
| 監視画面が開かない | 試験ログの `WARN 監視画面を開けませんでした` を確認します。会社のポリシーでブラウザの起動オプションが制限されていることがあります。`Config.ps1` の `$Browser` を変えて試します |
| 画面に「取得失敗」が続く | COM 番号(`$Port`)、機器のドライバー、ほかのプログラムが COM ポートを使っていないかを確認します。試験ログの `RSP` 行にエラーの内容が出ます |
| `Monitor.bat` を押すと、すぐに黒い窓が閉じる | 監視はすでに動いています(画面が前面に出ます)。正常な動作です |
