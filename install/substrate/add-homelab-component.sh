#!/bin/sh
# Adds the homelab kustomize Component to a substrate checkout's
# manifests/ate-install/base, which is what ate-setup renders outside kind
# mode. Run it after every clone or `git pull` of the checkout; it is a no-op
# when the component is already listed. Undo with `git checkout -- <base>`.
#
#   install/substrate/add-homelab-component.sh ~/src/substrate
set -eu

[ "$#" -eq 1 ] || { echo "usage: $0 <substrate-checkout>" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
component="$here/components/homelab"
base="$(cd "$1" && pwd)/manifests/ate-install/base"
kustomization="$base/kustomization.yaml"

[ -f "$kustomization" ] || { echo "not a substrate checkout: $kustomization missing" >&2; exit 1; }

# kustomize resolves component paths relative to the kustomization.
rel="$(python3 -I -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$component" "$base")"

if grep -qF -- "- $rel" "$kustomization"; then
  echo "already present: $rel"
  exit 0
fi

if grep -q '^components:' "$kustomization"; then
  # Upstream added its own components list; append ours under it.
  awk -v item="  - $rel" '{ print } /^components:/ { print item }' "$kustomization" > "$kustomization.tmp"
  mv "$kustomization.tmp" "$kustomization"
else
  printf '\ncomponents:\n  - %s\n' "$rel" >> "$kustomization"
fi

echo "added $rel to $kustomization"
