#!/usr/bin/env bash
#
# Apply the selected integrations, generate config, and build Image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-helpers.sh
. "${SCRIPT_DIR}/lib/git-helpers.sh"
# shellcheck source=lib/kernel-helpers.sh
. "${SCRIPT_DIR}/lib/kernel-helpers.sh"
# shellcheck source=lib/ksu-setup.sh
. "${SCRIPT_DIR}/lib/ksu-setup.sh"
# shellcheck source=lib/susfs-apply.sh
. "${SCRIPT_DIR}/lib/susfs-apply.sh"
# shellcheck source=lib/nomount-setup.sh
. "${SCRIPT_DIR}/lib/nomount-setup.sh"
# shellcheck source=lib/verify.sh
. "${SCRIPT_DIR}/lib/verify.sh"

: "${GITHUB_WORKSPACE:?}"
: "${GITHUB_STEP_SUMMARY:?}"
: "${CLANG_VERSION:?}"
: "${SOC:?}"
: "${BUILD_CONFIGS:?}"
: "${SOURCE_LAYOUT:?}"
: "${OFFICIAL_BUILD_TARGET:?}"
: "${KSU_TYPE:?}"
: "${KERNEL_BRANCH:?}"
: "${KERNEL_COMMIT:?}"
: "${BUILD_MODE:?}"

BUILD_STARTED_AT="$(date +%s)"
CONFIG_SECONDS=0
COMPILE_SECONDS=0
BUILD_PHASE="setup"

publish_performance_summary() {
  local status="$?"
  local finished_at
  local elapsed

  trap - EXIT
  finished_at="$(date +%s)"
  elapsed=$((finished_at - BUILD_STARTED_AT))

  {
    echo "### Build performance"
    echo "- Result: $([[ "$status" -eq 0 ]] && echo success || echo failure)"
    echo "- Last phase: $BUILD_PHASE"
    echo "- Config/patch time: ${CONFIG_SECONDS}s"
    echo "- Compile time: ${COMPILE_SECONDS}s"
    echo "- Script total: ${elapsed}s"
    if command -v ccache >/dev/null 2>&1; then
      echo
      echo '```text'
      ccache --show-stats || true
      echo '```'
    fi
  } >> "$GITHUB_STEP_SUMMARY"

  exit "$status"
}
trap publish_performance_summary EXIT

CLANG_ROOT="${GITHUB_WORKSPACE}/toolchains/${CLANG_VERSION}/bin"
export PATH="${CLANG_ROOT}:${PATH}"
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CCACHE_DIR="${GITHUB_WORKSPACE}/.ccache"
export CCACHE_BASEDIR="${GITHUB_WORKSPACE}"
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
export CCACHE_COMPRESS=true
export CCACHE_COMPRESSLEVEL=6
export CCACHE_MAXSIZE=3G
mkdir -p "${CCACHE_DIR}"

cd "${SOC}"

SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$KERNEL_COMMIT")"
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%d %H:%M:%S UTC')"
export KBUILD_BUILD_USER=opskernel
export KBUILD_BUILD_HOST=github-actions

MAKE_ARGS=(
  O=out
  LLVM=1
  LLVM_IAS=1
  "CC=ccache clang"
  "CXX=ccache clang++"
  "HOSTCC=ccache clang"
  "HOSTCXX=ccache clang++"
)

ccache --zero-stats || true
CONFIG_STARTED_AT="$(date +%s)"
BUILD_PHASE="source integration"

install_ksu_variant "${KSU_TYPE}"

