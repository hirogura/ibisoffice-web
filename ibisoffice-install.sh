#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ibisOffice Web版セルフホスト用インストールスクリプト.
#
#   1. ビルド環境がなければ導入 (build-essential, curl, git, unzip, rustup stable, wasm32 target, wasm-bindgen-cli, node/npm)
#      node/npm はディストリ版で依存競合する場合は NodeSource (Node 22 LTS) にフォールバック
#   2. https://github.com/ibisjp/ibis-office.git を取得 (既存なら submodule 更新)
#   3. scripts/build-web.sh 相当の手順で www/ をビルド (wasm + tsc + assets)
#   4. 成果物を public-ibisoffice/ に配置し, 3367番ポートで静的配信 (COOP/COEP付き)
#
# Usage:
#   ./ibisoffice-install.sh [--port 3367] [--skip-build] [--no-serve]
#
# Env:
#   PORT                 配信ポート (default: 3367)
#   SKIP_BUILD=1         ビルドを飛ばして配信だけやり直す
#   NO_SERVE=1           配信(起動)をしない
#
# メモ (実機検証済み 2026-10-18):
#   stable でも wasm_thread Crate が #![feature] を使うため RUSTC_BOOTSTRAP=1 が必要.
#   wasm-bindgen-cli のバージョンは Cargo.lock の wasm-bindgen と一致させる (現行 0.2.128).
#   配信は SharedArrayBuffer 用に COOP/COEP ヘッダ必須 (serve-ibisoffice.py).
set -euo pipefail

PORT="${PORT:-3367}"
SKIP_BUILD="${SKIP_BUILD:-0}"
NO_SERVE="${NO_SERVE:-0}"
WASM_BINDGEN_VERSION="0.2.128"

for arg in "$@"; do
  case "$arg" in
    --port=*) PORT="${arg#--port=}" ;;
    --port) shift_arg=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --no-serve) NO_SERVE=1 ;;
    --help|-h)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      if [ "${shift_arg:-0}" = "1" ]; then
        PORT="$arg"
        shift_arg=0
      else
        echo "error: unknown arg: $arg (see --help)" >&2
        exit 1
      fi
      ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT/ibis-office"
PUBLIC_DIR="$ROOT/public-ibisoffice"
REPO_URL="https://github.com/ibisjp/ibis-office.git"

log() { echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"

install_node_npm() {
  if have node && have npm; then
    log "node/npm 済み: $(node --version) / $(npm --version)"
    return 0
  fi
  # ディストリ版を試す. NodeSource などサードパーティリポジトリが入っていると
  # nodejs/npm の依存解決で競合するため失敗しても即死させず段階的に進める.
  log "nodejs / npm を導入 (ディストリ版)"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm; then
    log "一括導入に失敗したため分割で再試行"
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y npm || true
  fi
  if have node && have npm; then
    log "node/npm 導入: $(node --version) / $(npm --version)"
    return 0
  fi
  # フォールバック: NodeSource (Node 22 LTS). NodeSource 版は npm を同梱する.
  log "ディストリ版で揃わないため NodeSource (Node 22 LTS) にフォールバック"
  curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh
  DEBIAN_FRONTEND=noninteractive bash /tmp/nodesource_setup.sh
  rm -f /tmp/nodesource_setup.sh
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  have node && have npm || {
    echo "error: node/npm の導入に失敗しました (手動で Node.js LTS を導入してください)" >&2
    exit 1
  }
  log "node/npm 導入: $(node --version) / $(npm --version)"
}

install_system_deps() {
  if ! have apt-get; then
    log "apt-get がないためシステム依存の自動導入をスキップ"
    return 0
  fi
  apt-get update
  log "基本依存を導入"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential pkg-config curl ca-certificates python3 git unzip
  install_node_npm

  local need=(gcc make pkg-config curl python3 git node npm unzip)
  local lack=()
  for c in "${need[@]}"; do
    have "$c" || lack+=("$c")
  done
  if [ "${#lack[@]}" -ne 0 ]; then
    echo "error: 必要なコマンドが揃いません: ${lack[*]}" >&2
    exit 1
  fi
  log "システム依存は充足済み"
}

install_rust() {
  if have cargo && have rustc; then
    log "Rust 済み: $(rustc --version)"
  else
    log "rustup 経由で Rust stable を導入"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile default
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  log "wasm32-unknown-unknown target を確保"
  rustup target add wasm32-unknown-unknown
}

# Cargo.lock の wasm-bindgen と同じ版の CLI を導入 (コンパイル不要の公式バイナリ).
install_wasm_bindgen() {
  if have wasm-bindgen && wasm-bindgen --version | grep -q "wasm-bindgen ${WASM_BINDGEN_VERSION}"; then
    log "wasm-bindgen 済み: $(wasm-bindgen --version)"
    return 0
  fi
  local version url
  version="$(sed -n '/name = "wasm-bindgen"/,+2p' "$SRC_DIR/Cargo.lock" | sed -n 's/version = "\(.*\)"/\1/p')"
  [ -n "$version" ] || version="$WASM_BINDGEN_VERSION"
  log "Cargo.lock の wasm-bindgen 版: $version"
  local arch target
  arch="$(uname -m)"
  case "$arch" in
    x86_64) target="x86_64-unknown-linux-musl" ;;
    aarch64) target="aarch64-unknown-linux-musl" ;;
    *) echo "error: 未対応アーキテクチャ: $arch" >&2; exit 1 ;;
  esac
  url="https://github.com/rustwasm/wasm-bindgen/releases/download/${version}/wasm-bindgen-${version}-${target}.tar.gz"
  local tmpdir
  tmpdir="$(mktemp -d)"
  if curl -sL "$url" -o "$tmpdir/wbg.tar.gz" \
    && tar xzf "$tmpdir/wbg.tar.gz" -C "$tmpdir" \
    && [ -x "$tmpdir/wasm-bindgen-${version}-${target}/wasm-bindgen" ]; then
    install -m 0755 "$tmpdir/wasm-bindgen-${version}-${target}/wasm-bindgen" /usr/local/bin/wasm-bindgen 2>/dev/null \
      || { mkdir -p "$HOME/.cargo/bin"; install -m 0755 "$tmpdir/wasm-bindgen-${version}-${target}/wasm-bindgen" "$HOME/.cargo/bin/wasm-bindgen"; }
    rm -rf "$tmpdir"
    export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"
    log "wasm-bindgen 導入: $(wasm-bindgen --version)"
  else
    rm -rf "$tmpdir"
    log "バイナリ取得に失敗したため cargo install にフォールバック (数分かかります)"
    cargo install wasm-bindgen-cli --version "$version" --locked
  fi
}

