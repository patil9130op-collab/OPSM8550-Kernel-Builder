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


# ------------------------------------------------------------
# TOOLCHAIN
# ------------------------------------------------------------

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


# ------------------------------------------------------------
# SOURCE
# ------------------------------------------------------------

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


# ============================================================
# SOURCE INTEGRATION
# ============================================================

CONFIG_STARTED_AT="$(date +%s)"
BUILD_PHASE="source integration"


echo "=============================================="
echo "[+] Installing KernelSU"
echo "    Type: ${KSU_TYPE}"
echo "=============================================="


install_ksu_variant "${KSU_TYPE}"


KSU_DIR="${KSU_KERNEL_DIR:-drivers/kernelsu}"


if [[ ! -d "${KSU_DIR}" ]]; then
  echo "[!] ERROR: KernelSU directory does not exist:"
  echo "    ${KSU_DIR}"
  exit 1
fi


echo "[+] KernelSU directory:"
echo "    ${KSU_DIR}"


# ============================================================
# SUSFS
#
# IMPORTANT:
# SUSFS MUST be applied before the final compatibility cleanup.
# ============================================================

if [[ "$KSU_TYPE" == *susfs* ||
      "$KSU_TYPE" == *SUSFS* ||
      "$KSU_TYPE" == *ZeroMount* ||
      "$KSU_TYPE" == *zeromount* ||
      "$KSU_TYPE" == *nomount* ]]; then

  : "${SUSFS_REF:?}"
  : "${SUSFS_COMMIT:?}"
  : "${SUSFS_PATCH_FILE:?}"

  echo "=============================================="
  echo "[+] Applying SUSFS"
  echo "    REF    : ${SUSFS_REF}"
  echo "    COMMIT : ${SUSFS_COMMIT}"
  echo "    PATCH  : ${SUSFS_PATCH_FILE}"
  echo "=============================================="

  apply_susfs_full \
    "$SUSFS_REF" \
    "$SUSFS_COMMIT" \
    "$SUSFS_PATCH_FILE"

  echo "[+] SUSFS applied successfully."

fi


# ============================================================
# KERNELSU COMPATIBILITY FIXES
# ============================================================

BUILD_PHASE="KernelSU compatibility"


INIT_C="${KSU_DIR}/core/init.c"
ALLOWLIST_C="${KSU_DIR}/policy/allowlist.c"
SUCOMPAT_C="${KSU_DIR}/feature/sucompat.c"


echo "=============================================="
echo "[+] KernelSU compatibility check"
echo "=============================================="


# ------------------------------------------------------------
# 1. ksu_late_loaded
#
# The symbol must have exactly ONE global definition.
#
# Current KernelSU uses:
#
#     bool ksu_late_loaded;
#
# ------------------------------------------------------------

if [[ -f "${INIT_C}" ]]; then

  KSU_LATE_DEFS="$(
    grep -RnsE \
      '^[[:space:]]*(static[[:space:]]+)?bool[[:space:]]+ksu_late_loaded[[:space:]]*;' \
      "${KSU_DIR}" 2>/dev/null || true
  )"

  KSU_LATE_COUNT="$(
    printf '%s\n' "${KSU_LATE_DEFS}" |
      sed '/^[[:space:]]*$/d' |
      wc -l
  )"

  echo "[*] ksu_late_loaded definitions: ${KSU_LATE_COUNT}"

  if [[ "${KSU_LATE_COUNT}" -eq 0 ]]; then

    echo "[+] Adding missing ksu_late_loaded definition."

    sed -i '1i bool ksu_late_loaded;' "${INIT_C}"

  elif [[ "${KSU_LATE_COUNT}" -gt 1 ]]; then

    echo "[!] ERROR: Multiple ksu_late_loaded definitions found:"
    printf '%s\n' "${KSU_LATE_DEFS}"

    exit 1

  else

    echo "[OK] ksu_late_loaded definition found."

  fi

