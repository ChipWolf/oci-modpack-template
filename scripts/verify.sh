#!/usr/bin/env bash
# Prove your published modpacks work, without a Minecraft server:
#   1. show each pack's layers so you can SEE the shared base layer's digest
#      is identical across packs (stored and downloaded once), and
#   2. pull and extract each pack into a local folder and list the files,
#      exactly as a server would drop them into /data.
#
# The "test" GitHub Actions workflow runs this for you on a button click.
#
# Usage:
#   REGISTRY=ghcr.io/you/oci-modpack-template TAG=latest ./scripts/verify.sh [pack ...]
# With no pack arguments it discovers them from your local packs/ folder.
set -euo pipefail

REGISTRY="${REGISTRY:-}"
TAG="${TAG:-latest}"
OUT_DIR="${OUT_DIR:-out/verify}"

if [[ -z "${REGISTRY}" ]]; then
  echo "ERROR: set REGISTRY, e.g. REGISTRY=ghcr.io/you/oci-modpack-template" >&2
  exit 2
fi

PACKS=("$@")
if [[ ${#PACKS[@]} -eq 0 ]]; then
  for dir in packs/*/; do
    [[ -d "${dir}" ]] || continue
    name="$(basename "${dir}")"
    [[ "${name}" == "base" ]] && continue
    PACKS+=("${name}")
  done
fi
if [[ ${#PACKS[@]} -eq 0 ]]; then
  echo "ERROR: no packs given and none discovered under packs/." >&2
  exit 2
fi

rm -rf "${OUT_DIR}"; mkdir -p "${OUT_DIR}"

echo "== layers per pack (the shared base layer digest should be identical) =="
for pack in "${PACKS[@]}"; do
  echo "--- ${pack} ---"
  oras manifest fetch "${REGISTRY}/${pack}:${TAG}" \
    | jq -r '.layers[] | "  \(.digest)  \(.size) bytes  \(.annotations["org.opencontainers.image.title"] // "")"'
done

echo
echo "== extract each pack (as a server would apply it into /data) =="
for pack in "${PACKS[@]}"; do
  ref="${REGISTRY}/${pack}:${TAG}"
  dest="${OUT_DIR}/${pack}"
  blobs="${OUT_DIR}/.blobs-${pack}"
  mkdir -p "${dest}" "${blobs}"
  echo "--- ${pack} ---"
  oras pull "${ref}" --output "${blobs}"
  # Apply layers in manifest order (base first). oras may name pulled blobs
  # by their title annotation, so match each manifest layer to a file on
  # disk by sha256 rather than by filename.
  oras manifest fetch "${ref}" | jq -r '.layers[].digest' | while read -r digest; do
    while IFS= read -r f; do
      if [[ "sha256:$(sha256sum "$f" | awk '{print $1}')" == "${digest}" ]]; then
        tar -xzf "$f" -C "${dest}"
        break
      fi
    done < <(find "${blobs}" -type f)
  done
  find "${dest}" -type f | sed "s#^${dest}/#    #" | sort
done

echo
echo ">> verify complete. Extracted file trees are under ${OUT_DIR}/."
