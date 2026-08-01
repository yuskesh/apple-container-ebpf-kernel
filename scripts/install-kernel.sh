#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Install a freshly built kernel into Apple `container`. Run on the macOS host.
#
#   scripts/install-kernel.sh /path/to/Image-7.1.5-ebpf
#
# Tunables:
#   ARCH   target architecture (default arm64)
set -euo pipefail

IMG="${1:?usage: install-kernel.sh <Image-file>}"
ARCH="${ARCH:-arm64}"
[ -f "$IMG" ] || { echo "!!! no such file: $IMG"; exit 1; }

command -v container >/dev/null 2>&1 || {
  echo "!!! 'container' CLI not found. Install Apple container (brew install container)."
  exit 1
}

echo ">>> setting Apple container kernel: $IMG (arch $ARCH)"
container system kernel set --binary "$IMG" --arch "$ARCH" --force

cat <<'EOF'
>>> done.

Notes:
  * Only NEW `container run` instances pick up the new kernel. Existing
    containers snapshot their kernel when the runtime starts.
  * Start the runtime so it keeps the custom kernel (it will not re-download an
    official one):
        container system start --disable-kernel-install
  * Verify with: scripts/verify-kernel.sh
EOF
