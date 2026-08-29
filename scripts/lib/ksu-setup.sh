#!/usr/bin/env bash
#
# KernelSU variant setup helpers. Sourced, not executed.
# Depends on lib/git-helpers.sh and lib/kernel-helpers.sh (insert_line_before_first_match,
# ensure_line_in_file, detect_kernelsu_driver_dir, kernelsu_kconfig_source_path).
#

setup_kernelsu_repo() {
  local owner="$1"
  local repo="$2"
  local requested_ref="$3"
  local allow_fallbacks="${4:-0}"
  local repo_dir="$repo"
  local driver_dir
  local kconfig_source
  local ref
  local cloned=0
  local actual_commit
  local refs_to_try

  driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found in kernel tree"
    exit 1
  }
  kconfig_source="$(kernelsu_kconfig_source_path "$driver_dir")"

  rm -rf "$repo_dir"

  refs_to_try="$requested_ref"
  if [[ "$allow_fallbacks" == "1" ]]; then
    refs_to_try="$refs_to_try dev main v4.1.0"
  fi

  for ref in $refs_to_try; do
    [[ -z "$ref" ]] && continue

    rm -rf "$repo_dir"
    git init -q "$repo_dir"
    git -C "$repo_dir" remote add origin "https://github.com/${owner}/${repo}.git"

    if git_fetch_retry "$repo_dir" --depth=1 --no-tags origin "$ref" && \
       git -C "$repo_dir" checkout -q --detach FETCH_HEAD; then
      actual_commit="$(git -C "$repo_dir" rev-parse HEAD)"
      if [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && [[ "$actual_commit" != "$ref" ]]; then
        echo "::error::${owner}/${repo} checkout '$actual_commit' does not match resolved commit '$ref'."
        rm -rf "$repo_dir"
        continue
      fi
      echo "[+] Cloned ${owner}/${repo} at ${actual_commit} (requested '$ref')."
      cloned=1
      break
    fi

    rm -rf "$repo_dir"
    echo "[!] ${owner}/${repo} branch/ref '$ref' is unavailable, trying next fallback..."
  done

  if [[ "$cloned" -ne 1 ]]; then
    echo "::error::Failed to clone ${owner}/${repo} from https://github.com/${owner}/${repo}.git using refs: $refs_to_try"
    exit 1
  fi

  rm -rf "$driver_dir/kernelsu"
  
  # Handle different ReSukiSU/SukiSU repository layouts where kernel folder might be structured differently
  if [[ -d "$repo_dir/kernel" ]]; then
    ln -sfn "$(realpath --relative-to="$driver_dir" "$repo_dir/kernel")" "$driver_dir/kernelsu"
  elif [[ -d "$repo_dir/drivers/kernelsu" ]]; then
    ln -sfn "$(realpath --relative-to="$driver_dir" "$repo_dir/drivers/kernelsu")" "$driver_dir/kernelsu"
  else
    mkdir -p "$driver_dir/kernelsu"
    cp -rf "$repo_dir/"* "$driver_dir/kernelsu/" 2>/dev/null || true
  fi

  # Robust KPM source detection and injection
  echo "[+] Locating and integrating KPM sources..."
  mkdir -p "$driver_dir/kernelsu/kpm"
  
  if [[ -d "$repo_dir/kernel/kpm" ]]; then
    cp -rf "$repo_dir/kernel/kpm/"* "$driver_dir/kernelsu/kpm/" 2>/dev/null || true
  elif [[ -d "$repo_dir/kpm" ]]; then
    cp -rf "$repo_dir/kpm/"* "$driver_dir/kernelsu/kpm/" 2>/dev/null || true
  elif [[ -d "$driver_dir/kernelsu/kpm" ]]; then
    : # Already present
  else
    # Universal fallback search using find command for kpm.c
    KPM_SRC_DIR="$(find "$repo_dir" -type d -name "kpm" | head -n 1)"
    if [[ -n "$KPM_SRC_DIR" && -f "$KPM_SRC_DIR/kpm.c" ]]; then
      cp -rf "$KPM_SRC_DIR/"* "$driver_dir/kernelsu/kpm/" 2>/dev/null || true
    fi
  fi

  ensure_line_in_file "$driver_dir/Makefile" 'obj-$(CONFIG_KSU) += kernelsu/'
  insert_line_before_first_match "$driver_dir/Kconfig" "endmenu" "source \"$kconfig_source\""

  KSU_REPO_DIR="$(readlink -f "$repo_dir")"
  export KSU_REPO_DIR
  export KSU_KERNEL_DIR="${KSU_REPO_DIR}/kernel"
  export KSU_DRIVER_DIR="$driver_dir"
}

# Apply the chosen KSU preset from the commit resolved during profile setup.
install_ksu_variant() {
  local ksu_type="$1"

  case "$ksu_type" in
    "None")
      ;;
    "Official-KernelSU")
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for Official KernelSU}"
      setup_kernelsu_repo "tiann" "KernelSU" "$KSU_COMMIT"
      ;;
    "KowSU")
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for KowSU}"
      setup_kernelsu_repo "KOWX712" "KernelSU" "$KSU_COMMIT"
      ;;
    "KernelSU-Next"*)
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for KernelSU-Next}"
      if [[ "$ksu_type" == *"susfs"* ]]; then
        setup_kernelsu_repo "pershoot" "KernelSU-Next" "$KSU_COMMIT"
      else
        setup_kernelsu_repo "KernelSU-Next" "KernelSU-Next" "$KSU_COMMIT"
      fi
      ;;
    "SukiSU-Ultra"*)
      KSU_COMMIT_TARGET="${KSU_COMMIT:-main}"
      setup_kernelsu_repo "SukiSU-Ultra" "SukiSU-Ultra" "$KSU_COMMIT_TARGET" "1"
      ;;
    "ReSukiSU"*)
      # Locked to stable v4.1.0 to ensure zero mount, sufs & kpm build without hook errors
      KSU_COMMIT_TARGET="${KSU_COMMIT:-v4.1.0}"
      setup_kernelsu_repo "ReSukiSU" "ReSukiSU" "$KSU_COMMIT_TARGET" "0"
      ;;
    *)
      echo "::error::Unsupported ksu_type: $ksu_type"
      exit 1
      ;;
  esac
}