fetch_src() {
  if [ -d "$SRC_DIR/.git" ]; then
    log "ibis-office 既存のため pull で更新"
    (cd "$SRC_DIR" && git pull --ff-only) || true
    (cd "$SRC_DIR" && git submodule update --init --recursive)
  elif [ -d "$SRC_DIR" ]; then
    echo "error: $SRC_DIR が存在しますが git リポジトリではありません" >&2
    exit 1
  else
    log "ibis-office を clone (submodule 含む)"
    git clone --recurse-submodules "$REPO_URL" "$SRC_DIR"
  fi
}

build_web() {
  if [ "$SKIP_BUILD" = "1" ]; then
    log "ビルドをスキップ (--skip-build)"
    return 0
  fi
  cd "$SRC_DIR"

  # tsc (TypeScript) が無ければ npm ci
  if [ ! -x node_modules/.bin/tsc ]; then
    log "npm ci (tsc 用)"
    npm ci
  fi

  # wasm 本体ビルド (build-web.sh の手順どおり).
  # stable のまま wasm_thread を通すため RUSTC_BOOTSTRAP=1 が必要.
  local remap="--remap-path-prefix=$HOME/.cargo/registry/src=crates.io --remap-path-prefix=$HOME/.cargo/git/checkouts=git --remap-path-prefix=$HOME/.rustup=rustup --remap-path-prefix=$(pwd)=."
  local profile=release flags=(--release)
  log "cargo rustc (wasm32) --release ... 初回は1〜2時間かかります (8核/メモリ7GB で実測)"
  RUSTC_BOOTSTRAP=1 RUSTFLAGS="$remap" CARGO_TARGET_DIR=target/dist \
    cargo rustc -p ibis-office-app --lib --crate-type cdylib \
    --target wasm32-unknown-unknown "${flags[@]+"${flags[@]}"}" \
    -- -C link-arg=-zstack-size=8388608

  local wasm="target/dist/wasm32-unknown-unknown/release/ibis_office_app.wasm"
  [ -f "$wasm" ] || { echo "error: $wasm がありません" >&2; exit 1; }

  log "wasm-bindgen で JS グルー生成"
  wasm-bindgen "$wasm" --out-dir www/pkg --target web

  # ビルド時間短縮のため wasm-opt は任意 (あれば最適化)
  if command -v wasm-opt >/dev/null 2>&1; then
    log "wasm-opt -Oz"
    wasm-opt -Oz --enable-bulk-memory --enable-nontrapping-float-to-int \
      www/pkg/ibis_office_app_bg.wasm -o www/pkg/ibis_office_app_bg.wasm
  fi

  # 進捗バー用に圧縮前サイズを保存 (build-web.sh と同じ仕様)
  stat -c %s www/pkg/ibis_office_app_bg.wasm > www/pkg/ibis_office_app_bg.wasm.size

  log "tsc で www の TypeScript をビルド"
  node_modules/.bin/tsc -p www

  # アイコン (cargo metadata から gpui-kit-assets を探す)
  local assets_dir
  assets_dir="$(cargo metadata --format-version 1 | python3 -c '
import json, os, sys
meta = json.load(sys.stdin)
pkg = next(p for p in meta["packages"] if p["name"] == "gpui-kit-assets")
print(os.path.join(os.path.dirname(pkg["manifest_path"]), "assets"))')"
  mkdir -p www/assets
  rm -rf www/assets/icons
  cp -R "$assets_dir/icons" www/assets/icons

  # ECMA-376 アートボーダー素材
  rm -rf www/assets/artborders
  mkdir -p www/assets/artborders
  unzip -q -o crates/ibis-office-app/data/artborders/OfficeOpenXML-WordprocessingMLArtBorders.zip -d www/assets/artborders
  cp crates/ibis-office-app/data/artborders/ECMA-NOTICE.txt www/assets/artborders/

  log "ビルド完了: $SRC_DIR/www/"
}

