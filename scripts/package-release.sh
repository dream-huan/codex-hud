#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PACKAGE_SOURCE=${CODEX_HUD_PACKAGE_SOURCE:-$PROJECT_ROOT/dist/package}
OUTPUT_DIR=${CODEX_HUD_RELEASE_DIR:-$PROJECT_ROOT/dist/release}
VERSION=${CODEX_HUD_VERSION:-dev}

detect_target() {
  OS=$(uname -s)
  ARCH=$(uname -m)
  case "$OS:$ARCH" in
    Linux:x86_64|Linux:amd64) echo x86_64-unknown-linux-gnu ;;
    Linux:aarch64|Linux:arm64) echo aarch64-unknown-linux-gnu ;;
    Darwin:x86_64) echo x86_64-apple-darwin ;;
    Darwin:arm64|Darwin:aarch64) echo aarch64-apple-darwin ;;
    *)
      echo "codex-hud: unsupported release host: $OS $ARCH" >&2
      exit 1
      ;;
  esac
}

TARGET=${CODEX_HUD_TARGET:-$(detect_target)}
ASSET=codex-hud-$TARGET.tar.gz

for COMMAND in tar sha256sum; do
  if ! command -v "$COMMAND" >/dev/null 2>&1; then
    echo "codex-hud: required command not found: $COMMAND" >&2
    exit 1
  fi
done
if [ ! -x "$PACKAGE_SOURCE/bin/codex" ]; then
  echo "codex-hud: package is missing $PACKAGE_SOURCE/bin/codex" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-hud-release.XXXXXX")
cleanup() {
  rm -rf -- "$STAGE_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/config" "$STAGE_DIR/renderer" "$STAGE_DIR/scripts"
cp -R "$PACKAGE_SOURCE" "$STAGE_DIR/package"
install -m 0755 "$PROJECT_ROOT/bin/codex-hud" "$STAGE_DIR/bin/codex-hud"
install -m 0755 "$PROJECT_ROOT/renderer/statusline.mjs" "$STAGE_DIR/renderer/statusline.mjs"
install -m 0644 "$PROJECT_ROOT/config/config.json" "$STAGE_DIR/config/config.json"
install -m 0755 "$PROJECT_ROOT/scripts/install.sh" "$STAGE_DIR/scripts/install.sh"
install -m 0755 "$PROJECT_ROOT/scripts/uninstall.sh" "$STAGE_DIR/scripts/uninstall.sh"
install -m 0644 "$PROJECT_ROOT/LICENSE" "$STAGE_DIR/LICENSE"
install -m 0644 "$PROJECT_ROOT/NOTICE" "$STAGE_DIR/NOTICE"
printf '%s\n' "$VERSION" > "$STAGE_DIR/VERSION"

tar -czf "$OUTPUT_DIR/$ASSET" -C "$STAGE_DIR" .
(cd "$OUTPUT_DIR" && sha256sum "$ASSET" > "$ASSET.sha256")

echo "Created $OUTPUT_DIR/$ASSET"
echo "Created $OUTPUT_DIR/$ASSET.sha256"
