#!/usr/bin/env bash
#
# Clone the kernel, matching -modules, KSU, SUSFS, and ZeroMount repositories.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-helpers.sh
. "${SCRIPT_DIR}/lib/git-helpers.sh"

: "${KERNEL_REPO:?}"
: "${MODULES_REPO:?}"
: "${KERNEL_BRANCH:?}"
: "${KERNEL_COMMIT:?}"
: "${MODULES_COMMIT:?}"
: "${KERNEL_CLONE_DIR:?}"
: "${MODULES_CLONE_DIR:?}"
: "${SOURCE_LAYOUT:?}"
: "${SOC:?}"
: "${GITHUB_WORKSPACE:?}"
: "${KSU_TYPE:-None}"

clone_repo() {
  local repo="$1"
  local branch="$2"
  local commit="$3"
  local dest="$4"
  local label="$5"

  echo "[clone] $label -> $repo ($branch at $commit) into $dest"
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" ]]; then
    echo "::error::Refusing to clone $label into existing path: $dest"
    exit 1
  fi

  git init -q "$dest"
  git -C "$dest" remote add origin "$repo"
  git_fetch_retry "$dest" --depth=1 --no-tags origin "$commit" \
    || { echo "::error::Failed to fetch $label commit '$commit' for branch '$branch': $repo"; exit 1; }
  git -C "$dest" checkout -q --detach FETCH_HEAD
  test "$(git -C "$dest" rev-parse HEAD)" = "$commit" \
    || { echo "::error::$label checkout did not match resolved commit '$commit'."; exit 1; }
}

# Kick off modules clone in background; kernel clone in foreground.
clone_repo "$MODULES_REPO" "$KERNEL_BRANCH" "$MODULES_COMMIT" "$MODULES_CLONE_DIR" "modules repo" &
MODULES_PID=$!

clone_repo "$KERNEL_REPO" "$KERNEL_BRANCH" "$KERNEL_COMMIT" "$KERNEL_CLONE_DIR" "kernel repo"

if ! wait "$MODULES_PID"; then
  echo "::error::Background modules repo clone failed."
  exit 1
fi

if [[ "$SOURCE_LAYOUT" == "oneplus-official" ]]; then
  OFFICIAL_KERNEL_DIR="${MODULES_CLONE_DIR}/kernel_platform/msm-kernel"
  mkdir -p "$(dirname "$OFFICIAL_KERNEL_DIR")"
  rm -rf "$OFFICIAL_KERNEL_DIR"
  mv "$KERNEL_CLONE_DIR" "$OFFICIAL_KERNEL_DIR"
  rm -rf "${SOC}"
  ln -sfn "${GITHUB_WORKSPACE}/${OFFICIAL_KERNEL_DIR}" "${SOC}"
  TARGET_KERNEL_DIR="$OFFICIAL_KERNEL_DIR"
else
  TARGET_KERNEL_DIR="$KERNEL_CLONE_DIR"
fi

# ==============================================================================
# Root Solution, SUSFS & ZeroMount Setup
# ==============================================================================

# 1. Clone SukiSU / KernelSU
if [[ -n "${KSU_REPO:-}" && -n "${KSU_COMMIT:-}" ]]; then
  clone_repo "$KSU_REPO" "${KSU_REF:-main}" "$KSU_COMMIT" "${TARGET_KERNEL_DIR}/KernelSU" "KernelSU/SukiSU repo"
  echo "[setup] KernelSU / SukiSU source successfully placed in ${TARGET_KERNEL_DIR}/KernelSU"
fi

# 2. Clone SUSFS repo
if [[ -n "${SUSFS_REPO:-}" && -n "${SUSFS_COMMIT:-}" ]]; then
  clone_repo "$SUSFS_REPO" "${SUSFS_REF:-main}" "$SUSFS_COMMIT" "susfs4ksu" "SUSFS repo"
  echo "[setup] SUSFS source cloned into susfs4ksu"
fi

# 3. Clone ZeroMount repo
if [[ -n "${ZEROMOUNT_REPO:-}" && -n "${ZEROMOUNT_COMMIT:-}" ]]; then
  clone_repo "$ZEROMOUNT_REPO" "${ZEROMOUNT_REF:-main}" "$ZEROMOUNT_COMMIT" "zeromount" "ZeroMount repo"
  echo "[setup] ZeroMount VFS source cloned into zeromount"
fi