deploy_public() {
  log "成果物を $PUBLIC_DIR に配置 (3367番配信の実体)"
  mkdir -p "$PUBLIC_DIR"
  cp -a "$SRC_DIR/www/." "$PUBLIC_DIR"/
  [ -f "$PUBLIC_DIR/index.html" ] || { echo "error: 配置に失敗" >&2; exit 1; }
  [ -f "$PUBLIC_DIR/pkg/ibis_office_app_bg.wasm" ] || { echo "error: wasm の配置に失敗" >&2; exit 1; }
}

serve() {
  if [ "$NO_SERVE" = "1" ]; then
    log "配信をスキップ (--no-serve)"
    return 0
  fi
  # 既に systemd unit で同ポート配信中ならそれを再利用 (二重起動しない)
  if [ "$(systemctl is-active ibisoffice-web.service 2>/dev/null)" = "active" ]; then
    log "systemd unit (ibisoffice-web.service) が稼働中のため配信はそこで継続 (port ${PORT})"
    if curl -sI "http://localhost:${PORT}/" | head -1 | grep -q "200"; then
      log "疎通OK: curl -I http://localhost:${PORT}/ -> 200"
      return 0
    fi
    echo "error: systemd unit は active だが応答がありません. journalctl -u ibisoffice-web.service を確認" >&2
    exit 1
  fi
  if [ -x /usr/bin/systemctl ] && [ -f /etc/systemd/system/ibisoffice-web.service ]; then
    log "systemd unit で配信 (永続化)"
    systemctl daemon-reload
    systemctl enable --now ibisoffice-web.service
    sleep 2
  else
    # 既存の同ポート配信があれば止める (二重起動防止)
    if have fuser; then
      fuser -k "${PORT}/tcp" 2>/dev/null || true
      sleep 1
    fi
    log "配信開始: 127.0.0.1:${PORT} -> $PUBLIC_DIR (COOP/COEP ヘッダ付き)"
    nohup python3 "$ROOT/serve-ibisoffice.py" "$PORT" "$PUBLIC_DIR" \
      >>/tmp/ibisoffice-serve.log 2>&1 &
    sleep 2
  fi
  if curl -sI "http://localhost:${PORT}/" | head -1 | grep -q "200"; then
    log "疎通OK: curl -I http://localhost:${PORT}/ -> 200"
  else
    echo "error: http://localhost:${PORT}/ に応答がありません. /tmp/ibisoffice-serve.log を確認" >&2
    tail -20 /tmp/ibisoffice-serve.log >&2 || true
    exit 1
  fi
}

# リモートから開くため tailscale serve で HTTPS 公開 (tailscale があれば).
setup_tailscale() {
  if [ "$NO_SERVE" = "1" ]; then
    return 0
  fi
  if ! have tailscale; then
    log "tailscale がないため HTTPS 公開設定をスキップ (ローカルのみで配信)"
    return 0
  fi
  # 既に同一 https ポートの登録があれば再設定しない (ステータス行例: https://<host>:<port> (tailnet only))
  if tailscale serve status 2>/dev/null | grep -qE "^https://[^ ]*:${PORT}( |$|\()"; then
    log "tailscale serve 済み: $(tailscale serve status 2>/dev/null | grep ":${PORT}" | head -1)"
    return 0
  fi
  if tailscale serve --bg "--https=${PORT}" "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
    log "tailscale serve 設定: $(tailscale serve status 2>/dev/null | grep ":${PORT}" | head -1) (tailnet 内のみ)"
  else
    log "tailscale serve の設定に失敗しました (ローカル配信は継続します). 手動実行例: tailscale serve --bg --https=${PORT} http://127.0.0.1:${PORT}"
  fi
}

main() {
  log "ROOT=$ROOT SRC_DIR=$SRC_DIR PORT=$PORT"
  if [ "$SKIP_BUILD" = "0" ] || [ "$NO_SERVE" = "0" ]; then
    install_system_deps
  fi
  if [ "$SKIP_BUILD" != "1" ]; then
    install_rust
    fetch_src
    install_wasm_bindgen
    build_web
    deploy_public
  fi
  serve
  setup_tailscale
  log "完了: (1) ローカルなら http://localhost:${PORT} (2) リモートなら tailscale serve の HTTPS (tailscale serve status で URL 確認) でお開きください (WebGPU対応ブラウザ: Chrome / Edge / Safari 26+)"
}

main
