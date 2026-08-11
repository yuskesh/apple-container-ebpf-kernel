# apple-container-ebpf-kernel

Build a custom Linux kernel with a **full eBPF feature set** and run it under
[Apple `container`](https://github.com/apple/container) on Apple Silicon macOS.

Apple `container` (and most off-the-shelf macOS Linux VMs) ship a kernel that is
missing the pieces serious eBPF work needs — no BTF, no `sched_ext`, no
`struct_ops` qdisc, sometimes no `kprobes`/`uprobes` at all. This repo is a small
config overlay plus three scripts that build a stock Linux stable kernel
(currently **7.1.8**, arm64) with all of that turned on, and install it into the
`container` runtime.

## What you get

A kernel with, verified present:

- **BTF** (`/sys/kernel/btf/vmlinux`) — required for CO-RE and `struct_ops`.
- **BPF `struct_ops`** targets: `sched_ext` (CPU schedulers in BPF), BPF qdisc
  (`Qdisc_ops`, Linux 7.0+), and TCP congestion ops.
- The **BPF JIT** (always-on) and `BPF_SYSCALL`/`BPF_EVENTS`.
- The full **tracing stack**: kprobes, kretprobes, uprobes, fprobe, ftrace,
  tracepoints, syscall tracepoints.
- **netem** packet impairment (`tc qdisc … netem loss/delay …`) for latency and
  loss testing, plus the common classful qdiscs and BPF/u32 classifiers.
- The **BPF LSM** with `fmod_ret` error injection (so `SEC("lsm/<hook>")` and
  `fmod_ret` programs actually fire — the bpf LSM is activated per run with
  `--kernel-arg`, see below).
- **AF_XDP** socket maps (`XSKMAP`/`DEVMAP`) so `xsk_redirect` programs load.

The exact set is in [`config/ebpf-overlay.conf`](config/ebpf-overlay.conf), which
is heavily commented with the rationale and the dependency gotchas.

## Requirements

- Apple Silicon Mac. Upstream supports `container` on **macOS 26** and states it
  does not support older releases, so that is the floor here too.
- [Apple `container`](https://github.com/apple/container) **1.2.0 or newer**
  (`brew install container`). The bpf LSM is activated per run via
  `--kernel-arg`, which was added in 1.2.0
  ([apple/container#1744](https://github.com/apple/container/pull/1744)); on
  older releases everything else in the kernel still works, but there is no way
  to add `bpf` to the active LSM list short of force-baking the whole command
  line into the image (what this repo did before the 1.2 bump — see the caveats).
- ~15 GB free disk and a few minutes (a full build took **9 minutes** on an M1
  Max with `-j8`; see [Verified with](#verified-with)).
- The kernel itself is built **inside a Linux/arm64 build container**
  (`debian:trixie`); you do not need a cross-toolchain on the host.

## Quick start

```sh
# 0. clone this repo somewhere, e.g. ~/apple-container-ebpf-kernel
cd ~/apple-container-ebpf-kernel

# 1. launch a long-lived build container with this repo mounted at /work
container run -d --name kbuild --cap-add ALL -c 8 -m 8G \
  --mount type=bind,source="$PWD",target=/work \
  -w /work docker.io/library/debian:trixie sleep infinity

# 2. build the kernel (downloads the kernel source + kata config fragments,
#    merges the overlay, builds arch/arm64/boot/Image)
container exec kbuild /work/scripts/build-kernel.sh
#    -> writes /work/output/Image-7.1.8-ebpf

# 3. install it into the runtime (host side) and restart keeping the kernel
./scripts/install-kernel.sh ./output/Image-7.1.8-ebpf
container system start --disable-kernel-install

# 4. verify the feature set on a throwaway container
./scripts/verify-kernel.sh
```

Expected `verify-kernel.sh` output (abridged):

```
uname:     7.1.8-ebpf
cmdline:   console=hvc0 tsc=reliable panic=0 lsm=lockdown,capability,landlock,yama,apparmor,bpf oops=panic init=/sbin/vminitd ro rootfstype=ext4 root=/dev/vda
BTF:       present (10883894 bytes)
sched_ext: present
bpffs:      present (not mounted — run setup-bpf-env.sh)
lsm:       capability,landlock,bpf
struct_ops in BTF:
  bpf_struct_ops_Qdisc_ops
  bpf_struct_ops_sched_ext_ops
  bpf_struct_ops_tcp_congestion_ops
```

The `cmdline:` line is the runtime's real command line — nothing is baked into
the image anymore — with the `lsm=` list replaced by the one passed via
`--kernel-arg` (that is `verify-kernel.sh` doing it; note `bpf` at the end).

The `lsm:` line lists the LSMs that are **actually active**, which is only ever a
subset of the `lsm=` on the kernel command line — the kernel silently ignores any
LSM that is not built in. `bpf` being present is the part that matters: it is the
proof that the `--kernel-arg lsm=` override took effect. The exact rest of the
list varies with the kata fragments you build against, so do not treat it as a
fingerprint.

## Running BPF programs

Apple's `container` runtime mounts `/sys` and `/proc` but does **not** mount
`tracefs`, `securityfs`, or `bpffs`. Without these, tracepoint-based BPF programs
fail with `error=tracefs not found`.

Run `scripts/setup-bpf-env.sh` inside the container to mount them before loading
any BPF programs:

```sh
# one-shot: set up the environment, then run your program
container run --rm --cap-add ALL \
  --mount type=bind,source="$PWD/scripts",target=/scripts \
  debian:trixie sh -c '/scripts/setup-bpf-env.sh && your-bpf-program'
```

Or in an already-running container:

```sh
container exec <container> /work/scripts/setup-bpf-env.sh
# then load / attach your BPF programs as usual
```

If the program uses the **BPF LSM** (`SEC("lsm/<hook>")`), additionally start the
container with the bpf LSM active — it is off by default and per run:

```sh
container run --rm --cap-add ALL \
  --kernel-arg lsm=lockdown,capability,landlock,yama,apparmor,bpf \
  debian:trixie sh -c '/scripts/setup-bpf-env.sh && your-lsm-program'
```

Pass the **full list**: a user-supplied `lsm=` replaces the runtime default
verbatim, so naming only `bpf` would silently drop `landlock`/`yama`/`apparmor`.
Without the flag the container boots fine, but LSM programs attach and never
fire — `setup-bpf-env.sh` prints a warning when it detects this. Only
`SEC("lsm/…")` needs the flag; `fmod_ret`, kprobes, tracepoints, XDP and
everything else work without it.

The setup script mounts:

| Filesystem     | Mount point             | Purpose                                |
| -------------- | ----------------------- | -------------------------------------- |
| `tracefs`      | `/sys/kernel/tracing`   | Tracepoint/kprobe attachment for BPF   |
| `securityfs`   | `/sys/kernel/security`  | Read `/sys/kernel/security/lsm`        |
| `bpf`          | `/sys/fs/bpf`           | Pin BPF maps and programs across procs |

## How it works

The build is a three-way config merge:

```
arm64 defconfig
  + kata-containers config fragments   (virtio drivers, ext4, the boot console,
  |                                      everything needed to boot under the VM)
  + config/ebpf-overlay.conf           (this repo: BTF + struct_ops + tracing +
                                         netem + BPF LSM + AF_XDP)
  -> merge_config.sh -> olddefconfig -> make Image
```

The kata fragments supply the drivers and boot expectations that make the kernel
bootable inside the lightweight VM; the overlay layers the eBPF capabilities on
top. `build-kernel.sh` fetches both, runs the merge, **asserts the eBPF
essentials survived `olddefconfig`** (it silently drops options with unmet
dependencies), and builds the image.

Installation uses `container system kernel set --binary … --force`. Using
`--binary` (a raw `Image`) avoids known issues with the `--tar` path.

## Repo layout

```
config/ebpf-overlay.conf   the eBPF Kconfig overlay (the core of this repo)
scripts/build-kernel.sh    build the Image inside a debian:trixie container
scripts/install-kernel.sh  install the Image into Apple container (host)
scripts/verify-kernel.sh   probe the running kernel for the feature set (host)
scripts/setup-bpf-env.sh   mount tracefs/securityfs/bpffs for BPF programs
docs/build-workflow.md     the end-to-end build, in detail
docs/troubleshooting.md    the dependency traps and boot pitfalls
```

## Verified with

Everything below was measured end to end — build, install, boot, verify — on this
combination. It is not a compatibility claim for anything else.

| Component | Version | How it was checked |
|---|---|---|
| macOS | 26.5.2 (25F84), Apple M1 Max | `sw_vers` |
| Apple `container` | 1.2.2 | `container --version` |
| `containerization` | 0.40.1 | exact pin of `container` 1.2.2 (`Package.resolved`) |
| Linux kernel | 7.1.8 (`7.1.8-ebpf`) | built here, then `verify-kernel.sh` |
| kata fragments | 4.0.0 | `KATA_TAG` default in `build-kernel.sh` |
| Build | 8m56s, `-j8`, 69 MB `Image` | `time make … Image` |
| Date | 2026-08-02 | |

**Why this table exists.** Before the `container` 1.2 bump this repo force-baked
the runtime's entire kernel command line into the image, and a runtime release
that changed that line would have stopped the guest from booting — the table was
the record of which release the baked string was read from. That coupling is
gone: the image no longer forces a command line, and the bpf LSM rides on the
`--kernel-arg` flag instead. What remains version-coupled is only that flag
itself (`container` >= 1.2.0) and the runtime's *default* `lsm=` list, which the
recommended override restates verbatim plus `,bpf`:

```
lsm=lockdown,capability,landlock,yama,apparmor,bpf
```

If a future `container` release changes its default LSM set, update the list in
your `--kernel-arg` (and in `verify-kernel.sh`) to match — worst case is a
missing LSM at runtime, not an unbootable guest.

## Important caveats

- **The new kernel only affects new `container run` instances.** Existing
  containers snapshot their kernel when the runtime starts.
- **The BPF LSM is per-run and opt-in.** Runs without
  `--kernel-arg lsm=…,bpf` boot fine, but `SEC("lsm/<hook>")` programs attach
  and silently never fire. `setup-bpf-env.sh` warns when the bpf LSM is
  inactive; `verify-kernel.sh` shows the active list.
- **Images built before the 1.2 bump ignore `--kernel-arg`.** Those images were
  built with `CONFIG_CMDLINE_FORCE`, which overrides whatever the runtime
  passes — including your flags. If `verify-kernel.sh` shows a `cmdline:` that
  does not contain the arguments you passed, you are booting one of those old
  images; rebuild from this overlay.
- See [`docs/troubleshooting.md`](docs/troubleshooting.md) for the BTF dependency
  chain and other traps.

## Bumping the kernel version

The overlay is version-independent. To build a newer stable release, pass `KVER`:

```sh
container exec kbuild env KVER=7.2.0 /work/scripts/build-kernel.sh
```

Patch-level bumps reuse the same overlay via `olddefconfig` with no changes.

Note that **7.1.x is a plain stable line, not a longterm one** — it stops getting
fixes once the next stable line lands, so expect to bump `KVER` periodically
rather than settling on it. Pick a longterm release instead if you want to sit
still; the overlay does not care either way.

The kata fragments are pinned separately via `KATA_TAG` (default `4.0.0`), and
`build-kernel.sh` also applies kata's dax patch from `patches/6.18.x/` if it still
applies. Both are deliberately pinned rather than tracking `main`: the fragments
decide what actually survives `olddefconfig`, so an unreviewed bump can silently
drop an eBPF option. The build asserts the essentials either way and fails loudly
if one goes missing.

## License

Dual-licensed under **MIT OR Apache-2.0** — see [LICENSE-MIT](LICENSE-MIT) and
[LICENSE-APACHE](LICENSE-APACHE); use whichever you prefer (Apache-2.0 adds an
explicit patent grant; MIT is GPLv2-compatible). The config overlay references
upstream Linux Kconfig symbols; the Linux kernel itself is GPLv2 and is
downloaded at build time, not redistributed here.
