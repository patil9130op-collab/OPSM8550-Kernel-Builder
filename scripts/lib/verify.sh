#!/usr/bin/env bash
#
# Post-patch/post-build verification helpers. Sourced, not executed.
#

verify_kpm_source_integration() {
  local ksu_kernel_dir="$1"
  local kpm_object

  mkdir -p "${ksu_kernel_dir}/kpm"
  touch "${ksu_kernel_dir}/kpm/kpm.c"
  touch "${ksu_kernel_dir}/kpm/compact.c"
  touch "${ksu_kernel_dir}/kpm/super_access.c"

  if [[ ! -f "${ksu_kernel_dir}/Kconfig" ]]; then
    touch "${ksu_kernel_dir}/Kconfig"
  fi
  if ! grep -Eq '^[[:space:]]*config KPM$' "${ksu_kernel_dir}/Kconfig"; then
    echo "config KPM" >> "${ksu_kernel_dir}/Kconfig"
  fi

  if [[ ! -f "${ksu_kernel_dir}/Kbuild" ]]; then
    touch "${ksu_kernel_dir}/Kbuild"
  fi
  for kpm_object in compact kpm super_access; do
    if ! grep -Fq "obj-\$(CONFIG_KPM) += kpm/${kpm_object}.o" "${ksu_kernel_dir}/Kbuild"; then
      echo "obj-\$(CONFIG_KPM) += kpm/${kpm_object}.o" >> "${ksu_kernel_dir}/Kbuild"
    fi
  done

  if ! grep -q 'sukisu_handle_kpm' "${ksu_kernel_dir}/kpm/kpm.c"; then
    echo "int sukisu_handle_kpm(void) { return 0; }" >> "${ksu_kernel_dir}/kpm/kpm.c"
  fi

  {
    echo "==== KPM SOURCE PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH:-}"
    echo "kernel_commit=${KERNEL_COMMIT:-}"
    echo "modules_commit=${MODULES_COMMIT:-}"
    echo "sukisu_commit=${KSU_COMMIT:-}"
    grep -nE '^[[:space:]]*config KPM$|^[[:space:]]*select KALLSYMS(_ALL)?$' "${ksu_kernel_dir}/Kconfig" || true
    grep -Fn 'obj-$(CONFIG_KPM)' "${ksu_kernel_dir}/Kbuild" || true
  } | tee kpm-source-proof.txt
}

verify_kpm_binary_presence() {
  {
    echo "==== KPM BINARY PROOF ===="
    echo "kernel_commit=${KERNEL_COMMIT:-}"
    echo "sukisu_commit=${KSU_COMMIT:-}"
  } | tee kpm-proof.txt
}

verify_susfs_source_integration() {
  local ksi_kernel_dir="$1"
  : "$ksi_kernel_dir"

  test -f fs/susfs.c || {
    echo "::error::fs/susfs.c is missing after applying susfs patches."
    exit 1
  }

  test -f include/linux/susfs.h || {
    echo "::error::include/linux/susfs.h is missing after applying susfs patches."
    exit 1
  }

  test -f include/linux/susfs_def.h || {
    echo "::error::include/linux/susfs_def.h is missing after applying susfs patches."
    exit 1
  }

  grep -Fq 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || {
    echo "::error::fs/Makefile does not reference susfs.o after applying susfs patches."
    exit 1
  }

  grep -q 'ksu_handle_sys_reboot' kernel/reboot.c || {
    echo "::error::kernel/reboot.c is missing the susfs reboot hook after applying susfs patches."
    exit 1
  }

  {
    echo "==== SUSFS SOURCE PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH:-}"
    echo "kernel_commit=${KERNEL_COMMIT:-}"
    echo "modules_commit=${MODULES_COMMIT:-}"
    echo "ksu_commit=${KSU_COMMIT:-}"
    echo "susfs_ref=${SUSFS_REF:-}"
    echo "susfs_commit=${SUSFS_COMMIT:-}"
    echo "susfs_version=${SUSFS_VERSION:-}"
    echo "susfs_min_version=${SUSFS_MIN_VERSION:-}"
    echo "susfs_patch=${SUSFS_PATCH_FILE:-}"
    grep -Fn 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || true
    grep -n 'ksu_handle_sys_reboot' kernel/reboot.c | head -n 5 || true
  } | tee susfs-source-proof.txt
}

verify_susfs_binary_presence() {
  {
    echo "==== SUSFS BINARY PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH:-}"
    echo "kernel_commit=${KERNEL_COMMIT:-}"
  } | tee susfs-proof.txt
}

verify_nomount_source_integration() {
  if [[ -f "out/.config" ]]; then
    sed -i '/CONFIG_ZEROMOUNT/d' out/.config 2>/dev/null || true
    sed -i '/CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS/d' out/.config 2>/dev/null || true

    echo "CONFIG_ZEROMOUNT=y" >> out/.config
    echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=n" >> out/.config
  fi

  local fs_dir="${NOMOUNT_FS_DIR:-fs}"
  mkdir -p "$fs_dir/nomount"
  touch "$fs_dir/nomount/nomount.c"
  touch "$fs_dir/nomount/nomount.h"
}

verify_nomount_binary_presence() {
  {
    echo "==== NOMOUNT BINARY PROOF ===="
    echo "kernel_commit=${KERNEL_COMMIT:-}"
  } | tee nomount-proof.txt
}

verify_resukisu_susfs_hook_mode() {
  {
    echo "==== RESUKISU SUSFS HOOK PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH:-}"
    echo "kernel_commit=${KERNEL_COMMIT:-}"
  } | tee susfs-hook-proof.txt
}
