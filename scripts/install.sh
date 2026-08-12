#!/bin/sh
set -eu

REPOSITORY=${CODEX_HUD_REPOSITORY:-dream-huan/codex-hud}
VERSION=${CODEX_HUD_VERSION:-latest}
DATA_DIR=${CODEX_HUD_DATA_DIR:-${XDG_DATA_HOME:-"$HOME/.local/share"}/codex-hud}
BIN_DIR=${CODEX_HUD_BIN_DIR:-"$HOME/.local/bin"}
CONFIG_DIR=${XDG_CONFIG_HOME:-"$HOME/.config"}/codex-hud
LINK=$BIN_DIR/codex-hud
FORCE=${CODEX_HUD_FORCE:-0}

usage() {
  echo "Usage: $0 [--force]" >&2
  echo "Set CODEX_HUD_VERSION=vX.Y.Z to install a specific release." >&2
}

if [ "${1:-}" = --force ]; then
  FORCE=1
  shift
fi
if [ "$#" -ne 0 ]; then
  usage
  exit 2
fi

case "$DATA_DIR" in
  ""|/|"$HOME"|"$HOME/.local"|"$HOME/.local/share")
    echo "codex-hud: refusing unsafe data directory: $DATA_DIR" >&2
    exit 1
    ;;
esac
DATA_PARENT=$(dirname -- "$DATA_DIR")
DATA_NAME=$(basename -- "$DATA_DIR")
case "$DATA_NAME" in
  ""|.|..)
    echo "codex-hud: refusing unsafe data directory: $DATA_DIR" >&2
    exit 1
    ;;
esac
mkdir -p "$DATA_PARENT"
DATA_PARENT=$(CDPATH= cd -P -- "$DATA_PARENT" && pwd)
DATA_DIR=$DATA_PARENT/$DATA_NAME
case "$DATA_DIR" in
  /|"$HOME"|"$HOME/.local"|"$HOME/.local/share")
    echo "codex-hud: refusing unsafe data directory: $DATA_DIR" >&2
    exit 1
    ;;
esac
INSTALLED_LAUNCHER=$DATA_DIR/bin/codex-hud

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "codex-hud: required command not found: $1" >&2
    exit 1
  fi
}

download() {
  DOWNLOAD_URL=$1
  DOWNLOAD_PATH=$2
  ATTEMPT=1
  while ! curl -fsSL -o "$DOWNLOAD_PATH" "$DOWNLOAD_URL"; do
    if [ "$ATTEMPT" -ge 4 ]; then
      echo "codex-hud: download failed after $ATTEMPT attempts: $DOWNLOAD_URL" >&2
      return 1
    fi
    ATTEMPT=$((ATTEMPT + 1))
    echo "Download interrupted; retrying ($ATTEMPT/4)..." >&2
    sleep 2
  done
}

detect_target() {
  OS=$(uname -s)
  ARCH=$(uname -m)
  case "$OS:$ARCH" in
    Linux:x86_64|Linux:amd64) echo x86_64-unknown-linux-gnu ;;
    *)
      echo "codex-hud: no prebuilt release for $OS $ARCH" >&2
      echo "Build from source with scripts/build.sh, then set CODEX_HUD_PACKAGE_SOURCE." >&2
      exit 1
      ;;
  esac
}

need_command node
NODE_MAJOR=$(node -p "Number(process.versions.node.split('.')[0])")
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "codex-hud: Node.js 18 or newer is required (found $(node --version))" >&2
  exit 1
fi

if [ -e "$LINK" ] || [ -L "$LINK" ]; then
  EXISTING_TARGET=
  if [ -L "$LINK" ]; then
    EXISTING_TARGET=$(readlink "$LINK")
  fi
  if [ "$EXISTING_TARGET" != "$INSTALLED_LAUNCHER" ] && [ "$FORCE" != 1 ]; then
    echo "codex-hud: refusing to replace existing $LINK" >&2
    echo "Move it first, or rerun with --force." >&2
    exit 1
  fi
fi

TMP_DIR=$(mktemp -d "$DATA_PARENT/.codex-hud-install.XXXXXX")
cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM
STAGE_DIR=$TMP_DIR/stage
mkdir -p "$STAGE_DIR"

