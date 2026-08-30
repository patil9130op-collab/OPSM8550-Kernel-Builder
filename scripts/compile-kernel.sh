#!/usr/bin/env bash
#
# Apply selected integrations, generate config, and build Image.
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

# ============================================================
# REQUIRED ENVIRONMENT
# ============================================================

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

# ============================================================
# BUILD TIMING
# ============================================================

BUILD_STARTED_AT="$(date +%s)"
CONFIG_SECONDS=0
COMPILE_SECONDS=0
BUILD_PHASE="setup"

publish_performance_summary() {
    local status="$?"
    local finished_at
    local elapsed
    local result

    trap - EXIT

    finished_at="$(date +%s)"
    elapsed=$((finished_at - BUILD_STARTED_AT))

    if [[ "${status}" -eq 0 ]]; then
        result="success"
    else
        result="failure"
    fi

    {
        echo "### Build performance"
        echo "- Result: ${result}"
        echo "- Last phase: ${BUILD_PHASE}"
        echo "- Config/patch time: ${CONFIG_SECONDS}s"
        echo "- Compile time: ${COMPILE_SECONDS}s"
        echo "- Script total: ${elapsed}s"

        if command -v ccache >/dev/null 2>&1; then
            echo
            echo '```text'
            ccache --show-stats || true
            echo '```'
        fi
    } >> "${GITHUB_STEP_SUMMARY}"

    exit "${status}"
}

trap publish_performance_summary EXIT

# ============================================================
# TOOLCHAIN
# ============================================================

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

# ============================================================
# KERNEL SOURCE
# ============================================================

cd "${SOC}"

SOURCE_DATE_EPOCH="$(git show -s --format=%ct "${KERNEL_COMMIT}")"

export SOURCE_DATE_EPOCH

KBUILD_BUILD_TIMESTAMP="$(
    date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%d %H:%M:%S UTC'
)"

export KBUILD_BUILD_TIMESTAMP
export KBUILD_BUILD_USER=opskernel
export KBUILD_BUILD_HOST=github-actions

# ============================================================
# MAKE ARGUMENTS
# ============================================================

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

echo
echo "============================================================"
echo "[+] Installing KernelSU"
echo "    TYPE: ${KSU_TYPE}"
echo "============================================================"

install_ksu_variant "${KSU_TYPE}"

KSU_DIR="${KSU_KERNEL_DIR:-drivers/kernelsu}"

if [[ ! -d "${KSU_DIR}" ]]; then
    echo "[!] ERROR: KernelSU directory not found:"
    echo "    ${KSU_DIR}"
    exit 1
fi

echo "[OK] KernelSU directory: ${KSU_DIR}"

# ============================================================
# APPLY SUSFS
# ============================================================

if [[ "${KSU_TYPE}" == *susfs* ||
      "${KSU_TYPE}" == *SUSFS* ||
      "${KSU_TYPE}" == *ZeroMount* ||
      "${KSU_TYPE}" == *zeromount* ||
      "${KSU_TYPE}" == *nomount* ]]; then

    : "${SUSFS_REF:?}"
    : "${SUSFS_COMMIT:?}"
    : "${SUSFS_PATCH_FILE:?}"

    echo
    echo "============================================================"
    echo "[+] Applying SUSFS"
    echo "    REF    : ${SUSFS_REF}"
    echo "    COMMIT : ${SUSFS_COMMIT}"
    echo "    PATCH  : ${SUSFS_PATCH_FILE}"
    echo "============================================================"

    if ! apply_susfs_full \
        "${SUSFS_REF}" \
        "${SUSFS_COMMIT}" \
        "${SUSFS_PATCH_FILE}"; then

        echo "[!] SUSFS patch reported conflicts."
        echo "[!] The SUSFS helper must resolve compatible rejects."
        exit 1
    fi

    echo "[OK] SUSFS integration finished."
fi

# ============================================================
# KERNELSU FILE PATHS
# ============================================================

INIT_C="${KSU_DIR}/core/init.c"
ALLOWLIST_C="${KSU_DIR}/policy/allowlist.c"
SUCOMPAT_C="${KSU_DIR}/feature/sucompat.c"

# ============================================================
# KSU COMPATIBILITY
# ============================================================

BUILD_PHASE="KernelSU compatibility"

echo
echo "============================================================"
echo "[+] KernelSU compatibility verification"
echo "============================================================"

# ============================================================
# ksu_late_loaded
# ============================================================

if [[ -f "${INIT_C}" ]]; then

    KSU_LATE_COUNT="$(
        grep -RhsE \
            '^[[:space:]]*(static[[:space:]]+)?bool[[:space:]]+ksu_late_loaded[[:space:]]*;' \
            "${KSU_DIR}" 2>/dev/null |
        wc -l
    )"

    echo "[*] ksu_late_loaded declarations: ${KSU_LATE_COUNT}"

    if [[ "${KSU_LATE_COUNT}" -eq 0 ]]; then

        echo "[+] Adding missing ksu_late_loaded declaration."

        sed -i \
            '1i bool ksu_late_loaded;' \
            "${INIT_C}"

    elif [[ "${KSU_LATE_COUNT}" -eq 1 ]]; then

        echo "[OK] ksu_late_loaded declaration found."

    else

        echo "[!] ERROR: Multiple ksu_late_loaded declarations found."

        grep -Rnw "${KSU_DIR}" \
            -e "ksu_late_loaded" 2>/dev/null || true

        exit 1
    fi
