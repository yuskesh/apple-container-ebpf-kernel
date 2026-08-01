#!/usr/bin/env sh
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Mount tracefs, securityfs, and bpffs so BPF programs can attach to
# tracepoints and pin maps.  Run this inside the container *before* loading
# any BPF programs that use tracepoints, kprobes, or map pinning.
#
# Requires SYS_ADMIN capability (or --cap-add ALL).
set -eu

# tracefs — required for tracepoint-based BPF program attachment
if mountpoint -q /sys/kernel/tracing 2>/dev/null; then
  echo "tracefs:    already mounted"
elif [ -d /sys/kernel/tracing ]; then
  mount -t tracefs tracefs /sys/kernel/tracing
  echo "tracefs:    mounted"
else
  echo "tracefs:    FAILED — /sys/kernel/tracing not found" >&2
  exit 1
fi


# securityfs — needed to read /sys/kernel/security/lsm
if mountpoint -q /sys/kernel/security 2>/dev/null; then
  echo "securityfs: already mounted"
elif [ -d /sys/kernel/security ]; then
  mount -t securityfs securityfs /sys/kernel/security
  echo "securityfs: mounted"
else
  echo "securityfs: FAILED — /sys/kernel/security not found" >&2
  exit 1
fi

# Warn early when the bpf LSM is not active: SEC("lsm/<hook>") programs would
# attach but never fire. Activation is per run and needs container >= 1.2.0:
#   container run --kernel-arg lsm=lockdown,capability,landlock,yama,apparmor,bpf ...
case ",$(cat /sys/kernel/security/lsm 2>/dev/null)," in
  *,bpf,*)
    echo "bpf lsm:    active"
    ;;
  *)
    echo "bpf lsm:    NOT active — SEC(\"lsm/...\") programs will not fire" >&2
    echo "            (re-run the container with --kernel-arg lsm=lockdown,capability,landlock,yama,apparmor,bpf)" >&2
    ;;
esac

# bpffs — required for BPF map pinning (pinning to /sys/fs/bpf/...)
if mountpoint -q /sys/fs/bpf 2>/dev/null; then
  echo "bpffs:      already mounted"
elif [ -d /sys/fs/bpf ]; then
  mount -t bpf bpf /sys/fs/bpf
  echo "bpffs:      mounted"
else
  echo "bpffs:      FAILED — /sys/fs/bpf not found" >&2
  exit 1
fi