fi


# ------------------------------------------------------------
# 2. ksu_webview_zygote_umount_enabled
#
# SUSFS/KSU integration may reference this symbol.
#
# First find an existing definition.
# Do NOT blindly add another definition.
# ------------------------------------------------------------

if [[ -f "${ALLOWLIST_C}" ]]; then

  WEBVIEW_DEFS="$(
    grep -RnsE \
      '^[[:space:]]*(static[[:space:]]+)?bool[[:space:]]+ksu_webview_zygote_umount_enabled[[:space:]]*=' \
      "${KSU_DIR}" 2>/dev/null || true
  )"

  WEBVIEW_COUNT="$(
    printf '%s\n' "${WEBVIEW_DEFS}" |
      sed '/^[[:space:]]*$/d' |
      wc -l
  )"

  echo "[*] ksu_webview_zygote_umount_enabled definitions: ${WEBVIEW_COUNT}"


  if [[ "${WEBVIEW_COUNT}" -eq 0 ]]; then

    echo "[+] No definition found."
    echo "[+] Adding one global definition."

    sed -i \
      '1i bool ksu_webview_zygote_umount_enabled = false;' \
      "${ALLOWLIST_C}"


  elif [[ "${WEBVIEW_COUNT}" -gt 1 ]]; then

    echo "[!] ERROR: Multiple ksu_webview_zygote_umount_enabled definitions found:"
    printf '%s\n' "${WEBVIEW_DEFS}"

    exit 1


  else

    echo "[OK] ksu_webview_zygote_umount_enabled definition found."

  fi

fi


# ------------------------------------------------------------
# 3. sh_user_path()
#
# NEVER solve duplicate definitions by making every function
# weak.
#
# Keep only the FIRST complete implementation.
# ------------------------------------------------------------

if [[ -f "${SUCOMPAT_C}" ]]; then

  SH_USER_PATH_COUNT="$(
    grep -Ec \
      '^[[:space:]]*(static[[:space:]]+)?(__attribute__\(\(weak\)\)[[:space:]]+)?char[[:space:]]+__user[[:space:]]*\*sh_user_path[[:space:]]*\(void\)' \
      "${SUCOMPAT_C}" 2>/dev/null || true
  )"

  echo "[*] sh_user_path definitions: ${SH_USER_PATH_COUNT}"


  if [[ "${SH_USER_PATH_COUNT}" -gt 1 ]]; then

    echo "[!] Duplicate sh_user_path() detected."
    echo "[+] Keeping the first implementation."


    python3 - "${SUCOMPAT_C}" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()


def is_function_start(line):
    text = line.strip()

    return (
        "sh_user_path(void)" in text
        and "__user" in text
        and text.endswith("{")
    )


result = []
seen = 0
i = 0

while i < len(lines):

    if is_function_start(lines[i]):

        seen += 1

        # Keep FIRST implementation.
        if seen == 1:

            result.append(lines[i])
            i += 1

            depth = 1

            while i < len(lines):

                line = lines[i]
                result.append(line)

                depth += line.count("{")
                depth -= line.count("}")

                i += 1

                if depth == 0:
                    break

        # Remove every duplicate implementation.
        else:

            i += 1
            depth = 1

            while i < len(lines) and depth > 0:

                depth += lines[i].count("{")
                depth -= lines[i].count("}")

                i += 1

        continue

    result.append(lines[i])
    i += 1


with open(path, "w", encoding="utf-8") as f:
    f.writelines(result)


print(f"[+] sh_user_path cleanup complete.")
print(f"[+] Definitions found: {seen}")
PY

  fi


  SH_USER_PATH_FINAL="$(
    grep -Ec \
      '^[[:space:]]*(static[[:space:]]+)?(__attribute__\(\(weak\)\)[[:space:]]+)?char[[:space:]]+__user[[:space:]]*\*sh_user_path[[:space:]]*\(void\)' \
      "${SUCOMPAT_C}" 2>/dev/null || true
  )"


  echo "[+] sh_user_path definitions after cleanup: ${SH_USER_PATH_FINAL}"


  if [[ "${SH_USER_PATH_FINAL}" -gt 1 ]]; then

    echo "[!] ERROR: sh_user_path() is still duplicated."
    exit 1

  fi

