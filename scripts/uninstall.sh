#!/bin/sh
set -eu

DATA_DIR=${CODEX_HUD_DATA_DIR:-${XDG_DATA_HOME:-"$HOME/.local/share"}/codex-hud}
BIN_DIR=${CODEX_HUD_BIN_DIR:-"$HOME/.local/bin"}
CONFIG_DIR=${XDG_CONFIG_HOME:-"$HOME/.config"}/codex-hud
LINK=$BIN_DIR/codex-hud
INSTALLED_LAUNCHER=$DATA_DIR/bin/codex-hud
PURGE=0

if [ "${1:-}" = --purge ]; then
  PURGE=1
elif [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--purge]" >&2
  exit 2
fi

case "$DATA_DIR" in
  ""|/|"$HOME"|"$HOME/.local"|"$HOME/.local/share")
    echo "codex-hud: refusing unsafe data directory: $DATA_DIR" >&2
    exit 1
    ;;
esac

if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$INSTALLED_LAUNCHER" ]; then
  rm -f -- "$LINK"
fi
if [ -e "$DATA_DIR" ]; then
  rm -rf -- "$DATA_DIR"
fi

if [ "$PURGE" -eq 1 ]; then
  case "$CONFIG_DIR" in
    ""|/|"$HOME"|"$HOME/.config")
      echo "codex-hud: refusing unsafe config directory: $CONFIG_DIR" >&2
      exit 1
      ;;
  esac
  if [ -e "$CONFIG_DIR" ]; then
    rm -rf -- "$CONFIG_DIR"
  fi
fi

echo "Removed codex-hud runtime files."
if [ "$PURGE" -eq 0 ]; then
  echo "Preserved user config at $CONFIG_DIR/config.json"
fi
