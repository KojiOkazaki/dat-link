# dat-link

Reachy Mini を Mac に接続して使うための初期化ツール。

## Reachy Mini (Lite) を Mac で初期化する

`scripts/setup_reachy_mini_mac.sh` を実行すると、以下を一括でセットアップします。

1. Homebrew (未インストールの場合)
2. `git` / `git-lfs`
3. `uv` (高速な Python パッケージマネージャ)
4. Python 3.12
5. 仮想環境 `~/reachy_mini_env`
6. `reachy-mini` パッケージ
7. USB 接続確認 & `reachy_mini` import 確認

### 使い方

Mac の **ターミナル** (`Cmd + Space` → `Terminal`) で:

```bash
git clone https://github.com/KojiOkazaki/dat-link.git
cd dat-link
chmod +x scripts/setup_reachy_mini_mac.sh
./scripts/setup_reachy_mini_mac.sh
```

### オプション

| オプション         | 説明                                                |
| ------------------ | --------------------------------------------------- |
| `--with-mujoco`    | MuJoCo シミュレーション用の extra も一緒にインストール |
| `--dev`            | `pollen-robotics/reachy_mini` を clone して `uv sync` |
| `--venv-dir DIR`   | venv 作成先 (デフォルト: `~/reachy_mini_env`)        |
| `--python VER`     | Python バージョン (デフォルト: 3.12)                 |

例:

```bash
# シミュレーションも使う
./scripts/setup_reachy_mini_mac.sh --with-mujoco

# 開発者モード (SDK のソースを編集したい場合)
./scripts/setup_reachy_mini_mac.sh --dev --with-mujoco
```

### セットアップ後の使い方

```bash
# 仮想環境を有効化
source ~/reachy_mini_env/bin/activate

# 接続テスト (Reachy Mini Lite を USB 接続した状態で)
python -c "from reachy_mini import ReachyMini; \
with ReachyMini() as m: print('connected')"
```

### 事前準備 (ハードウェア)

Reachy Mini **Lite** の場合:

1. 付属の AC アダプタで本体に給電
2. USB-C ケーブルで Mac と接続

### 参考

- 公式インストールガイド: <https://huggingface.co/docs/reachy_mini/SDK/installation>
- Reachy Mini Lite セットアップ: <https://huggingface.co/docs/reachy_mini/platforms/reachy_mini_lite/get_started>
- SDK リポジトリ: <https://github.com/pollen-robotics/reachy_mini>
- Seeed Studio (日本語): <https://wiki.seeedstudio.com/ja/reachymini_sdk_installation/>
