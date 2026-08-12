#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PACKAGE_SOURCE=$PROJECT_ROOT/dist/package
DATA_DIR=${CODEX_HUD_DATA_DIR:-${XDG_DATA_HOME:-"$HOME/.local/share"}/codex-hud}
BIN_DIR=${CODEX_HUD_BIN_DIR:-"$HOME/.local/bin"}
CONFIG_DIR=${XDG_CONFIG_HOME:-"$HOME/.config"}/codex-hud
LINK=$BIN_DIR/codex-hud
INSTALLED_LAUNCHER=$DATA_DIR/bin/codex-hud

case "$DATA_DIR" in
  ""|/|"$HOME"|"$HOME/.local"|"$HOME/.local/share")
    echo "codex-hud: refusing unsafe data directory: $DATA_DIR" >&2
    exit 1
    ;;
esac

if [ ! -x "$PACKAGE_SOURCE/bin/codex" ]; then
  "$SCRIPT_DIR/build.sh"
fi

if [ -e "$LINK" ] || [ -L "$LINK" ]; then
  EXISTING_TARGET=
  if [ -L "$LINK" ]; then
    EXISTING_TARGET=$(readlink "$LINK")
  fi
  if [ "$EXISTING_TARGET" != "$INSTALLED_LAUNCHER" ]; then
    if [ "${CODEX_HUD_FORCE:-0}" != 1 ]; then
      echo "codex-hud: refusing to replace existing $LINK" >&2
      echo "Move it first, or rerun with CODEX_HUD_FORCE=1." >&2
      exit 1
    fi
    rm -f -- "$LINK"
  fi
fi

mkdir -p "$DATA_DIR/bin" "$DATA_DIR/renderer" "$DATA_DIR/config" "$BIN_DIR" "$CONFIG_DIR"
if [ -e "$DATA_DIR/package" ]; then
  rm -rf -- "$DATA_DIR/package"
fi
mkdir -p "$DATA_DIR/package"
cp -R "$PACKAGE_SOURCE/." "$DATA_DIR/package/"
install -m 0755 "$PROJECT_ROOT/bin/codex-hud" "$INSTALLED_LAUNCHER"
install -m 0755 "$PROJECT_ROOT/renderer/statusline.mjs" "$DATA_DIR/renderer/statusline.mjs"
install -m 0644 "$PROJECT_ROOT/config/config.json" "$DATA_DIR/config/config.json"

if [ ! -e "$CONFIG_DIR/config.json" ]; then
  install -m 0644 "$PROJECT_ROOT/config/config.json" "$CONFIG_DIR/config.json"
fi

ln -sfn "$INSTALLED_LAUNCHER" "$LINK"

echo "Installed codex-hud at $LINK"
echo "Runtime files: $DATA_DIR"
echo "User config: $CONFIG_DIR/config.json"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Add $BIN_DIR to PATH before running codex-hud." ;;
esac