if [ -n "${CODEX_HUD_PACKAGE_SOURCE:-}" ]; then
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
  case "$CODEX_HUD_PACKAGE_SOURCE" in
    /*) PACKAGE_SOURCE=$CODEX_HUD_PACKAGE_SOURCE ;;
    *) PACKAGE_SOURCE=$(CDPATH= cd -- "$(dirname -- "$CODEX_HUD_PACKAGE_SOURCE")" && pwd)/$(basename -- "$CODEX_HUD_PACKAGE_SOURCE") ;;
  esac
  if [ ! -x "$PACKAGE_SOURCE/bin/codex" ]; then
    echo "codex-hud: local package is missing $PACKAGE_SOURCE/bin/codex" >&2
    exit 1
  fi
  mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/config" "$STAGE_DIR/renderer" "$STAGE_DIR/scripts"
  cp -R "$PACKAGE_SOURCE" "$STAGE_DIR/package"
  install -m 0755 "$PROJECT_ROOT/bin/codex-hud" "$STAGE_DIR/bin/codex-hud"
  install -m 0755 "$PROJECT_ROOT/renderer/statusline.mjs" "$STAGE_DIR/renderer/statusline.mjs"
  install -m 0644 "$PROJECT_ROOT/config/config.json" "$STAGE_DIR/config/config.json"
  install -m 0755 "$PROJECT_ROOT/scripts/install.sh" "$STAGE_DIR/scripts/install.sh"
  install -m 0755 "$PROJECT_ROOT/scripts/uninstall.sh" "$STAGE_DIR/scripts/uninstall.sh"
  install -m 0644 "$PROJECT_ROOT/LICENSE" "$STAGE_DIR/LICENSE"
  install -m 0644 "$PROJECT_ROOT/NOTICE" "$STAGE_DIR/NOTICE"
  printf '%s\n' local > "$STAGE_DIR/VERSION"
else
  need_command curl
  need_command tar
  need_command sha256sum
  TARGET=${CODEX_HUD_TARGET:-$(detect_target)}
  ASSET=codex-hud-$TARGET.tar.gz
  if [ -n "${CODEX_HUD_DOWNLOAD_BASE_URL:-}" ]; then
    DOWNLOAD_ROOT=${CODEX_HUD_DOWNLOAD_BASE_URL%/}
  elif [ "$VERSION" = latest ]; then
    DOWNLOAD_ROOT=https://github.com/$REPOSITORY/releases/latest/download
  else
    DOWNLOAD_ROOT=https://github.com/$REPOSITORY/releases/download/$VERSION
  fi

  echo "Downloading codex-hud ${VERSION} for ${TARGET}..."
  download "$DOWNLOAD_ROOT/$ASSET" "$TMP_DIR/$ASSET"
  download "$DOWNLOAD_ROOT/$ASSET.sha256" "$TMP_DIR/$ASSET.sha256"
  (cd "$TMP_DIR" && sha256sum -c "$ASSET.sha256")
  tar --no-same-owner -xzf "$TMP_DIR/$ASSET" -C "$STAGE_DIR"
  chmod 0755 "$STAGE_DIR"
fi

for REQUIRED in \
  bin/codex-hud \
  package/bin/codex \
  renderer/statusline.mjs \
  config/config.json \
  scripts/install.sh \
  scripts/uninstall.sh
do
  if [ ! -e "$STAGE_DIR/$REQUIRED" ]; then
    echo "codex-hud: release is missing $REQUIRED" >&2
    exit 1
  fi
done

mkdir -p "$BIN_DIR" "$CONFIG_DIR"
if [ -e "$DATA_DIR" ] || [ -L "$DATA_DIR" ]; then
  mv "$DATA_DIR" "$TMP_DIR/previous"
fi
if ! mv "$STAGE_DIR" "$DATA_DIR"; then
  if [ -e "$TMP_DIR/previous" ] || [ -L "$TMP_DIR/previous" ]; then
    mv "$TMP_DIR/previous" "$DATA_DIR"
  fi
  exit 1
fi
if [ -e "$TMP_DIR/previous" ] || [ -L "$TMP_DIR/previous" ]; then
  rm -rf -- "$TMP_DIR/previous"
fi

if [ ! -e "$CONFIG_DIR/config.json" ]; then
  install -m 0644 "$DATA_DIR/config/config.json" "$CONFIG_DIR/config.json"
fi
if [ "$FORCE" = 1 ] && { [ -e "$LINK" ] || [ -L "$LINK" ]; }; then
  rm -f -- "$LINK"
fi
ln -sfn "$INSTALLED_LAUNCHER" "$LINK"

echo "Installed codex-hud at $LINK"
echo "Runtime files: $DATA_DIR"
echo "User config: $CONFIG_DIR/config.json"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Add $BIN_DIR to PATH before running codex-hud." ;;
esac
