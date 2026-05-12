#!/usr/bin/env bash
#
# Reachy Mini (Lite) を macOS で初期化するためのセットアップスクリプト
#
# 公式ドキュメント:
#   https://huggingface.co/docs/reachy_mini/SDK/installation
#   https://huggingface.co/docs/reachy_mini/platforms/reachy_mini_lite/get_started
#
# 実行方法:
#   chmod +x scripts/setup_reachy_mini_mac.sh
#   ./scripts/setup_reachy_mini_mac.sh
#
# オプション:
#   --with-mujoco   MuJoCo シミュレーション用の extra も一緒にインストール
#   --dev           reachy_mini リポジトリを git clone して `uv sync` で開発環境を構築
#   --venv-dir DIR  venv 作成先 (デフォルト: $HOME/reachy_mini_env)
#   --python VER    Python バージョン (デフォルト: 3.12, サポート: 3.10 - 3.12)

set -euo pipefail

WITH_MUJOCO=0
DEV_MODE=0
VENV_DIR="${HOME}/reachy_mini_env"
PYTHON_VERSION="3.12"
WORK_DIR="${HOME}/reachy_mini"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-mujoco) WITH_MUJOCO=1; shift ;;
    --dev) DEV_MODE=1; shift ;;
    --venv-dir) VENV_DIR="$2"; shift 2 ;;
    --python) PYTHON_VERSION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log()  { printf "\033[1;34m[setup]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m  %s\n" "$*"; }
err()  { printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; }

# ──────────────────────────────────────────────────────────────
# 0. プラットフォームチェック
# ──────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "このスクリプトは macOS 専用です (検出: $(uname -s))"
  exit 1
fi

ARCH="$(uname -m)"
log "macOS ${ARCH} を検出しました"

# ──────────────────────────────────────────────────────────────
# 1. Homebrew のインストール
# ──────────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  log "Homebrew が見つかりません。インストールを開始します"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ "${ARCH}" == "arm64" ]]; then
    if ! grep -q '/opt/homebrew/bin/brew shellenv' "${HOME}/.zprofile" 2>/dev/null; then
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "${HOME}/.zprofile"
    fi
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
else
  log "Homebrew は既にインストール済み: $(brew --version | head -n1)"
fi

# ──────────────────────────────────────────────────────────────
# 2. Git / Git LFS
# ──────────────────────────────────────────────────────────────
log "git / git-lfs をインストール"
brew install git git-lfs
git lfs install

# ──────────────────────────────────────────────────────────────
# 3. uv のインストール
# ──────────────────────────────────────────────────────────────
if ! command -v uv >/dev/null 2>&1; then
  log "uv をインストール"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # 現在のシェルから使えるように PATH を通す
  export PATH="${HOME}/.local/bin:${PATH}"
fi
log "uv バージョン: $(uv --version)"

# ──────────────────────────────────────────────────────────────
# 4. Python のインストール
# ──────────────────────────────────────────────────────────────
log "Python ${PYTHON_VERSION} をインストール"
uv python install "${PYTHON_VERSION}" --default

# ──────────────────────────────────────────────────────────────
# 5. 仮想環境の作成
# ──────────────────────────────────────────────────────────────
if [[ ${DEV_MODE} -eq 1 ]]; then
  # 開発モード: reachy_mini を clone し、uv sync で同期
  log "開発モード: reachy_mini を ${WORK_DIR} に clone"
  if [[ ! -d "${WORK_DIR}" ]]; then
    git clone https://github.com/pollen-robotics/reachy_mini "${WORK_DIR}"
  else
    log "${WORK_DIR} は既に存在します。git pull で更新"
    git -C "${WORK_DIR}" pull --ff-only
  fi

  cd "${WORK_DIR}"
  if [[ ${WITH_MUJOCO} -eq 1 ]]; then
    uv sync --extra mujoco
  else
    uv sync
  fi
  ACTIVATE_CMD="cd ${WORK_DIR} && source .venv/bin/activate"
else
  # 通常モード: 独立した venv に pip install
  log "仮想環境を作成: ${VENV_DIR}"
  uv venv "${VENV_DIR}" --python "${PYTHON_VERSION}"

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"

  log "reachy-mini パッケージをインストール"
  if [[ ${WITH_MUJOCO} -eq 1 ]]; then
    uv pip install "reachy-mini[mujoco]"
  else
    uv pip install "reachy-mini"
  fi
  ACTIVATE_CMD="source ${VENV_DIR}/bin/activate"
fi

# ──────────────────────────────────────────────────────────────
# 6. USB 接続の確認 (Reachy Mini Lite)
# ──────────────────────────────────────────────────────────────
log "USB デバイスを確認 (Reachy Mini Lite の USB-シリアル変換チップ)"
# 1a86:55d3 = WCH CH343, 38fb:1001 = Reachy Mini USB-Serial
if system_profiler SPUSBDataType 2>/dev/null | grep -E -i "0x1a86|0x38fb|reachy|CH343|CH9102" >/dev/null; then
  log "Reachy Mini らしき USB デバイスを検出しました"
  system_profiler SPUSBDataType | grep -E -i -A2 "0x1a86|0x38fb|reachy|CH343|CH9102" || true
else
  warn "Reachy Mini の USB デバイスが見つかりません"
  warn "  - USB-C ケーブルが Mac と Reachy Mini に正しく接続されているか"
  warn "  - 電源アダプタがコンセントに接続されているか"
  warn "  を確認してください"
fi

# ──────────────────────────────────────────────────────────────
# 7. SDK が import できるか確認
# ──────────────────────────────────────────────────────────────
log "Python から reachy_mini を import できるかテスト"
python - <<'PY'
import importlib, sys
mod = importlib.import_module("reachy_mini")
print(f"  reachy_mini OK (path = {mod.__file__})")
PY

# ──────────────────────────────────────────────────────────────
# 完了
# ──────────────────────────────────────────────────────────────
cat <<EOF

────────────────────────────────────────────────────────────
✅ Reachy Mini のセットアップが完了しました
────────────────────────────────────────────────────────────

次回ターミナルを開いたら、まず仮想環境を有効化してください:

    ${ACTIVATE_CMD}

▼ 接続テスト (Reachy Mini Lite を USB 接続した状態で):

    python -c "from reachy_mini import ReachyMini; \\
ReachyMini().__enter__(); print('connected')"

▼ サンプルを動かす:

    git clone https://github.com/pollen-robotics/reachy_mini.git
    cd reachy_mini/examples
    python hello_world.py

▼ デスクトップアプリ (Reachy Mini Control) を使う場合:
    https://hf.co/reachy-mini/#/download からダウンロード

ドキュメント:
  - https://huggingface.co/docs/reachy_mini/SDK/installation
  - https://huggingface.co/docs/reachy_mini/SDK/quickstart
────────────────────────────────────────────────────────────
EOF
