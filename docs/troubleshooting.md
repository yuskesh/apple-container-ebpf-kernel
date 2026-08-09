# Troubleshooting

The traps that actually cost time when building this kernel, and how to get past
them.

## BTF silently doesn't appear

`CONFIG_DEBUG_INFO_BTF=y` only sticks if a three-link chain is satisfied, and
`make olddefconfig` drops it **without any error or warning** if it isn't:

1. `DEBUG_INFO` is a *choice* (DWARF4 / DWARF5 / NONE), not a bool. You must
   select a DWARF variant — the overlay sets `CONFIG_DEBUG_INFO_DWARF5=y`.
2. arm64 `defconfig` ships `CONFIG_DEBUG_INFO_REDUCED=y`, which is mutually
   exclusive with BTF. The overlay disables it
   (`# CONFIG_DEBUG_INFO_REDUCED is not set`).
3. Only with both of the above does `CONFIG_DEBUG_INFO_BTF=y` survive.

**Always** `grep -x CONFIG_DEBUG_INFO_BTF=y .config` after `olddefconfig`.
`build-kernel.sh` does this and aborts if it fails.

You also need `pahole` (Debian package `dwarves`) installed at build time, or the
DWARF→BTF step is skipped.

## struct_ops targets disappear together

`CONFIG_SCHED_CLASS_EXT` (sched_ext) and `CONFIG_NET_SCH_BPF` (BPF qdisc) both
depend on BTF. If BTF drops (above), both drop with it and the failure looks like
"sched_ext isn't in my kernel" rather than "BTF is missing". Fix BTF first, then
re-check these.

## The BPF LSM loads but never fires; fmod_ret won't attach

Two separate causes:

- **`bpf` isn't in the active `lsm=` list.** The VM runtime passes its own `lsm=`
  on the kernel command line, which overrides `CONFIG_LSM` and does not include
  `bpf`. Since Apple `container` 1.2.0
  ([apple/container#1744](https://github.com/apple/container/pull/1744)) that
  default can be replaced **per run**:

  ```sh
  container run --kernel-arg lsm=lockdown,capability,landlock,yama,apparmor,bpf …
  ```

  Pass the full list — a user-supplied `lsm=` replaces the default verbatim, so
  naming only `bpf` would silently drop `landlock`/`yama`/`apparmor`. The flag
  must be on **every** run that uses `SEC("lsm/…")`; without it the container
  boots fine and LSM programs attach but never fire (`setup-bpf-env.sh` warns
  when it detects this). On `container` <= 1.1.x the flag does not exist; arm64
  has no `CMDLINE_EXTEND`, so the only option there was baking the entire
  command line into the image with `CONFIG_CMDLINE_FORCE` (what this repo did
  before the 1.2 bump — see the repo history), at the price that a stale forced
  string prevents the guest from booting.
- **No `fmod_ret`-able targets.** `fmod_ret` needs
  `CONFIG_FUNCTION_ERROR_INJECTION=y` (plus `CONFIG_BPF_KPROBE_OVERRIDE=y`) for
  there to be any attachable functions. `fmod_ret` does **not** need `bpf` in
  the `lsm=` list — only `SEC("lsm/…")` does.

Confirm it worked: `/sys/kernel/security/lsm` should list `bpf`. The runtime does
not mount securityfs, so that file does not exist until you mount it yourself —
which needs `CAP_SYS_ADMIN`:

```sh
container run --rm --cap-add SYS_ADMIN \
  --kernel-arg lsm=lockdown,capability,landlock,yama,apparmor,bpf \
  docker.io/library/debian:trixie sh -c \
  'mount -t securityfs securityfs /sys/kernel/security && cat /sys/kernel/security/lsm'
# -> capability,landlock,bpf
```

`verify-kernel.sh` does this for you. Note the list only ever contains LSMs that
are actually built in, so it is a subset of the `lsm=` on the command line —
`bpf` being there is the thing to check, not an exact match.

### `--kernel-arg` seems to have no effect

If `cat /proc/cmdline` inside the guest does not show the arguments you passed,
you are almost certainly booting an image built before the `container` 1.2 bump:
those set `CONFIG_CMDLINE_FORCE`, which makes the kernel ignore everything the
runtime passes — including your `--kernel-arg` flags — and report its own baked
string back. Rebuild from the current overlay (which no longer forces a command
line), or check which image is installed with `container system` and re-run
`scripts/install-kernel.sh`.

## `tar` fails extracting the kernel source

Extracting `linux-X.Y.Z.tar.xz` onto a bind-mounted (virtiofs) directory throws
permission errors on the selftest symlinks. Extract inside the container
filesystem (e.g. `/root/build`) and copy only the finished `Image` out to the
mount.

## My new kernel "didn't take"

The kernel set applies to **new** `container run` instances only — existing
containers keep the kernel they snapshotted when the runtime started. Start a
fresh container to test, and restart the runtime with
`container system start --disable-kernel-install` so it keeps your kernel instead
of installing an official one.

Prefer `container system kernel set --binary <Image>` (a raw image) over the
`--tar` form, which has had issues with compressed/relative-path archives.

## netem says "unavailable" in verify

`tc qdisc … netem …` needs `CAP_NET_ADMIN`, which `verify-kernel.sh` does not add
(it only takes `SYS_ADMIN`, to mount securityfs). Test netem explicitly:

```sh
container run --rm --cap-add NET_ADMIN docker.io/library/debian:trixie sh -c \
  'apt-get update -qq && apt-get install -y -qq iproute2 &&
   tc qdisc add dev lo root netem loss 5% && tc qdisc del dev lo root && echo netem-ok'
```

(Stock `debian:trixie` does not ship `tc`, hence the `iproute2` install first.)

## `tracefs not found` (BPF tracepoint programs fail)

```
WARN failed to attach BPF program program="trace_sys_enter_execve" error=tracefs not found
```

**Root cause:** Apple's `container` runtime mounts `/sys` and `/proc` but does
not mount `tracefs`, `securityfs`, or `bpffs`. The kernel has tracing enabled,
but the filesystem interface is not exposed to userspace.

**Fix:** Run `scripts/setup-bpf-env.sh` inside the container before loading any
BPF programs that use tracepoints, kprobes, or map pinning:

```sh
# one-shot
container run --rm --cap-add ALL \
  --mount type=bind,source="$PWD/scripts",target=/scripts \
  debian:trixie sh -c '/scripts/setup-bpf-env.sh && your-bpf-program'

# or inside an already-running container
container exec <container> /work/scripts/setup-bpf-env.sh
```

The script mounts `tracefs` at `/sys/kernel/tracing`, `securityfs` at
`/sys/kernel/security`, and `bpf` at `/sys/fs/bpf`. You need at minimum
`--cap-add SYS_ADMIN` (or `--cap-add ALL`) for the mounts to succeed.