# Auto-fix missing declarations or conflicting definitions in source tree before build
KSU_DIR="${KSU_KERNEL_DIR:-drivers/kernelsu}"
if [[ -d "$KSU_DIR" ]]; then
  echo "[+] Applying compatibility patches for ReSukiSU/KSU source variables..."
  
  # Fix ksu_late_loaded in core/init.c if undeclared
  if [[ -f "$KSU_DIR/core/init.c" ]] && ! grep -q "ksu_late_loaded" "$KSU_DIR/core/init.c"; then
    sed -i '/#include/a bool ksu_late_loaded = false;' "$KSU_DIR/core/init.c" || true
  fi

  # Fix ksu_webview_zygote_umount_enabled in allowlist.c if undeclared
  if [[ -f "$KSU_DIR/policy/allowlist.c" ]] && ! grep -q "ksu_webview_zygote_umount_enabled" "$KSU_DIR/policy/allowlist.c"; then
    sed -i '/#include/a bool ksu_webview_zygote_umount_enabled = false;' "$KSU_DIR/policy/allowlist.c" || true
  fi

  # Fix redefinition of sh_user_path in sucompat.c by making it weak or conditional
  if [[ -f "$KSU_DIR/feature/sucompat.c" ]]; then
    sed -i 's/static char __user \*sh_user_path/__attribute__((weak)) static char __user *sh_user_path/g' "$KSU_DIR/feature/sucompat.c" || true
  fi
fi

if [[ "$KSU_TYPE" == *susfs* || "$KSU_TYPE" == *SUSFS* || "$KSU_TYPE" == *ZeroMount* || "$KSU_TYPE" == *zeromount* || "$KSU_TYPE" == *nomount* ]]; then
  : "${SUSFS_REF:?}"
  : "${SUSFS_COMMIT:?}"
  : "${SUSFS_PATCH_FILE:?}"
  apply_susfs_full "$SUSFS_REF" "$SUSFS_COMMIT" "$SUSFS_PATCH_FILE" || true
fi

touch .scmversion

ACTIVE_BUILD_CONFIGS="${BUILD_CONFIGS}"
if [[ "$SOURCE_LAYOUT" == "oneplus-official" ]]; then
  ACTIVE_BUILD_CONFIGS="vendor/${OFFICIAL_BUILD_TARGET}_GKI.config"
fi
read -r -a ACTIVE_CONFIG_ARRAY <<< "$ACTIVE_BUILD_CONFIGS"

BUILD_PHASE="config generation"
apply_variant_configs arch/arm64/configs/gki_defconfig
make "${MAKE_ARGS[@]}" gki_defconfig "${ACTIVE_CONFIG_ARRAY[@]}"

# Explicit config overrides
if [[ "$KSU_TYPE" == *ZeroMount* || "$KSU_TYPE" == *zeromount* || "$KSU_TYPE" == *SukiSU* || "$KSU_TYPE" == *ReSukiSU* || "$KSU_TYPE" == *nomount* || "$KSU_TYPE" == *KPM* ]]; then
  scripts/config --file out/.config --enable CONFIG_KSU || true
  scripts/config --file out/.config --enable CONFIG_KPM || true
  scripts/config --file out/.config --enable CONFIG_KALLSYMS || true
  scripts/config --file out/.config --enable CONFIG_KALLSYMS_ALL || true
  scripts/config --file out/.config --enable CONFIG_KSU_SUSFS || true
  scripts/config --file out/.config --enable CONFIG_KSU_SUSFS_SUS_MAP || true
  scripts/config --file out/.config --enable CONFIG_KSU_SUSFS_OPEN_REDIRECT || true
  scripts/config --file out/.config --enable CONFIG_ZEROMOUNT || true
  scripts/config --file out/.config --enable CONFIG_ZEROMOUNT_VFS || true
  scripts/config --file out/.config --enable CONFIG_NOMOUNT || true
fi

apply_variant_configs out/.config
make "${MAKE_ARGS[@]}" olddefconfig

CONFIG_SECONDS=$(($(date +%s) - CONFIG_STARTED_AT))

BUILD_PHASE="kernel compilation"
COMPILE_STARTED_AT="$(date +%s)"
if ! make -j"$(nproc)" "${MAKE_ARGS[@]}" Image 2>&1 | tee build.log; then
  COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))
  ccache --show-stats || true
  echo "==== BUILD ERROR SUMMARY ===="
  grep -nE ' error:|undefined reference|No rule to make target|fatal error:' build.log | tail -n 50 || true
  echo "==== BUILD FAILED (last 200 lines) ===="
  tail -n 200 build.log || true
  exit 1
fi
COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))

ccache --show-stats || true
test -f out/arch/arm64/boot/Image
BUILD_PHASE="build complete"
