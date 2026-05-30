# Reachy Mini × Meta Ray-Ban Display — システム・アーキテクチャ

ローカルLLMで会話するスマートグラス × ロボットの**ハンズフリーAR体験**システム。
ユーザーは Meta Ray-Ban Display を装着して目の前の Reachy Mini を見ながら、
日本語で自由に会話し、その内容がAR字幕として視界に重なる。
グラスの Neural Band 操作だけで会話を開始したり、ロボットを動かしたりできる。

---

## 1. 概要

| 項目 | 内容 |
| --- | --- |
| 目的 | 「スマートグラス × オープン卓上ロボット × ローカルLLM」を一体動作させ、AR字幕＋音声＋体動の対話を成立させる |
| 想定用途 | キャリアセンター実証実験、教育現場、学会デモ、対話AI研究 |
| 特色 | 個人情報を外部に送らない**ローカルLLM**完結／**手放しで会話開始**／**字幕＋音声＋身体動作の三位一体** |
| 完成度 | 実機で end-to-end 動作（会話・字幕表示・操作コマンド・モーション・音量制御まで） |

---

## 2. 全体構成（3層アーキテクチャ）

```
┌──────────────────────────┐      HTTPS（ポーリング 1秒）        ┌──────────────────────────┐
│  Meta Ray-Ban Display     │  ◄────────────────────────────►   │  中継サーバー（Render）     │
│  ・AR字幕（タイプ風表示）  │     /api/snapshot                 │  Node.js + Express        │
│  ・操作UI（D-pad）        │     /api/command                  │  固定URL                  │
│  ・Neural Band ジェスチャ │     ※スマホ経由のネット            │  発話のキャッシュ＋配信     │
└──────────────────────────┘                                    │  コマンドのキュー          │
                                                                  └──────────┬───────────────┘
                                                                             │ HTTPS
                                                                             ▼
              LAN（mDNS）                                          ┌──────────────────────────┐
   ┌────────────────────────────────────────────────────────────  │   Reachy Mini（実機）     │
   │                                                              │  ・USBマイク → 録音       │
   ▼                                                              │  ・reachy_link.py で      │
┌──────────────────────────┐                                      │    中継と通信             │
│  Mac（脳と声）            │                                      │  ・reachy_mini SDK で     │
│  ・Ollama（gemma4:e4b）   │ ◄────────────────────────────────── │    頭・体・アンテナ       │
│  ・VOICEVOX（TTS）        │                                      │  ・aplay でスピーカー     │
└──────────────────────────┘                                      └──────────────────────────┘
```

### 3層の役割

**表示・操作層（Meta Ray-Ban Display）**
600×600 のAR Webアプリ。グラス越しに実物Reachyを見ながら、その近くに発話テキストの吹き出しが浮かぶ。
入力は矢印＋Enter（Neural Bandのスワイプ・ピンチに対応）。
**MOVE / EMOTION / ACTION / TALK / VOLUME / STOP** のメニューでロボット操作。
最新発話はカタカタとタイプライター風に表示。

**中継層（Render・固定URL）**
Express ベースの軽量サーバー。
グラスとロボットを直接繋がず、両者の所在やネットワークに依存しない。
グラスは1秒ごとにポーリングで状態と最新発話を取得（簡易トンネルで SSE が詰まる問題への対処）。
Render の無料Webサービスにデプロイし、URLが永続化（再登録不要）。

**ロボット層（Reachy Mini）**
既存の音声会話アプリ `mini_voice.py` に `reachy_link.py` を差し込み、
中継への発話送信とコマンド受信を実装。
`reachy_mini` SDK で頭（look_at_world）・体（body_yaw）・アンテナ（antenna_joint_positions）と
公式 RecordedMove（simple_nod、ダンス）を制御。
**音声はReachy本体スピーカーから出す**（グラスは字幕のみ＝実物ロボットとの一体感を保つ要件）。

---

## 3. 会話の流れ（1ターン）

```
[ユーザー]               [グラス]            [中継]          [Reachy]                [Mac]
   │ TALK→START 押下      │                   │              │                      │
   │ ───────────────────► │ POST /api/command │              │                      │
   │                      │ {start_convers..} │ ── キュー ──►│ コマンド受信          │
   │                      │                   │              │ 録音開始(6秒)         │
   │ 話す（USBマイク）─────────────────────────────────────► │                      │
   │                      │                   │              │ Whisper STT ─────────│
   │                      │                   │              │   text "こんにちは"   │
   │                      │                   │ ◄ POST       │ ──── /api/speech ─►  │
   │                      │ ◄ snapshot ─────  │ user発話     │                      │
   │                      │ [字幕に user発話] │              │ post_state("thinking")│
   │                      │ ◄ snapshot ─────  │ THINKING     │                      │
   │                      │                   │              │ Ollama gemma4 ──────►│
   │                      │                   │              │ ◄────── 返答テキスト │
   │                      │                   │ ◄ POST       │                      │
   │                      │ ◄ snapshot ─────  │ reachy発話   │                      │
   │ ◄ [AR字幕でタイプ表示]│ SPEAKING          │              │ VOICEVOX 合成 ───────►│
   │                      │                   │              │ ◄────────── wav      │
   │ ◄ [Reachyから音声]──────────────────────────────────── │ aplay で再生          │
   │                      │                   │              │ + reachy_mini SDK で │
   │ [体・アンテナが動く] ◄───────────────────────────────── │   発話中モーション     │
   │                      │ ◄ snapshot ─────  │ IDLE         │ post_state("idle")   │
```

