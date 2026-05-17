#!/usr/bin/env zsh
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$workspace_dir"

if ! command -v zig >/dev/null 2>&1; then
	echo "[release] Zig is required but not found in PATH"
	exit 1
fi

echo "[release] building x86_64-linux-musl"
zig build release-x86 -Doptimize=ReleaseSmall

echo "[release] building aarch64-linux-musl"
zig build release-pi -Doptimize=ReleaseSmall

mkdir -p dist
cp -f zig-out/bin/nanoclaw-next-x86_64 dist/
cp -f zig-out/bin/nanoclaw-next-aarch64 dist/

echo "[release] artifact sizes"
ls -lh dist/nanoclaw-next-x86_64 dist/nanoclaw-next-aarch64

echo "[release] checksums"
if command -v shasum >/dev/null 2>&1; then
	shasum -a 256 dist/nanoclaw-next-x86_64 dist/nanoclaw-next-aarch64 > dist/SHA256SUMS
elif command -v sha256sum >/dev/null 2>&1; then
	sha256sum dist/nanoclaw-next-x86_64 dist/nanoclaw-next-aarch64 > dist/SHA256SUMS
else
	echo "[release] checksum tool not found (shasum/sha256sum)"
	exit 1
fi
cat dist/SHA256SUMS
