using System;
using System.IO.Ports;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

// AtIo.cs (CsqWatch)   Author: yuichi
//
// IO 専用: シリアルポートに AT コマンドを 1 つ送って、応答をそのまま標準出力へ出す。
// コマンドの中身や判定は一切持たない (すべて引数で渡す)。
//
//   AtIo.exe <Port> <BaudRate> <Cmd> [WaitSec] [AfterCmd] [DuringCmd] [DuringEverySec]
//   AtIo.exe -HELP          ... 使い方を表示 (-H / --HELP / -? / /? も可)
//
//   例) 信号強度:   AtIo.exe COM3 115200 "AT+CSQ" 3
//       試験発信:   AtIo.exe COM3 115200 "ATD+819012345678;" 20 "ATH"
//       通話中も測る: AtIo.exe COM3 115200 "ATD+819012345678;" 20 "ATH" "AT+CSQ" 5
//
//   AfterCmd なし : 終端 (OK / ERROR / NO CARRIER ...) を受信した時点で終了。WaitSec が上限。
//   AfterCmd あり : WaitSec 秒だけ受信を続け、その後 AfterCmd を送って 1 秒待つ。
//   DuringCmd あり: Cmd の終端行を受信したあと、DuringEverySec 秒ごとに DuringCmd を送る
//                   (Cmd の応答前には送らない。発信中に文字を送ると発信が中断される機器があるため)。
//                   NO CARRIER / BUSY / NO ANSWER / NO DIALTONE を受信したら、待ちを打ち切って AfterCmd へ進む。
//                   区切りとして「--- during <コマンド>」「--- after <コマンド>」の行を標準出力へ出す。
//
//   終了コード  0=正常  1=引数不足  2=I/O エラー
class AtIo
{
    // 応答の終端行 (OK / ERROR / +CME ERROR: n など) が受信済みか。
    // 受信を分割して受けても取りこぼさないよう、これまでの全文に対して調べる。
    static readonly Regex Final = new Regex(
        @"(^|[\r\n])(OK|ERROR|NO CARRIER|BUSY|NO ANSWER|NO DIALTONE|\+CM[ES] ERROR:[^\r\n]*)\r",
        RegexOptions.Compiled);

    // 通話が終わったことを示す結果コード (DuringCmd ありのとき、待ちを打ち切る)
    static readonly Regex CallEnd = new Regex(
        @"(^|[\r\n])(NO CARRIER|BUSY|NO ANSWER|NO DIALTONE)\r",
        RegexOptions.Compiled);

    // -HELP / -H / --HELP / -? / /?  (大文字小文字は区別しない)
    static bool IsHelp(string a)
    {
        string s = a.ToUpperInvariant();
        return s == "-HELP" || s == "--HELP" || s == "-H" || s == "-?" || s == "/?" || s == "/HELP";
    }

    const string HelpText = @"AtIo (CsqWatch) - AT command one-shot sender for a serial modem
         シリアルポートに AT コマンドを 1 つ送り、応答をそのまま標準出力へ出す

USAGE
  AtIo.exe <Port> <BaudRate> <Cmd> [WaitSec] [AfterCmd] [DuringCmd] [DuringEverySec]
  AtIo.exe -HELP

ARGUMENTS
  Port       COM ポート名                          例: COM3
  BaudRate   ボーレート (数値でなければ 115200)    例: 115200
  Cmd        送る AT コマンド (行末の CR は自動)    例: ""AT+CSQ""
  WaitSec    応答を待つ上限の秒数 (既定 3)
  AfterCmd   WaitSec 経過後に続けて送るコマンド    例: ""ATH""
  DuringCmd  待っている間に繰り返し送るコマンド    例: ""AT+CSQ""   (AfterCmd と一緒に使う)
  DuringEverySec  DuringCmd を送る間隔の秒数 (既定 5、最小 2)

BEHAVIOR
  接続      8N1、DTR/RTS を ON。開いた直後に ATE0V1 (エコーOFF・文字応答) を送る。
  AfterCmd なし
            OK / ERROR / NO CARRIER などの終端行を受信した時点で終了する。
            WaitSec は待ち時間の上限。
  AfterCmd あり
            WaitSec 秒のあいだ受信を続け、その後 AfterCmd を送って 1 秒待つ。
            (発信して呼び出し、一定時間後に切断する用途)
  DuringCmd あり
            Cmd の終端行 (OK など) を受信したあと、DuringEverySec 秒ごとに DuringCmd を送る。
            Cmd の応答前には送らない (発信中に文字を送ると発信が中断される機器があるため)。
            NO CARRIER / BUSY / NO ANSWER / NO DIALTONE を受信したら待ちを打ち切る。
            区切りとして ""--- during <コマンド>"" ""--- after <コマンド>"" の行を出す。
  出力      応答は加工せず標準出力へ。エラーメッセージは標準エラー出力へ。

EXIT CODE
  0  正常
  1  引数不足
  2  I/O エラー (ポートを開けない、など)

EXAMPLES
  AtIo.exe COM3 115200 ""AT+CSQ"" 3
  AtIo.exe COM3 115200 ""AT+CREG?"" 2
  AtIo.exe COM3 115200 ""ATD+81xxxxxxxxxx;"" 20 ""ATH""
  AtIo.exe COM3 115200 ""ATD+81xxxxxxxxxx;"" 20 ""ATH"" ""AT+CSQ"" 5

NOTE
  ATD (発信) は通話料がかかります。COM ポートは同時に 1 プログラムしか使えません。

HELP OPTIONS
  -HELP  --HELP  -H  -?  /?  /HELP   (大文字小文字は区別しない)
";

