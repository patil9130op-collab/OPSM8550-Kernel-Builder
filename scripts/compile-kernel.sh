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
        if [[ "${status}" -eq 0 ]]; then
            echo "- Result: success"
        else
            echo "- Result: failure"
        fi
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

SOURCE_DATE_EPOCH="$(git show -s --format=%ct "${KERNEL_COMMIT}")"
export SOURCE_DATE_EPOCH
KBUILD_BUILD_TIMESTAMP="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%d %H:%M:%S UTC')"
export KBUILD_BUILD_TIMESTAMP
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

echo "============================================================"
echo "[+] Installing KernelSU"
echo "    TYPE: ${KSU_TYPE}"
echo "============================================================"

install_ksu_variant "${KSU_TYPE}"

KSU_DIR="${KSU_KERNEL_DIR:-drivers/kernelsu}"

if [[ ! -d "${KSU_DIR}" ]]; then
    echo "[!] ERROR: KernelSU directory not found: ${KSU_DIR}"
    exit 1
fi

echo "[OK] KernelSU directory: ${KSU_DIR}"

if [[ "${KSU_TYPE}" == *susfs* ||
      "${KSU_TYPE}" == *SUSFS* ||
      "${KSU_TYPE}" == *ZeroMount* ||
      "${KSU_TYPE}" == *zeromount* ||
      "${KSU_TYPE}" == *nomount* ]]; then

    : "${SUSFS_REF:?}"
    : "${SUSFS_COMMIT:?}"
    : "${SUSFS_PATCH_FILE:?}"

    echo "============================================================"
    echo "[+] Applying SUSFS"
    echo "    REF    : ${SUSFS_REF}"
    echo "    COMMIT : ${SUSFS_COMMIT}"
    echo "    PATCH  : ${SUSFS_PATCH_FILE}"
    echo "============================================================"

    apply_susfs_full \
        "${SUSFS_REF}" \
        "${SUSFS_COMMIT}" \
        "${SUSFS_PATCH_FILE}"

    echo "[OK] SUSFS integration finished."
fi

# ------------------------------------------------------------------
# KernelSU compatibility repair.
#
# Important:
#   Do NOT use "sed -i '1i ...'" here. Some KSU files begin with a
#   block comment, so that puts the declaration inside the comment.
#   Instead, insert declarations after the include section.
# ------------------------------------------------------------------

BUILD_PHASE="KernelSU compatibility"

INIT_C="${KSU_DIR}/core/init.c"
ALLOWLIST_C="${KSU_DIR}/policy/allowlist.c"
SUCOMPAT_C="${KSU_DIR}/feature/sucompat.c"

insert_global_definition() {
    local file="$1"
    local symbol="$2"
    local definition="$3"

    python3 - "${file}" "${symbol}" "${definition}" <<'PY'
import re
import sys

path, symbol, definition = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# A real global definition/declaration anywhere in this C file.
# Ignore comments and string literals by requiring the symbol to appear
# in a normal declaration-like line.
decl_re = re.compile(
    rf'(?m)^[ \t]*(?:(?:static|extern|const|volatile|__init|__read_mostly)[ \t]+)*'
    rf'(?:bool|int|unsigned[ \t]+int)[ \t]+{re.escape(symbol)}[ \t]*(?:=[^;]+)?;[ \t]*$'
)

matches = list(decl_re.finditer(text))

if matches:
    print(f"[OK] {symbol}: existing declaration/definition found ({len(matches)}).")
    if len(matches) > 1:
        print(f"[!] ERROR: {symbol} has multiple declaration-like definitions in {path}.")
        for m in matches:
            line = text.count("\n", 0, m.start()) + 1
            print(f"    line {line}: {m.group(0).strip()}")
        sys.exit(1)
    sys.exit(0)

# Find the last #include in the file header. This guarantees the type
# 'bool' and kernel types are already available and avoids block comments.
include_matches = list(re.finditer(r'(?m)^[ \t]*#include[^\n]*\n', text))

if include_matches:
    pos = include_matches[-1].end()
else:
    # Fallback: insert after leading comments/shebang/preprocessor area.
    pos = 0
    while True:
        m = re.match(r'(?s)(?:\s|/\*.*?\*/|//[^\n]*\n)*', text[pos:])
        if not m or m.end() == 0:
            break
        pos += m.end()

new_text = text[:pos] + "\n" + definition + "\n" + text[pos:]

with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)

