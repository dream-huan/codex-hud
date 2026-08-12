#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_DIR=${CODEX_HUD_SOURCE_DIR:-$PROJECT_ROOT/.cache/codex}
PACKAGE_DIR=$PROJECT_ROOT/dist/package
PROFILE=${CODEX_HUD_PROFILE:-release}
CARGO_BIN=${CARGO:-cargo}

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "codex-hud: required command not found: $1" >&2
    exit 1
  fi
}

detect_target() {
  OS=$(uname -s)
  ARCH=$(uname -m)
  case "$OS:$ARCH" in
    Linux:x86_64) echo x86_64-unknown-linux-gnu ;;
    Linux:aarch64|Linux:arm64) echo aarch64-unknown-linux-gnu ;;
    Darwin:x86_64) echo x86_64-apple-darwin ;;
    Darwin:arm64|Darwin:aarch64) echo aarch64-apple-darwin ;;
    *)
      echo "codex-hud: unsupported build host: $OS $ARCH" >&2
      echo "Set CODEX_HUD_TARGET to a target supported by Codex's package builder." >&2
      exit 1
      ;;
  esac
}

need_command git
need_command python3
need_command node
need_command "$CARGO_BIN"

NODE_MAJOR=$(node -p "Number(process.versions.node.split('.')[0])")
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "codex-hud: Node.js 18 or newer is required (found $(node --version))" >&2
  exit 1
fi

if [ "${CODEX_HUD_SKIP_TESTS:-0}" != 1 ]; then
  node --test "$PROJECT_ROOT/renderer/statusline.test.mjs"
fi

"$SCRIPT_DIR/prepare-upstream.sh"
TARGET=${CODEX_HUD_TARGET:-$(detect_target)}

if command -v rustup >/dev/null 2>&1; then
  if ! rustup target list --installed | grep -Fx "$TARGET" >/dev/null 2>&1; then
    (cd "$SOURCE_DIR/codex-rs" && rustup target add "$TARGET")
  fi
fi

if [ -n "${CODEX_BUILD_JOBS:-}" ]; then
  export CARGO_BUILD_JOBS=$CODEX_BUILD_JOBS
fi

set -- \
  --target "$TARGET" \
  --variant codex \
  --package-dir "$PACKAGE_DIR" \
  --cargo "$CARGO_BIN" \
  --cargo-profile "$PROFILE" \
  --force

if [ -n "${CODEX_HUD_ENTRYPOINT_BIN:-}" ]; then
  set -- "$@" --entrypoint-bin "$CODEX_HUD_ENTRYPOINT_BIN"
fi
if [ -n "${CODEX_HUD_CODE_MODE_HOST_BIN:-}" ]; then
  set -- "$@" --code-mode-host-bin "$CODEX_HUD_CODE_MODE_HOST_BIN"
fi
if [ -n "${CODEX_HUD_BWRAP_BIN:-}" ]; then
  set -- "$@" --bwrap-bin "$CODEX_HUD_BWRAP_BIN"
fi
if [ -n "${CODEX_HUD_ZSH_BIN:-}" ]; then
  set -- "$@" --zsh-bin "$CODEX_HUD_ZSH_BIN"
fi
if [ -n "${CODEX_HUD_RG_BIN:-}" ]; then
  set -- "$@" --rg-bin "$CODEX_HUD_RG_BIN"
fi

python3 "$SOURCE_DIR/scripts/build_codex_package.py" "$@"

if [ "$(uname -s)" = Linux ] && [ "${CODEX_HUD_STRIP:-1}" = 1 ] && command -v strip >/dev/null 2>&1; then
  strip "$PACKAGE_DIR/bin/codex" "$PACKAGE_DIR/bin/codex-code-mode-host"
fi

echo "Built codex-hud package at $PACKAGE_DIR"