ポイント:
- **発話テキストは音声より先にグラスへ送る**ので、VOICEVOXが落ちていても字幕は出る（段階的劣化）。
- **コマンドはキューに入り、Reachyが1秒ポーリングで取得**。SSEを使わないので中継先の制約に強い。

---

## 4. 使用技術スタック

| 役割 | 採用技術 | 補足 |
| --- | --- | --- |
| LLM（脳） | **Ollama + gemma4:e4b** | Mac上でローカル実行。プライバシー◎・クラウドAPI非依存 |
| STT（聞き取り） | Hugging Face Whisper large-v3-turbo | 完全ローカル化（faster-whisper）も準備済み |
| TTS（音声合成） | **VOICEVOX**（四国めたん 他） | Mac上の Docker、日本語話者多数 |
| ロボット制御 | **reachy_mini SDK**（公式） | head/body/antenna、公式ダンス（RecordedMove） |
| 中継サーバー | Node.js + Express + ポーリング | **Render 無料Webサービス**（固定URL） |
| スマートグラス | Meta Ray-Ban Display + Web App | 600×600、矢印＋Enter操作、黒=透過 |
| 通信 | HTTPS（グラス↔中継）／ LAN mDNS（Reachy↔Mac） | IPが変わっても `.local` 名で解決 |
| Reachy側クライアント | `reachy_link.py`（urllibのみ・依存ゼロ） | mini_voice.py に数行差し込み |
| 操作コマンド | `reachy_moves.py`（command_motion） | look_left, nod, wave, dance, emote, volume_up/down 等を SDK 呼び出しにマップ |

---

## 5. スマートグラスとロボティクスの連携・要点

1. **三層分離**で各コンポーネントが独立 — グラスは表示と操作だけ、Reachyは会話と動きだけ、中継が両者を緩く繋ぐ。
2. **音声はロボット本体から、字幕はグラスから** — 実物の存在感を消さない設計。
3. **ハンズフリー会話開始** — グラスの `TALK→START` がReachyの `_start_turn` イベントを発火し、Enterキー不要で会話開始。
4. **コマンド ⇄ モーション直結** — グラスのボタンが reachy_mini SDK の `look_at_world` / antenna / RecordedMove などに即マップ。
5. **音量もバンドで** — VOL+/− でReachyスピーカーの `amixer` を遠隔操作。
6. **段階的劣化** — グラスや中継が落ちても、ロボット単体の会話は継続。最悪の場面で「ロボットと話せる」は守られる。
7. **URL固定（Render）** — 簡易トンネルのURL変動問題を恒久解消。グラスへの再登録不要。

---

## 6. 設計思想

- **ローカルLLMファースト**: 個人情報を扱う場（キャリア支援、教育）でも安心。クラウドAPI不要。
- **テキスト × 音声 × 体動の三位一体**: 画面チャットを超える対話感を、AR字幕・ロボットの声・身体動作の重ねがけで実現。
- **依存最小**: `reachy_link.py` は Python標準ライブラリのみ、中継は Express のみ、グラスはピュアHTML/JS。動くものを優先。
- **会場の不確実性に強く**: ネット不安定でも `.local` mDNS、URL churn の根治、wifi省電力OFFなど運用知見を内蔵。

---

## 7. 限界と今後

| 現状 | 今後 |
| --- | --- |
| 既存技術（Whisper / Ollama / VOICEVOX / reachy_mini SDK）の**統合とUX設計が新規性**。新規アルゴリズムは無い | 査読論文化には別途ユーザースタディが必要 |
| 音声と全モーションの**両立は条件付き**（reachy_mini SDK のWebRTC音声と aplay が競合） | TTS再生を SDK 経由にして恒久両立 |
| Render 無料は15分でスリープ→コールドスタート | named tunnel もしくは Render 有料化で常時応答 |
| グラス上の吹き出しは画面中央に固定 | カメラで実Reachyの位置を認識し、その真上に吹き出しを固定（**AR位置合わせ**） |
| 1台1ペア構成 | 複数台展示、複数言語字幕、ユーザー発話の字幕、リアルタイム翻訳 |

---

## 8. ソースコード構成

```
dat-link/
├── reachy/
│   ├── server.js           中継サーバー（Express、ポーリングAPI）
│   ├── public/
│   │   ├── index.html      MRBD ビューア（AR字幕・カーソル・カタカタ表示・サイバーUI）
│   │   └── control.html    スマホ用補助操作UI
│   ├── reachy_link.py      Reachy側クライアント（標準ライブラリのみ）
│   └── reachy_moves.py     ボタン → モーション マッピング（接続シングルトンでFD保護）
├── render.yaml             Render デプロイ設定（固定URL）
└── .claude/skills/         再現用スキル（reachy-voice-chat / -glass-link / -venue-deploy）
```

中継URL（運用中の固定アドレス）: `https://reachy-relay.onrender.com`

---

## 9. 一行サマリー

> **Meta Ray-Ban Display × Reachy Mini × ローカルLLM（Gemma 4）を、HTTPSポーリングの三層アーキテクチャで結合し、AR字幕＋ロボット音声＋身体動作の同期対話を、会場ネットの揺らぎにも耐える形で end-to-end 実装したシステム。**