fi

# ============================================================
# ksu_webview_zygote_umount_enabled
# ============================================================

if [[ -f "${ALLOWLIST_C}" ]]; then

    WEBVIEW_COUNT="$(
        grep -RhsE \
            '^[[:space:]]*(static[[:space:]]+)?bool[[:space:]]+ksu_webview_zygote_umount_enabled[[:space:]]*=' \
            "${KSU_DIR}" 2>/dev/null |
        wc -l
    )"

    echo "[*] ksu_webview_zygote_umount_enabled definitions: ${WEBVIEW_COUNT}"

    if [[ "${WEBVIEW_COUNT}" -eq 0 ]]; then

        echo "[+] Adding missing ksu_webview_zygote_umount_enabled."

        sed -i \
            '1i bool ksu_webview_zygote_umount_enabled = false;' \
            "${ALLOWLIST_C}"

    elif [[ "${WEBVIEW_COUNT}" -eq 1 ]]; then

        echo "[OK] ksu_webview_zygote_umount_enabled definition found."

    else

        echo "[!] ERROR: Multiple ksu_webview_zygote_umount_enabled definitions found."

        grep -Rnw "${KSU_DIR}" \
            -e "ksu_webview_zygote_umount_enabled" 2>/dev/null || true

        exit 1
    fi
fi

# ============================================================
# sh_user_path compatibility
# ============================================================

if [[ -f "${SUCOMPAT_C}" ]]; then

    echo
    echo "============================================================"
    echo "[+] Checking sh_user_path"
    echo "============================================================"

    python3 - "${SUCOMPAT_C}" <<'PY'
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as fh:
    source = fh.read()

signature = re.compile(
    r'(?m)^[ \t]*'
    r'(?:__attribute__\s*\(\(\s*weak\s*\)\)\s*)?'
    r'(?:static\s+)?'
    r'(?:inline\s+)?'
    r'(?:__always_inline\s+)?'
    r'char\s+__user\s*\*\s*'
    r'sh_user_path\s*\(\s*void\s*\)'
)


def find_open_brace(text, start):
    i = start
    n = len(text)

    line_comment = False
    block_comment = False
    string = False
    char = False
    escaped = False

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if line_comment:
            if c == "\n":
                line_comment = False
            i += 1
            continue

        if block_comment:
            if c == "*" and nxt == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue

        if string:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                string = False
            i += 1
            continue

        if char:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == "'":
                char = False
            i += 1
            continue

        if c == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue

        if c == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue

        if c == '"':
            string = True
            i += 1
            continue

        if c == "'":
            char = True
            i += 1
            continue

        if c == "{":
            return i

        if c == ";":
            return None

        i += 1

    return None


def find_function_end(text, opening):
    depth = 0
    i = opening
    n = len(text)

    line_comment = False
    block_comment = False
    string = False
    char = False
    escaped = False

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if line_comment:
            if c == "\n":
                line_comment = False
            i += 1
            continue

        if block_comment:
            if c == "*" and nxt == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue

        if string:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                string = False
            i += 1
            continue

        if char:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == "'":
                char = False
            i += 1
            continue

        if c == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue

        if c == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue

        if c == '"':
            string = True
            i += 1
            continue

        if c == "'":
            char = True
            i += 1
            continue

        if c == "{":
            depth += 1

        elif c == "}":
            depth -= 1

            if depth == 0:
                return i + 1

        i += 1

    return None


matches = list(signature.finditer(source))

print("[*] sh_user_path signatures found:", len(matches))

definitions = []

for match in matches:

    brace = find_open_brace(source, match.end())

    if brace is None:
        continue

    end = find_function_end(source, brace)

    if end is None:
        print("[!] ERROR: Unmatched sh_user_path function.")
        sys.exit(1)

    definitions.append((match.start(), end))


print("[*] sh_user_path implementations found:", len(definitions))

if len(definitions) == 0:
    print("[!] ERROR: sh_user_path implementation not found.")
    sys.exit(1)

if len(definitions) == 1:
    print("[OK] Single sh_user_path implementation found.")
    sys.exit(0)

print("[!] Duplicate sh_user_path implementations found.")
print("[+] Keeping the first implementation.")

for start, end in reversed(definitions[1:]):
    source = source[:start] + source[end:]

with open(path, "w", encoding="utf-8") as fh:
    fh.write(source)

verify_matches = list(signature.finditer(source))
verify_definitions = []

