#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Verify the currently installed kernel has the eBPF feature set. Run on the
# macOS host; it spawns a throwaway container on the active kernel.
#
# Needs Apple `container` >= 1.2.0: the bpf LSM is activated per run with
# --kernel-arg (apple/container#1744). On older releases the flag does not exist
# and this script fails to start the probe container.
#
# Tunables:
#   IMAGE   container image to probe with (default debian:trixie)
set -euo pipefail

IMAGE="${IMAGE:-docker.io/library/debian:trixie}"

# The full runtime default lsm= list plus bpf; a user-supplied lsm= replaces the
# default verbatim, so listing only bpf would drop landlock/yama/apparmor.
LSM_ARG="lsm=lockdown,capability,landlock,yama,apparmor,bpf"

# SYS_ADMIN is needed for one thing only: mounting securityfs, without which the
# active LSM list is unreadable and the `bpf` LSM cannot be verified at all.
container run --rm --cap-add SYS_ADMIN --kernel-arg "$LSM_ARG" "$IMAGE" sh -c '
  set -e
  echo "uname:     $(uname -r)"
  echo "cmdline:   $(cat /proc/cmdline)"

  if [ -s /sys/kernel/btf/vmlinux ]; then
    echo "BTF:       present ($(wc -c </sys/kernel/btf/vmlinux) bytes)"
  else
    echo "BTF:       MISSING"
  fi

  if [ -d /sys/kernel/sched_ext ]; then
    echo "sched_ext: present"
  else
    echo "sched_ext: MISSING"
  fi


  # bpffs — needed for BPF map pinning
  if mountpoint -q /sys/fs/bpf 2>/dev/null; then
    echo "bpffs:      mounted"
  elif [ -d /sys/fs/bpf ]; then
    echo "bpffs:      present (not mounted — run setup-bpf-env.sh)"
  else
    echo "bpffs:      MISSING"
  fi

  # The active LSM list; shows "bpf" only if the --kernel-arg lsm= override took
  # effect. The runtime does not mount securityfs, so mount it here or the list
  # is invisible. The list contains only LSMs actually built in, so it is a
  # subset of the lsm= on the command line -- `bpf` being present is what matters.
  mount -t securityfs securityfs /sys/kernel/security 2>/dev/null || true
  echo "lsm:       $(cat /sys/kernel/security/lsm 2>/dev/null || echo "(securityfs unavailable; needs CAP_SYS_ADMIN)")"

  if ! command -v bpftool >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq bpftool >/dev/null 2>&1 || true
  fi
  if command -v bpftool >/dev/null 2>&1; then
    echo "struct_ops in BTF:"
    bpftool btf dump file /sys/kernel/btf/vmlinux format c 2>/dev/null \
      | grep -oE "bpf_struct_ops_(sched_ext_ops|Qdisc_ops|tcp_congestion_ops)" \
      | sort -u | sed "s/^/  /" || echo "  (none found)"
  fi
'
echo ">>> netem needs CAP_NET_ADMIN; check it manually with:"
echo "    container run --rm --cap-add NET_ADMIN $IMAGE sh -c 'tc qdisc add dev lo root netem loss 5% && tc qdisc del dev lo root && echo netem-ok'"
echo ">>> If bpffs shows 'not mounted', run scripts/setup-bpf-env.sh inside the container first."