    static int Main(string[] args)
    {
        if (args.Length >= 1 && IsHelp(args[0]))
        {
            Console.Write(HelpText);
            return 0;
        }

        if (args.Length < 3)
        {
            Console.Error.WriteLine("Usage: AtIo.exe <Port> <BaudRate> <Cmd> [WaitSec] [AfterCmd] [DuringCmd] [DuringEverySec]");
            Console.Error.WriteLine("Help : AtIo.exe -HELP");
            return 1;
        }

        string portName = args[0];
        int baudRate;
        if (!int.TryParse(args[1], out baudRate)) baudRate = 115200;

        string cmd = args[2];
        int waitSec = 3;
        if (args.Length >= 4 && !int.TryParse(args[3], out waitSec)) waitSec = 3;
        string afterCmd = args.Length >= 5 ? args[4] : null;
        if (afterCmd == "") afterCmd = null;
        string duringCmd = args.Length >= 6 ? args[5] : null;
        if (duringCmd == "" || afterCmd == null) duringCmd = null;   // DuringCmd は AfterCmd と一緒のときだけ
        int duringEvery = 5;
        if (args.Length >= 7 && !int.TryParse(args[6], out duringEvery)) duringEvery = 5;
        if (duringEvery < 2) duringEvery = 2;

        using (SerialPort port = new SerialPort(portName, baudRate, Parity.None, 8, StopBits.One))
        {
            try
            {
                port.ReadTimeout = 2000;
                port.WriteTimeout = 2000;
                port.DtrEnable = true;   // クレードル/モデムのスリープ解除に必要
                port.RtsEnable = true;
                port.Open();

                // 初期化: エコーOFF + 詳細応答(V1)。この応答は捨てる。
                port.DiscardInBuffer();
                port.Write("ATE0V1\r");
                Thread.Sleep(80);
                port.DiscardInBuffer();

                port.Write(cmd + "\r");

                StringBuilder all = new StringBuilder();
                DateTime start = DateTime.Now;
                bool mainDone = false;            // Cmd の終端行を受信したか
                DateTime lastDuring = DateTime.MinValue;
                while ((DateTime.Now - start).TotalSeconds < waitSec)
                {
                    string chunk = port.ReadExisting();
                    if (chunk.Length > 0)
                    {
                        Console.Write(chunk);
                        all.Append(chunk);
                    }
                    if (afterCmd == null && Final.IsMatch(all.ToString())) break;

                    if (duringCmd != null)
                    {
                        string s = all.ToString();
                        if (!mainDone && Final.IsMatch(s))
                        {
                            mainDone = true;
                            lastDuring = DateTime.Now;    // 最初の DuringCmd は DuringEverySec 秒後
                        }
                        if (mainDone && CallEnd.IsMatch(s)) break;   // 通話が終わった
                        double left = waitSec - (DateTime.Now - start).TotalSeconds;
                        if (mainDone && left >= 2 && (DateTime.Now - lastDuring).TotalSeconds >= duringEvery)
                        {
                            Console.Write("\r\n--- during " + duringCmd + "\r\n");
                            port.Write(duringCmd + "\r");
                            lastDuring = DateTime.Now;
                        }
                    }
                    Thread.Sleep(50);
                }

                if (!string.IsNullOrEmpty(afterCmd))
                {
                    if (duringCmd != null) Console.Write("\r\n--- after " + afterCmd + "\r\n");
                    port.Write(afterCmd + "\r");
                    Thread.Sleep(1000);
                    Console.Write(port.ReadExisting());
                }
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("IO Error: " + ex.Message);
                return 2;
            }
        }
    }
}
