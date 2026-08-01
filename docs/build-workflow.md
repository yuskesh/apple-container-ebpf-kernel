# Build workflow

This is the end-to-end process `scripts/build-kernel.sh` automates, written out
so you can run it by hand or adapt it. Everything happens on an Apple Silicon Mac
with Apple `container` installed; the kernel is compiled inside a Linux/arm64
`debian:trixie` container.

## 1. Launch a build container

```sh
container run -d --name kbuild --cap-add ALL -c 8 -m 8G \
  --mount type=bind,source="$PWD",target=/work \
  -w /work docker.io/library/debian:trixie sleep infinity
```

`--cap-add ALL` is convenient for a build box. The repo is mounted at `/work`;
the finished image lands in `/work/output` so it is visible from the host.

## 2. Install build dependencies (inside the container)

```sh
apt-get update
apt-get install -y --no-install-recommends \
  build-essential flex bison libelf-dev libssl-dev bc kmod cpio \
  python3 rsync xz-utils dwarves git wget ca-certificates
```

`dwarves` provides `pahole`, which generates BTF from DWARF during the build.

## 3. Fetch the kernel source

```sh
mkdir -p /root/build && cd /root/build
wget https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.5.tar.xz
tar -xf linux-7.1.5.tar.xz
```

Extract inside the container filesystem (`/root/build`), **not** on the
bind-mounted `/work`: the kernel selftests contain symlinks that fail to extract
over virtiofs.

## 4. Fetch the kata config fragments

The kata-containers project maintains a curated set of Kconfig fragments for
running Linux inside a lightweight VM (virtio drivers, the right console, ext4
root, etc.). A sparse checkout pulls only the kernel packaging directory:

```sh
cd /root/build
git clone --depth 1 --branch 4.0.0 --filter=blob:none --sparse \
  https://github.com/kata-containers/kata-containers kata
git -C kata sparse-checkout set tools/packaging/kernel
```

kata also carries a small dax fix that still applies cleanly to recent kernels
(7.0.x / 7.1.x, not yet upstream). Apply it if it applies:

```sh
cd /root/build/linux-7.1.5
patch -p1 --dry-run < /root/build/kata/tools/packaging/kernel/patches/6.18.x/0001-fs-dax-check-zero-or-empty-entry-before-converting-xarray.patch \
  && patch -p1 < /root/build/kata/tools/packaging/kernel/patches/6.18.x/0001-fs-dax-check-zero-or-empty-entry-before-converting-xarray.patch
```

## 5. Merge the configuration

```sh
make ARCH=arm64 defconfig

frags="$(find /root/build/kata/tools/packaging/kernel/configs/fragments/common -maxdepth 1 -name '*.conf'; \
         find /root/build/kata/tools/packaging/kernel/configs/fragments/arm64  -maxdepth 1 -name '*.conf')"

ARCH=arm64 scripts/kconfig/merge_config.sh -m .config $frags /work/config/ebpf-overlay.conf
make ARCH=arm64 olddefconfig
```

`merge_config.sh -m` layers the fragments without running `olddefconfig`; the
explicit `olddefconfig` afterwards resolves the final tree.

## 6. Confirm the eBPF options survived

`olddefconfig` **silently drops** any symbol whose dependencies are unmet, so
always check the ones that matter:

```sh
for kv in CONFIG_DEBUG_INFO_BTF=y CONFIG_SCHED_CLASS_EXT=y CONFIG_NET_SCH_BPF=y \
          CONFIG_BPF_LSM=y CONFIG_NET_SCH_NETEM=y CONFIG_XDP_SOCKETS=y \
          CONFIG_FUNCTION_ERROR_INJECTION=y; do
  grep -qx "$kv" .config && echo "ok  $kv" || echo "DROPPED  $kv"
done
```

If `CONFIG_DEBUG_INFO_BTF` is missing, the struct_ops targets are gone with it —
see [troubleshooting.md](troubleshooting.md).

## 7. Build

```sh
: > .scmversion                      # suppress the auto "+" suffix on a tarball
time make ARCH=arm64 LOCALVERSION=-ebpf -j8 Image
cp arch/arm64/boot/Image /work/output/Image-7.1.5-ebpf
```

A full build took 9 minutes on an M1 Max with `-j8`. The image is larger than a
stock VM kernel (69 MB) because it carries debug info and BTF.

## 8. Install and restart (host)

```sh
container system kernel set --binary ./output/Image-7.1.5-ebpf --arch arm64 --force
container system start --disable-kernel-install
```

`--disable-kernel-install` keeps your custom kernel instead of fetching an
official one. The new kernel applies to **new** `container run` instances only.

## 9. Verify

```sh
container run --rm docker.io/library/alpine:3.24 uname -r          # -> 7.1.5-ebpf
container run --rm docker.io/library/alpine:3.24 sh -c \
  'ls /sys/kernel/btf/vmlinux && ls -d /sys/kernel/sched_ext/'
```

Or just run `scripts/verify-kernel.sh`, which also enumerates the `struct_ops`
types present in BTF.

## Rolling back

Keep your previous working `Image` (or the runtime's original kernel) and
re-run `container system kernel set --binary <old-image> --arch arm64 --force`.
