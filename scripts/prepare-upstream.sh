#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
UPSTREAM_TAG=rust-v0.147.0
UPSTREAM_COMMIT=be6e8eac029b183056b7e4402879f15d2c85f61b
UPSTREAM_URL=https://github.com/openai/codex.git
SOURCE_DIR=${CODEX_HUD_SOURCE_DIR:-$PROJECT_ROOT/.cache/codex}
PATCH_FILE=$PROJECT_ROOT/patches/0001-custom-status-line.patch
CUSTOM_SOURCE=$PROJECT_ROOT/src/custom_status_line.rs
CUSTOM_TARGET=$SOURCE_DIR/codex-rs/tui/src/chatwidget/custom_status_line.rs

if ! command -v git >/dev/null 2>&1; then
  echo "codex-hud: git is required" >&2
  exit 1
fi

if ! git -C "$SOURCE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -e "$SOURCE_DIR" ]; then
    echo "codex-hud: source path exists but is not a Git checkout: $SOURCE_DIR" >&2
    exit 1
  fi
  mkdir -p "$(dirname -- "$SOURCE_DIR")"
  git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" "$SOURCE_DIR"
fi

ACTUAL_COMMIT=$(git -C "$SOURCE_DIR" rev-parse HEAD)
if [ "$ACTUAL_COMMIT" != "$UPSTREAM_COMMIT" ]; then
  echo "codex-hud: unsupported Codex source revision in $SOURCE_DIR" >&2
  echo "Expected $UPSTREAM_TAG ($UPSTREAM_COMMIT), found $ACTUAL_COMMIT" >&2
  exit 1
fi

if [ -e "$CUSTOM_TARGET" ] && ! cmp -s "$CUSTOM_SOURCE" "$CUSTOM_TARGET"; then
  echo "codex-hud: refusing to overwrite a different $CUSTOM_TARGET" >&2
  exit 1
fi

if git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
  git -C "$SOURCE_DIR" apply "$PATCH_FILE"
elif git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  : # The tracked-file patch is already present.
else
  echo "codex-hud: the status-line patch does not apply cleanly" >&2
  echo "Use a clean checkout of $UPSTREAM_TAG or remove CODEX_HUD_SOURCE_DIR." >&2
  exit 1
fi

if [ ! -e "$CUSTOM_TARGET" ]; then
  install -m 0644 "$CUSTOM_SOURCE" "$CUSTOM_TARGET"
fi

git -C "$SOURCE_DIR" diff --check
echo "Prepared Codex $UPSTREAM_TAG source at $SOURCE_DIR"
