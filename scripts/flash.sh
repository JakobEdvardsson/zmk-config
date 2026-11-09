#!/usr/bin/env bash
# Download the latest successful GitHub Actions firmware and copy it to a
# nice!nano in UF2 bootloader mode.
#
#   ./scripts/flash.sh left
#   ./scripts/flash.sh right
#   ./scripts/flash.sh both
#   ./scripts/flash.sh reset
#
# The left/right halves must be put into bootloader mode (double-tap reset)
# when prompted. GitHub Actions builds the pushed commit, so commit and push
# your config changes first.

set -euo pipefail

repo="${ZMK_REPO:-JakobEdvardsson/zmk-config}"
workflow="build.yml"
artifact="firmware"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

usage() {
  echo "usage: $0 {left|right|both|reset}" >&2
  exit 1
}

target="${1:-}"
case "$target" in
  left)  uf2_pattern="skeletyl_left-*-zmk.uf2" ;;
  right) uf2_pattern="skeletyl_right-*-zmk.uf2" ;;
  reset) uf2_pattern="settings_reset-*-zmk.uf2" ;;
  both)  ;;
  *) usage ;;
esac

find_bootloader() {
  if [ -n "${ZMK_BOOTLOADER_DIR:-}" ]; then
    printf '%s\n' "$ZMK_BOOTLOADER_DIR"
    return
  fi

  find /run/media/"$USER" /media/"$USER" /mnt -maxdepth 2 -type d -name NICENANO 2>/dev/null |
    head -n1 || true
}

wait_for_bootloader() {
  local dir
  dir="$(find_bootloader)"
  if [ -n "$dir" ]; then
    printf '%s\n' "$dir"
    return
  fi

  echo "Put the $target half into bootloader mode (double-tap reset)." >&2
  for _ in $(seq 1 60); do
    sleep 1
    dir="$(find_bootloader)"
    if [ -n "$dir" ]; then
      printf '%s\n' "$dir"
      return
    fi
  done

  echo "NICENANO drive not found after 60 seconds." >&2
  exit 1
}

if [ "$target" = "both" ]; then
  "$0" left
  echo
  echo "Left half flashed. Unplug it, then put the right half into bootloader mode."
  read -r -p "Press Enter when the right half's NICENANO drive is mounted..."
  "$0" right
  exit 0
fi

if [ -n "$(git status --porcelain -- build.yaml config)" ]; then
  echo "warning: build.yaml or config/ has uncommitted changes." >&2
  echo "         GitHub Actions builds the pushed commit, not local changes." >&2
fi

read -r run_id status conclusion head_sha < <(
  gh run list --repo "$repo" --workflow "$workflow" --limit 1 \
    --json databaseId,status,conclusion,headSha |
    jq -r '.[0] | [.databaseId, .status, (.conclusion // ""), .headSha] | @tsv'
)

if [ -z "${run_id:-}" ] || [ "$run_id" = "null" ]; then
  echo "No GitHub Actions build found. Push your config first." >&2
  exit 1
fi

if [ "$head_sha" != "$(git rev-parse HEAD)" ]; then
  echo "warning: latest build is for ${head_sha:0:8}, HEAD is $(git rev-parse --short HEAD)." >&2
  echo "         Push your changes first if you want the new config." >&2
fi

if [ "$status" != "completed" ]; then
  echo "Waiting for build $run_id..."
  if ! gh run watch "$run_id" --repo "$repo" --exit-status >/dev/null; then
    echo "Build $run_id failed." >&2
    exit 1
  fi
  conclusion="$(gh run view "$run_id" --repo "$repo" --json conclusion -q .conclusion)"
fi

if [ "$conclusion" != "success" ]; then
  echo "Latest build $run_id did not succeed ($conclusion)." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Downloading firmware from build $run_id..."
gh run download "$run_id" --repo "$repo" --name "$artifact" --dir "$tmpdir"
echo "Downloaded firmware from build $run_id."

uf2_path="$(find "$tmpdir" -name "$uf2_pattern" -print -quit)"
if [ -z "$uf2_path" ]; then
  echo "Could not find $uf2_pattern in the build artifact. Contents:" >&2
  find "$tmpdir" -type f -printf '  %P\n' >&2
  exit 1
fi

mountpoint="$(wait_for_bootloader)"
echo "Flashing $(basename "$uf2_path") to $mountpoint"
cp "$uf2_path" "$mountpoint"/
sync
echo "Done. The keyboard should reboot."
