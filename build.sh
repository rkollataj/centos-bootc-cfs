#!/usr/bin/env bash
# Build this image, signed and correctly sealed.
#
# Plain `podman build` alone produces an image that `bootc install` will
# reject with "The UKI has the wrong composefs= parameter", due to an open
# upstream bug (see fix-uki-digest.sh and README). This wraps the necessary
# steps: generate local Secure Boot keys if missing, build with them as
# secrets, then correct the UKI's embedded composefs digest.
#
# Usage: ./build.sh [image[:tag]]
set -euo pipefail

IMG="${1:-localhost/centos-bootc-composefs:stream10}"
cd "$(dirname "${BASH_SOURCE[0]}")"

./gen-secureboot-keys.sh

podman build -f Containerfile -t "$IMG" \
    --secret id=secureboot_key,src=secureboot-keys/db.key \
    --secret id=secureboot_cert,src=secureboot-keys/db.crt \
    .
./fix-uki-digest.sh "$IMG"
