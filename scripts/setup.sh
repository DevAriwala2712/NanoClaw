#!/usr/bin/env zsh
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$workspace_dir"

if ! command -v zig >/dev/null 2>&1; then
  echo "[setup] Zig is not installed. Install Zig 0.15.2 first."
  echo "[setup] macOS: brew install zig"
  echo "[setup] Linux: download from https://ziglang.org/download/"
  exit 1
fi

zig_version="$(zig version)"
if [[ "$zig_version" != 0.15.* ]]; then
  echo "[setup] Unsupported Zig version: $zig_version"
  echo "[setup] Please use Zig 0.15.2"
  exit 1
fi

echo "[setup] Zig version ok: $zig_version"

echo "[setup] Running compile check"
if ! zig build; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "[setup] zig build failed; on macOS 27 this is a known Zig 0.15.2 SDK issue."
    echo "[setup] Falling back to an explicit macOS 15 target (see README: Known issues)."
    mkdir -p zig-out/bin
    zig build-exe src/main.zig -target "$(uname -m | sed 's/arm64/aarch64/')-macos.15.0" -femit-bin=zig-out/bin/nanoclaw-next
  else
    exit 1
  fi
fi

echo "[setup] Initializing runtime config and state"
./zig-out/bin/nanoclaw-next init

echo "[setup] Setup complete"
echo "[setup] Next: ./zig-out/bin/nanoclaw-next selftest"
echo "[setup] Next: add model= lines to nanoclaw-next.conf, then ./zig-out/bin/nanoclaw-next probe"
