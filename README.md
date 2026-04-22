# BambuMultiTask

家庭内にある複数台の Bambu Lab 3D プリンタの進捗を **macOS のメニューバーから一目で確認** するための非公式ツールです。

公式の Bambu Studio / Bambu Handy だと 1 台ずつ切り替えないと残り時間や進捗が見られないので、全台の状態をまとめて眺められるようにしました。

## 特徴

- メニューバーに常駐し、印刷中のうち**一番早く終わるプリンタの残り時間**を表示
- メニューを開くと全プリンタの進捗・残り時間・レイヤー・ノズル/ベッド温度を一覧表示
- ローカル MQTT (LAN Only Mode) で通信するためクラウド不要・インターネット不要
- 複数台の登録・削除・編集が可能

## 動作要件

- macOS 13.0 以降
- Bambu Lab プリンタ (X1 / P1 / A1 系) が同じ LAN にあり、**LAN Only Mode が有効** であること
- Swift 5.9 以上 (Xcode 15 以降 or Swift toolchain)

## ビルド

```bash
# Swift executable としてそのまま実行
swift run

# もしくは .app バンドルを作成（推奨）
./scripts/build-app.sh
open build/BambuMultiTask.app
```

`build-app.sh` は universal binary (arm64 + x86_64) で `.app` を作り、ad-hoc 署名まで行います。

## 使い方

1. プリンタ側で **設定 → ネットワーク → LAN Only Mode** を有効化
2. プリンタの **IP アドレス / シリアル番号 / アクセスコード** をメモ
   - IP: プリンタ画面の WiFi 設定
   - シリアル: 本体裏 or 設定画面
   - アクセスコード: LAN Only Mode の画面に表示される 8 桁
3. 本アプリを起動し、メニューバーアイコンをクリック
4. 「設定…」から **＋** ボタンでプリンタを追加

## 認証情報の保存について

現状は `UserDefaults` に Access Code を平文で保存しています (ローカル運用前提)。将来的に Keychain に移行予定。

## 構成

```
Sources/BambuMultiTask/
├── BambuMultiTaskApp.swift      # @main / MenuBarExtra scene
├── Models/
│   ├── Printer.swift             # 接続情報
│   └── PrinterStatus.swift       # 実行時ステータス
├── Services/
│   ├── BambuMQTTClient.swift     # CocoaMQTT + TLS + pushall
│   └── PrinterManager.swift      # 全クライアント集約
├── Stores/
│   └── SettingsStore.swift       # UserDefaults 永続化
└── Views/
    ├── MenuBarView.swift          # ドロップダウン
    ├── PrinterRowView.swift       # 各プリンタの行
    └── SettingsView.swift         # 設定ウィンドウ
```

## 技術メモ

- Bambu プリンタは `mqtts://{IP}:8883` で MQTT over TLS を提供
- 認証: username `bblp` / password = Access Code
- 自己署名証明書のため `allowUntrustCACertificate` を有効化
- 接続後、`device/{SERIAL}/request` に `{"pushing":{"sequence_id":"0","command":"pushall"}}` を publish すると完全な状態が `device/{SERIAL}/report` に返ってくる
- 以降は差分更新が届く

## 参考

- 公式スライサ: https://github.com/bambulab/BambuStudio
- MQTT 仕様参考: https://github.com/Doridian/OpenBambuAPI

## ライセンス

MIT
