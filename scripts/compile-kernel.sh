#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-scripts/compile-kernel.sh}"

[[ -f "${TARGET}" ]] || { echo "[!] Missing ${TARGET}"; exit 1; }

TMP_BLOCK="$(mktemp)"
trap 'rm -f "${TMP_BLOCK}"' EXIT

cat > "${TMP_BLOCK}" <<'BLOCK_EOF'
# ------------------------------------------------------------------
# Cross-translation-unit KernelSU declarations.
# A definition in init.c is not visible to selinux_hide.c unless the latter
# sees an extern declaration. Repair every affected C translation unit directly.
# ------------------------------------------------------------------
ensure_extern_for_ksu_symbol() {
    local symbol="$1"
    python3 - "${KSU_DIR}" "${symbol}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
symbol = sys.argv[2]
decl_re = re.compile(
    rf'(?m)^[ \t]*(?:(?:static|extern|const|volatile|__init|__read_mostly)[ \t]+)*'
    rf'bool[ \t]+{re.escape(symbol)}[ \t]*(?:=[^;]+)?;[ \t]*$'
)
use_re = re.compile(rf'\b{re.escape(symbol)}\b')
include_re = re.compile(r'(?m)^[ \t]*#include[^\n]*\n')

for path in sorted(root.rglob('*.c')):
    text = path.read_text(encoding='utf-8', errors='replace')
    if not use_re.search(text) or decl_re.search(text):
        continue
    includes = list(include_re.finditer(text))
    pos = includes[-1].end() if includes else 0
    text = text[:pos] + '\nextern bool ' + symbol + ';\n' + text[pos:]
    path.write_text(text, encoding='utf-8')
    print(f'[+] Added extern bool {symbol}; to {path}')
PY
}

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

# SUSFS/ReSukiSU can rewrite KSU files. Re-run visibility repair after all
# definitions are normalized, before final verification and compilation.
ensure_extern_for_ksu_symbol "ksu_late_loaded"
ensure_extern_for_ksu_symbol "ksu_webview_zygote_umount_enabled"

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

# Verify every C translation unit that uses these globals has a visible
# declaration. This catches the exact compile failure before the long build.
python3 - "${KSU_DIR}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

for symbol in ("ksu_late_loaded", "ksu_webview_zygote_umount_enabled"):
    bad = []
    for path in sorted(root.rglob("*.c")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if not re.search(rf"\b{re.escape(symbol)}\b", text):
            continue
        if not re.search(
            rf"(?m)^[ \t]*(?:extern[ \t]+)?bool[ \t]+{re.escape(symbol)}[ \t]*(?:=[^;]+)?;",
            text,
        ):
            bad.append(str(path))
    if bad:
        print(f"[!] ERROR: {symbol} is used without a visible bool declaration in:")
        for item in bad:
            print(f"    {item}")
        sys.exit(1)
    print(f"[OK] All C users of {symbol} have a visible declaration.")
PY

SELINUX_HIDE_C="${KSU_DIR}/feature/selinux_hide.c"
if [[ -f "${SELINUX_HIDE_C}" ]]; then
    if ! grep -Eq '^[[:space:]]*extern[[:space:]]+bool[[:space:]]+ksu_late_loaded[[:space:]]*;' "${SELINUX_HIDE_C}" &&
       ! grep -Eq '^[[:space:]]*bool[[:space:]]+ksu_late_loaded[[:space:]]*(=|;)' "${SELINUX_HIDE_C}"; then
        echo "[!] ERROR: selinux_hide.c still has no visible ksu_late_loaded declaration."
        grep -n -B 3 -A 5 "ksu_late_loaded" "${SELINUX_HIDE_C}" || true
        exit 1
    fi
    echo "[OK] selinux_hide.c can see ksu_late_loaded."
fi

echo "[OK] KernelSU source preparation completed."
BLOCK_EOF

python3 - "${TARGET}" "${TMP_BLOCK}" <<'PY'
import sys
from pathlib import Path

target = Path(sys.argv[1])
block = Path(sys.argv[2]).read_text()
text = target.read_text()
start_marker = 'INIT_C="${KSU_DIR}/core/init.c"'
end_marker = '# SCM VERSION'
start = text.find(start_marker)
end = text.find(end_marker, start + 1 if start >= 0 else 0)
if start < 0 or end < 0 or end <= start:
    raise SystemExit('[!] Could not locate the KernelSU compatibility section in scripts/compile-kernel.sh')
new = text[:start] + block.rstrip() + '\n\n' + text[end:]
target.write_text(new)
print(f'[OK] KernelSU compatibility section replaced in {target}.')
PY

bash -n "${TARGET}"
echo '[OK] Bash syntax check passed.'
