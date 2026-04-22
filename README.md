# BambuMultiTask

家庭内にある複数台の Bambu Lab 3D プリンタの進捗を **macOS アプリで一目で確認** するための非公式ツールです。公式の Bambu Studio / Handy は 1 台ずつ切替しないと残り時間が見られないため、全台の状態をまとめて眺められるようにしました。

## 特徴

- プリンタの進捗・残り時間・レイヤー・温度を**カードUIで一覧表示**
- **LAN 接続** (LAN Only Mode) と **Bambu クラウド接続** の両対応
- クラウドアカウントログイン → 登録機器リストを自動取り込み
- App Sandbox 対応済み、Developer Team 署名済み

## 動作要件

- macOS 15.5 以降
- Xcode 16 以降 (ビルドのみ)
- 同一 LAN に Bambu Lab プリンタ、または Bambu クラウド上の登録機器

## ビルドと実行

```bash
open BambuMultiTask/BambuMultiTask.xcodeproj
# Xcode で Cmd+R
```

または CLI:

```bash
xcodebuild -project BambuMultiTask/BambuMultiTask.xcodeproj \
  -scheme BambuMultiTask -configuration Debug build
```

## 使い方

### A. LAN 接続

1. プリンタ側で **設定 → ネットワーク → LAN Only Mode** を有効化
2. アプリ起動 → 設定 → プリンタ → **＋** で追加
3. 名前 / IP / シリアル番号 / Access Code を入力して保存

### B. Bambu クラウド接続

1. アプリ起動 → 設定 → **クラウド** タブ
2. 地域 (グローバル/中国) を選択
3. メール＋パスワード、または **メール認証コード** でログイン
4. 「デバイス一覧を取得」→「プリンタ一覧に追加」

※ クラウド API は非公式で、Bambu 側の仕様変更により動作しなくなる可能性があります。動作しない場合は LAN 接続をご利用ください。

## プロジェクト構成

```
BambuMultiTask/                       # Xcode プロジェクト
├── BambuMultiTask.xcodeproj
└── BambuMultiTask/
    ├── AppDelegate.swift             # NSWindow + SwiftUI root
    ├── BambuMultiTask.entitlements   # App Sandbox + network.client
    ├── Assets.xcassets
    ├── Models/
    │   ├── Printer.swift              # 接続情報 + 接続種別 (LAN/Cloud)
    │   └── PrinterStatus.swift
    ├── Services/
    │   ├── BambuMQTTClient.swift      # CocoaMQTT + TLS + pushall
    │   ├── PrinterManager.swift       # 全クライアント集約
    │   └── BambuCloudSession.swift    # クラウド REST + トークン管理
    ├── Stores/
    │   └── SettingsStore.swift        # UserDefaults 永続化
    └── Views/
        ├── ContentView.swift           # メインウィンドウ
        ├── PrinterCardView.swift       # プリンタカード
        └── SettingsSheet.swift         # 設定シート (プリンタ/クラウド)
```

## 技術メモ

- LAN MQTT: `mqtts://{IP}:8883`、ユーザ `bblp` / パスワード Access Code、自己署名証明書を受容
- クラウド MQTT: `mqtts://{region}.mqtt.bambulab.com:8883`、ユーザ `u_{userID}` / パスワード accessToken
- 接続後 `device/{SERIAL}/request` に `{"pushing":{"sequence_id":"0","command":"pushall"}}` を publish して全状態を取得
- クラウド REST: `https://api.bambulab.com/v1/user-service/user/login` でログイン、`/v1/iot-service/api/user/bind` でデバイス一覧

## 参考

- 公式スライサ: https://github.com/bambulab/BambuStudio
- Bambu プロトコル調査: https://github.com/Doridian/OpenBambuAPI

## ライセンス

MIT