print(f"[+] {symbol}: inserted after the include/header section.")
PY
}

# ksu_late_loaded must be a real definition, not a declaration hidden
# inside the file's opening comment.
if [[ -f "${INIT_C}" ]]; then
    insert_global_definition \
        "${INIT_C}" \
        "ksu_late_loaded" \
        "bool ksu_late_loaded = false;"
fi

# WebView zygote flag is handled the same way.
if [[ -f "${ALLOWLIST_C}" ]]; then
    insert_global_definition \
        "${ALLOWLIST_C}" \
        "ksu_webview_zygote_umount_enabled" \
        "bool ksu_webview_zygote_umount_enabled = false;"
fi

# ------------------------------------------------------------------
# Remove duplicate sh_user_path() implementations safely.
# ------------------------------------------------------------------

if [[ -f "${SUCOMPAT_C}" ]]; then
    python3 - "${SUCOMPAT_C}" <<'PY'
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    source = f.read()

sig = re.compile(
    r'(?m)^[ \t]*'
    r'(?:(?:__attribute__\s*\(\(\s*weak\s*\)\)\s*)|(?:static\s+))?'
    r'char\s+__user\s*\*\s*sh_user_path\s*\(\s*void\s*\)'
)

matches = list(sig.finditer(source))
print(f"[*] sh_user_path signatures found: {len(matches)}")

if len(matches) <= 1:
    print("[OK] sh_user_path() is not duplicated.")
    sys.exit(0)

def scan_end(text, brace):
    depth = 0
    i = brace
    n = len(text)
    state = "code"
    escaped = False

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if state == "line":
            if c == "\n":
                state = "code"
            i += 1
            continue

        if state == "block":
            if c == "*" and nxt == "/":
                state = "code"
                i += 2
            else:
                i += 1
            continue

        if state == "string":
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                state = "code"
            i += 1
            continue

        if state == "char":
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == "'":
                state = "code"
            i += 1
            continue

        if c == "/" and nxt == "/":
            state = "line"
            i += 2
            continue
        if c == "/" and nxt == "*":
            state = "block"
            i += 2
            continue
        if c == '"':
            state = "string"
            i += 1
            continue
        if c == "'":
            state = "char"
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

ranges = []

for m in matches:
    i = m.end()

    # Find the first real opening brace after the signature.
    while i < len(source) and source[i] != "{":
        i += 1

    if i >= len(source):
        print("[!] ERROR: opening brace for sh_user_path() not found.")
        sys.exit(1)

    end = scan_end(source, i)
    if end is None:
        print("[!] ERROR: closing brace for sh_user_path() not found.")
        sys.exit(1)

    ranges.append((m.start(), end))

print("[!] Duplicate sh_user_path() implementations detected.")
print("[+] Keeping the first implementation.")

for start, end in reversed(ranges[1:]):
    source = source[:start] + source[end:]

with open(path, "w", encoding="utf-8") as f:
    f.write(source)

final_count = len(list(sig.finditer(source)))
print(f"[+] sh_user_path() definitions after cleanup: {final_count}")

if final_count != 1:
    print("[!] ERROR: sh_user_path() cleanup did not leave exactly one definition.")
    sys.exit(1)

print("[OK] sh_user_path() cleanup successful.")
PY
fi

# ------------------------------------------------------------------
# Final source checks. These are intentionally strict so a bad source
# integration fails before a long kernel compile.
# ------------------------------------------------------------------

echo "============================================================"
echo "[+] Final KernelSU source verification"
echo "============================================================"

if [[ -f "${INIT_C}" ]]; then
    LATE_DEFS="$(
        grep -Ec \
            '^[[:space:]]*(static[[:space:]]+)?bool[[:space:]]+ksu_late_loaded[[:space:]]*(=[^;]+)?;[[:space:]]*$' \
            "${INIT_C}" || true
    )"
    echo "[*] ksu_late_loaded declarations in init.c: ${LATE_DEFS}"
    if [[ "${LATE_DEFS}" -ne 1 ]]; then
        echo "[!] ERROR: expected exactly one ksu_late_loaded definition in init.c."
        grep -n -B 3 -A 5 "ksu_late_loaded" "${INIT_C}" || true
        exit 1
    fi
