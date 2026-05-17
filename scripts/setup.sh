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
zig build

echo "[setup] Initializing runtime config and state"
zig build run -- init

echo "[setup] Setup complete"
echo "[setup] Next: zig build run -- --demo"
echo "[setup] Next: zig build run -- selftest"
