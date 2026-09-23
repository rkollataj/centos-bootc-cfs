#!/usr/bin/env bash
# Generates local, throwaway UEFI Secure Boot keys (PK, KEK, db).
#
# Output: secureboot-keys/{PK,KEK,db}.{key,crt} + GUID.txt -- gitignored,
# never committed, and never regenerated if already present.
#
# - db.key/db.crt sign the UKI (build.sh passes them to `podman build
#   --secret`; seal-uki's --seal-state sealed uses them).
# - PK.crt/KEK.crt/db.crt + GUID.txt are enrolled into the VM's OVMF_VARS by
#   `bcvk libvirt run --secure-boot-keys secureboot-keys` (see README).
#
# These are local test keys, not a real PKI hierarchy: PK/KEK/db are each an
# independent self-signed cert. Fine for QEMU/OVMF trust enrollment, not for
# any real Secure Boot deployment.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secureboot-keys"

if [ -f "$DIR/db.key" ]; then
    echo "== secureboot-keys/ already exists, not regenerating."
    exit 0
fi

mkdir -p "$DIR"
echo "== generating local Secure Boot keys in $DIR (test keys only)"

GUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
echo "$GUID" > "$DIR/GUID.txt"

for pair in "PK:Platform Key" "KEK:Key Exchange Key" "db:Signature Database"; do
    name="${pair%%:*}"
    cn="${pair#*:}"
    openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -subj "/CN=centos-bootc-cfs local $cn/" \
        -keyout "$DIR/$name.key" -out "$DIR/$name.crt" 2>/dev/null
done

chmod 600 "$DIR"/*.key
echo "== done: $(ls "$DIR" | tr '\n' ' ')"