fi

if [[ -f "${ALLOWLIST_C}" ]]; then
    WEBVIEW_DEFS="$(
        grep -Ec \
            '^[[:space:]]*(static[[:space:]]+)?bool[[:space:]]+ksu_webview_zygote_umount_enabled[[:space:]]*(=[^;]+)?;[[:space:]]*$' \
            "${ALLOWLIST_C}" || true
    )"
    echo "[*] ksu_webview_zygote_umount_enabled declarations in allowlist.c: ${WEBVIEW_DEFS}"
    if [[ "${WEBVIEW_DEFS}" -ne 1 ]]; then
        echo "[!] ERROR: expected exactly one webview flag definition in allowlist.c."
        grep -n -B 3 -A 5 "ksu_webview_zygote_umount_enabled" "${ALLOWLIST_C}" || true
        exit 1
    fi
fi

if [[ -f "${SUCOMPAT_C}" ]]; then
    SH_USER_PATH_DEFS="$(
        grep -Ec \
            '^[[:space:]]*(static[[:space:]]+)?(__attribute__\(\(weak\)\)[[:space:]]+)?char[[:space:]]+__user[[:space:]]*\*[[:space:]]*sh_user_path[[:space:]]*\([[:space:]]*void[[:space:]]*\)' \
            "${SUCOMPAT_C}" || true
    )"
    echo "[*] sh_user_path() definitions in sucompat.c: ${SH_USER_PATH_DEFS}"
    if [[ "${SH_USER_PATH_DEFS}" -ne 1 ]]; then
        echo "[!] ERROR: expected exactly one sh_user_path() definition."
        grep -n -B 5 -A 15 "sh_user_path" "${SUCOMPAT_C}" || true
        exit 1
    fi
fi

echo "[OK] KernelSU source preparation completed."

touch .scmversion

BUILD_PHASE="config generation"

ACTIVE_BUILD_CONFIGS="${BUILD_CONFIGS}"

if [[ "${SOURCE_LAYOUT}" == "oneplus-official" ]]; then
    ACTIVE_BUILD_CONFIGS="vendor/${OFFICIAL_BUILD_TARGET}_GKI.config"
fi

read -r -a ACTIVE_CONFIG_ARRAY <<< "${ACTIVE_BUILD_CONFIGS}"

echo "============================================================"
echo "[+] Generating kernel configuration"
echo "============================================================"

apply_variant_configs arch/arm64/configs/gki_defconfig

make "${MAKE_ARGS[@]}" \
    gki_defconfig \
    "${ACTIVE_CONFIG_ARRAY[@]}"

if [[ "${KSU_TYPE}" == *ZeroMount* ||
      "${KSU_TYPE}" == *zeromount* ||
      "${KSU_TYPE}" == *SukiSU* ||
      "${KSU_TYPE}" == *ReSukiSU* ||
      "${KSU_TYPE}" == *nomount* ||
      "${KSU_TYPE}" == *KPM* ]]; then

    echo "[+] Enabling KernelSU / KPM / SUSFS / ZeroMount options."

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

echo "============================================================"
echo "[+] Building kernel Image"
echo "============================================================"

if ! make -j"$(nproc)" "${MAKE_ARGS[@]}" Image 2>&1 | tee build.log; then
    COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))
    ccache --show-stats || true

    echo "==== BUILD ERROR SUMMARY ===="
    grep -nE \
        ' error:|undefined reference|No rule to make target|fatal error:' \
        build.log | tail -n 80 || true

    echo "==== BUILD FAILED - LAST 200 LINES ===="
    tail -n 200 build.log || true
    exit 1
fi

COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))
ccache --show-stats || true

IMAGE_PATH="out/arch/arm64/boot/Image"

if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "[!] ERROR: Kernel Image was not generated."
    echo "[!] Expected: ${SOC}/${IMAGE_PATH}"
    exit 1
fi

BUILD_PHASE="build complete"

echo "============================================================"
echo "[+] Kernel Image built successfully"
echo "    ${SOC}/${IMAGE_PATH}"
echo "============================================================"
