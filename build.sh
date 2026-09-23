#!/usr/bin/env bash
# Build this image and correct its UKI's composefs= digest.
#
# Plain `podman build` alone produces an image that `bootc install` will
# reject with "The UKI has the wrong composefs= parameter", due to an open
# upstream bug (see fix-uki-digest.sh and README). This wraps the two
# necessary steps so `bootc install` / `bcvk libvirt run` work normally.
#
# Usage: ./build.sh [image[:tag]]
set -euo pipefail

IMG="${1:-localhost/centos-bootc-composefs:stream10}"
cd "$(dirname "${BASH_SOURCE[0]}")"

podman build -f Containerfile -t "$IMG" .
./fix-uki-digest.sh "$IMG"