fi


# ============================================================
# FINAL SOURCE VERIFICATION
# ============================================================

echo "=============================================="
echo "[+] Final KernelSU source verification"
echo "=============================================="


echo
echo "[*] ksu_late_loaded:"
grep -Rnw "${KSU_DIR}" \
  -e "ksu_late_loaded" 2>/dev/null | head -n 20 || true


echo
echo "[*] ksu_webview_zygote_umount_enabled:"
grep -Rnw "${KSU_DIR}" \
  -e "ksu_webview_zygote_umount_enabled" 2>/dev/null | head -n 20 || true


echo
echo "[*] sh_user_path:"
grep -Rnw "${KSU_DIR}/feature" \
  -e "sh_user_path" 2>/dev/null | head -n 20 || true


echo
echo "[+] KernelSU/SUSFS source preparation completed."


# ============================================================
# TOUCH SCM VERSION
# ============================================================

touch .scmversion


# ============================================================
# BUILD CONFIG
# ============================================================

ACTIVE_BUILD_CONFIGS="${BUILD_CONFIGS}"


if [[ "$SOURCE_LAYOUT" == "oneplus-official" ]]; then
  ACTIVE_BUILD_CONFIGS="vendor/${OFFICIAL_BUILD_TARGET}_GKI.config"
fi


read -r -a ACTIVE_CONFIG_ARRAY <<< "${ACTIVE_BUILD_CONFIGS}"


BUILD_PHASE="config generation"


echo "=============================================="
echo "[+] Applying kernel configuration"
echo "=============================================="


apply_variant_configs arch/arm64/configs/gki_defconfig


make "${MAKE_ARGS[@]}" \
  gki_defconfig \
  "${ACTIVE_CONFIG_ARRAY[@]}"


# ============================================================
# EXPLICIT CONFIG OVERRIDES
# ============================================================

if [[ "$KSU_TYPE" == *ZeroMount* ||
      "$KSU_TYPE" == *zeromount* ||
      "$KSU_TYPE" == *SukiSU* ||
      "$KSU_TYPE" == *ReSukiSU* ||
      "$KSU_TYPE" == *nomount* ||
      "$KSU_TYPE" == *KPM* ]]; then

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


# ============================================================
# BUILD
# ============================================================

BUILD_PHASE="kernel compilation"

COMPILE_STARTED_AT="$(date +%s)"


echo "=============================================="
echo "[+] Building kernel Image"
echo "=============================================="


if ! make -j"$(nproc)" \
    "${MAKE_ARGS[@]}" \
    Image 2>&1 | tee build.log; then

  COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))

  ccache --show-stats || true

  echo
  echo "=============================================="
  echo "==== BUILD ERROR SUMMARY ===="
  echo "=============================================="


  grep -nE \
    ' error:|undefined reference|No rule to make target|fatal error:' \
    build.log |
    tail -n 50 || true


  echo
  echo "=============================================="
  echo "==== BUILD FAILED - LAST 200 LINES ===="
  echo "=============================================="


  tail -n 200 build.log || true

  exit 1

fi


COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))


# ============================================================
# FINAL CHECK
# ============================================================

ccache --show-stats || true


if [[ ! -f out/arch/arm64/boot/Image ]]; then

  echo "[!] ERROR: Kernel Image was not generated."

  exit 1

fi


BUILD_PHASE="build complete"


echo "=============================================="
echo "[+] BUILD SUCCESSFUL"
echo "=============================================="
echo "[+] Image:"
echo "    ${SOC}/out/arch/arm64/boot/Image"
echo "=============================================="