for match in verify_matches:

    brace = find_open_brace(source, match.end())

    if brace is None:
        continue

    end = find_function_end(source, brace)

    if end is not None:
        verify_definitions.append((match.start(), end))


print(
    "[+] sh_user_path implementations after cleanup:",
    len(verify_definitions)
)

if len(verify_definitions) != 1:
    print("[!] ERROR: sh_user_path cleanup failed.")
    sys.exit(1)

print("[OK] sh_user_path cleanup successful.")
PY

fi

# ============================================================
# FINAL KSU SOURCE CHECK
# ============================================================

echo
echo "============================================================"
echo "[+] Final KernelSU source verification"
echo "============================================================"

echo
echo "[*] ksu_late_loaded:"
grep -Rnw "${KSU_DIR}" \
    -e "ksu_late_loaded" 2>/dev/null |
    head -n 20 || true

echo
echo "[*] ksu_webview_zygote_umount_enabled:"
grep -Rnw "${KSU_DIR}" \
    -e "ksu_webview_zygote_umount_enabled" 2>/dev/null |
    head -n 20 || true

echo
echo "[*] sh_user_path:"
grep -Rnw "${KSU_DIR}/feature" \
    -e "sh_user_path" 2>/dev/null |
    head -n 30 || true

echo
echo "[OK] KernelSU source preparation completed."

# ============================================================
# SCM VERSION
# ============================================================

touch .scmversion

# ============================================================
# BUILD CONFIGURATION
# ============================================================

BUILD_PHASE="config generation"

ACTIVE_BUILD_CONFIGS="${BUILD_CONFIGS}"

if [[ "${SOURCE_LAYOUT}" == "oneplus-official" ]]; then
    ACTIVE_BUILD_CONFIGS="vendor/${OFFICIAL_BUILD_TARGET}_GKI.config"
fi

read -r -a ACTIVE_CONFIG_ARRAY <<< "${ACTIVE_BUILD_CONFIGS}"

echo
echo "============================================================"
echo "[+] Generating kernel configuration"
echo "============================================================"

apply_variant_configs arch/arm64/configs/gki_defconfig

make "${MAKE_ARGS[@]}" \
    gki_defconfig \
    "${ACTIVE_CONFIG_ARRAY[@]}"

# ============================================================
# KSU / SUSFS / KPM / ZEROMOUNT CONFIG
# ============================================================

if [[ "${KSU_TYPE}" == *ZeroMount* ||
      "${KSU_TYPE}" == *zeromount* ||
      "${KSU_TYPE}" == *SukiSU* ||
      "${KSU_TYPE}" == *ReSukiSU* ||
      "${KSU_TYPE}" == *nomount* ||
      "${KSU_TYPE}" == *KPM* ]]; then

    echo
    echo "[+] Enabling KernelSU / KPM / SUSFS / ZeroMount options."

    scripts/config \
        --file out/.config \
        --enable CONFIG_KSU || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_KPM || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_KALLSYMS || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_KALLSYMS_ALL || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_KSU_SUSFS || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_KSU_SUSFS_SUS_MAP || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_KSU_SUSFS_OPEN_REDIRECT || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_ZEROMOUNT || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_ZEROMOUNT_VFS || true

    scripts/config \
        --file out/.config \
        --enable CONFIG_NOMOUNT || true
fi

apply_variant_configs out/.config

make "${MAKE_ARGS[@]}" olddefconfig

CONFIG_SECONDS=$(($(date +%s) - CONFIG_STARTED_AT))

# ============================================================
# KERNEL COMPILATION
# ============================================================

BUILD_PHASE="kernel compilation"

COMPILE_STARTED_AT="$(date +%s)"

echo
echo "============================================================"
echo "[+] Building kernel Image"
echo "============================================================"

if ! make \
    -j"$(nproc)" \
    "${MAKE_ARGS[@]}" \
    Image 2>&1 |
    tee build.log; then

    COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))

    ccache --show-stats || true

    echo
    echo "============================================================"
    echo "==== BUILD ERROR SUMMARY ===="
    echo "============================================================"

    grep -nE \
        ' error:|undefined reference|No rule to make target|fatal error:' \
        build.log |
        tail -n 80 || true

    echo
    echo "============================================================"
    echo "==== BUILD FAILED - LAST 200 LINES ===="
    echo "============================================================"

    tail -n 200 build.log || true

    exit 1
fi

COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))

# ============================================================
# FINAL IMAGE CHECK
# ============================================================

ccache --show-stats || true

IMAGE_PATH="out/arch/arm64/boot/Image"

if [[ ! -f "${IMAGE_PATH}" ]]; then

    echo
    echo "[!] ERROR: Kernel Image was not generated."
    echo "[!] Expected:"
    echo "    ${SOC}/${IMAGE_PATH}"

    exit 1
fi

BUILD_PHASE="build complete"

echo
echo "============================================================"
echo "[+] BUILD SUCCESSFUL"
echo "============================================================"
echo "[+] Kernel Image:"
echo "    ${SOC}/${IMAGE_PATH}"
echo "============================================================"
