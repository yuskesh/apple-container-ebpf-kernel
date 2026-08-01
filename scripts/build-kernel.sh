#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Build an eBPF-capable arm64 Linux kernel image for Apple `container`.
#
# Run this INSIDE a Linux/arm64 build container (e.g. debian:trixie) that has
# this repository bind-mounted. See README.md for the one-liner that launches
# such a container; in short:
#
#   container exec <build-container> /work/scripts/build-kernel.sh
#
# Output: $OUT/Image-<KVER>-ebpf. Copy it to the macOS host and run
# scripts/install-kernel.sh there.
#
# Tunables (environment variables):
#   KVER         linux stable version to build           (default 7.1.5)
#   KATA_TAG     kata-containers tag for config fragments (default 4.0.0)
#   JOBS         parallel make jobs                       (default: nproc)
#   SRC          build directory (container FS, NOT a bind mount) (default /root/build)
#   OUT          where to drop the finished Image         (default /work/output)
#   OVERLAY      path to the eBPF overlay config          (default <repo>/config/ebpf-overlay.conf)
#   LOCALVERSION uname -r suffix                          (default -ebpf)
set -euo pipefail

KVER="${KVER:-7.1.5}"
KATA_TAG="${KATA_TAG:-4.0.0}"
JOBS="${JOBS:-$(nproc)}"
SRC="${SRC:-/root/build}"
OUT="${OUT:-/work/output}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="${OVERLAY:-$HERE/config/ebpf-overlay.conf}"
LOCALVERSION="${LOCALVERSION:--ebpf}"

echo ">>> kernel $KVER | kata $KATA_TAG | jobs $JOBS"
echo ">>> overlay   $OVERLAY"
[ -f "$OVERLAY" ] || { echo "!!! overlay not found: $OVERLAY"; exit 1; }
mkdir -p "$SRC" "$OUT"

# 1. Build dependencies (Debian trixie). Harmless if already present.
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    build-essential flex bison libelf-dev libssl-dev bc kmod cpio \
    python3 rsync xz-utils dwarves git wget ca-certificates >/dev/null
fi

# 2. Kernel source. Extract inside the container FS: a virtiofs bind mount trips
#    over the selftest symlinks during tar extraction.
cd "$SRC"
ktree="$SRC/linux-$KVER"
if [ ! -d "$ktree" ]; then
  echo ">>> fetching linux-$KVER"
  wget -q "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
  tar -xf "linux-$KVER.tar.xz"
fi

# 3. kata config fragments (+ a dax patch). Sparse checkout of just the kernel dir.
kata="$SRC/kata"
if [ ! -d "$kata" ]; then
  echo ">>> fetching kata-containers $KATA_TAG config fragments"
  git clone --depth 1 --branch "$KATA_TAG" --filter=blob:none --sparse \
    https://github.com/kata-containers/kata-containers "$kata"
  git -C "$kata" sparse-checkout set tools/packaging/kernel
fi
frag_dir="$kata/tools/packaging/kernel/configs/fragments"

cd "$ktree"

# kata carries a dax fix that still applies cleanly on recent kernels (7.0.x /
# 7.1.x, not yet upstream).
dax="$kata/tools/packaging/kernel/patches/6.18.x/0001-fs-dax-check-zero-or-empty-entry-before-converting-xarray.patch"
if [ -f "$dax" ] && patch -p1 --dry-run <"$dax" >/dev/null 2>&1; then
  patch -p1 <"$dax"
  echo ">>> applied kata dax patch"
fi

# 4. Config: arm64 defconfig + kata common + kata arm64 + our eBPF overlay.
make ARCH=arm64 defconfig
frags="$(find "$frag_dir/common" -maxdepth 1 -name '*.conf'; \
         find "$frag_dir/arm64"  -maxdepth 1 -name '*.conf')"
# shellcheck disable=SC2086
ARCH=arm64 scripts/kconfig/merge_config.sh -m .config $frags "$OVERLAY"
: >.scmversion   # suppress the auto "+" version suffix on a tarball tree
make ARCH=arm64 olddefconfig

# 5. Sanity: olddefconfig silently drops options with unmet deps. Fail loudly if
#    any eBPF essential did not make it into the final .config.
need="CONFIG_DEBUG_INFO_BTF=y CONFIG_SCHED_CLASS_EXT=y CONFIG_NET_SCH_BPF=y \
      CONFIG_BPF_LSM=y CONFIG_NET_SCH_NETEM=y CONFIG_XDP_SOCKETS=y \
      CONFIG_FUNCTION_ERROR_INJECTION=y"
miss=0
for kv in $need; do
  grep -qx "$kv" .config || { echo "!!! missing from .config: $kv"; miss=1; }
done
[ "$miss" = 0 ] || { echo "!!! config check failed; aborting"; exit 1; }
echo ">>> config check OK"

# 6. Build.
time make ARCH=arm64 LOCALVERSION="$LOCALVERSION" -j"$JOBS" Image

img="$OUT/Image-$KVER-ebpf"
cp arch/arm64/boot/Image "$img"
ls -lh "$img"
echo ">>> done: $img"
echo ">>> copy this to the macOS host, then run scripts/install-kernel.sh <Image>"
