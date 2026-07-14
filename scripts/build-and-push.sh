#!/usr/bin/env bash
# Build every modpack under packs/ into deterministic tar.gz layers and,
# optionally, push each one to a registry as a Minecraft modpack OCI
# artifact that itzg/docker-minecraft-server can consume via
#   GENERIC_PACKS=oci://<registry>/<pack>:<tag>
#
# You normally do NOT run this by hand. The workflow in
# .github/workflows/publish.yml runs it for you on every push. It is kept
# short and readable so you *can* run it locally if you want to (see the
# "Running locally" section of the README).
#
# Folder convention (no config file needed):
#   packs/base/    -> OPTIONAL. If present, its contents become a SHARED
#                     layer applied first in every pack, so content common
#                     to all your packs is stored and downloaded only once.
#   packs/<name>/  -> every OTHER folder is one modpack, published as
#                     $REGISTRY/<name>:<tag> with layers [base?, <name>].
#
# Usage:
#   REGISTRY=ghcr.io/you/oci-modpack-template TAG=v1.0.0 ./scripts/build-and-push.sh
#   PUSH=false ./scripts/build-and-push.sh    # build layers only, no upload
set -euo pipefail

REGISTRY="${REGISTRY:-}"
TAG="${TAG:-latest}"
PUSH="${PUSH:-true}"
OUT_DIR="${OUT_DIR:-out}"
PACKS_DIR="${PACKS_DIR:-packs}"

# These two strings are the contract with itzg/docker-minecraft-server's
# install-oci-pack: the server rejects any artifact that does not match.
# Do not change them unless the server side changes too.
ARTIFACT_TYPE="application/vnd.itzg.minecraft.modpack.v1+json"
LAYER_TYPE="application/vnd.itzg.minecraft.modpack.layer.v1.tar+gzip"

cd "$(dirname "$0")/.."

if [[ "${PUSH}" == "true" && -z "${REGISTRY}" ]]; then
  echo "ERROR: set REGISTRY when PUSH=true, e.g. REGISTRY=ghcr.io/you/oci-modpack-template" >&2
  exit 2
fi
if [[ ! -d "${PACKS_DIR}" ]]; then
  echo "ERROR: no '${PACKS_DIR}/' folder found next to this script." >&2
  exit 2
fi

mkdir -p "${OUT_DIR}"

# Deterministic tar.gz: stable file order, fixed mtime/owner/group, and no
# gzip header timestamp. Identical input -> identical sha256, which is what
# lets the registry store a shared base layer exactly once across packs.
make_layer() {
  local src="$1" dst="$2"
  tar \
    --sort=name \
    --mtime='UTC 2020-01-01' \
    --owner=0 --group=0 --numeric-owner \
    --format=ustar \
    -cf - -C "${src}" . \
  | gzip -n > "${dst}"
}

# Optional shared base layer.
BASE_LAYER=""
if [[ -d "${PACKS_DIR}/base" ]]; then
  echo ">> building shared base layer from ${PACKS_DIR}/base"
  make_layer "${PACKS_DIR}/base" "${OUT_DIR}/base.tar.gz"
  BASE_LAYER="${OUT_DIR}/base.tar.gz"
  echo "   base.tar.gz  sha256:$(sha256sum "${BASE_LAYER}" | awk '{print $1}')"
fi

# Discover packs: every folder in packs/ except base.
PACKS=()
for dir in "${PACKS_DIR}"/*/; do
  [[ -d "${dir}" ]] || continue
  name="$(basename "${dir}")"
  [[ "${name}" == "base" ]] && continue
  PACKS+=("${name}")
done
if [[ ${#PACKS[@]} -eq 0 ]]; then
  echo "ERROR: found no modpack folders in ${PACKS_DIR}/ (base/ on its own is not a pack)." >&2
  exit 2
fi

for pack in "${PACKS[@]}"; do
  echo ">> building overlay layer for ${pack}"
  make_layer "${PACKS_DIR}/${pack}" "${OUT_DIR}/${pack}.tar.gz"
  echo "   ${pack}.tar.gz  sha256:$(sha256sum "${OUT_DIR}/${pack}.tar.gz" | awk '{print $1}')"
done

if [[ "${PUSH}" != "true" ]]; then
  echo ">> PUSH=false - built layers in ${OUT_DIR}/, skipping upload."
  exit 0
fi

SOURCE_URL="https://github.com/${GITHUB_REPOSITORY:-you/oci-modpack-template}"
for pack in "${PACKS[@]}"; do
  ref="${REGISTRY}/${pack}:${TAG}"
  echo ">> pushing ${ref}"
  # Layer order matters: base first so consumers apply it first and the
  # pack overlay wins on any conflict. oras keeps this order in the manifest.
  layers=()
  [[ -n "${BASE_LAYER}" ]] && layers+=("${BASE_LAYER}:${LAYER_TYPE}")
  layers+=("${OUT_DIR}/${pack}.tar.gz:${LAYER_TYPE}")
  oras push "${ref}" \
    --artifact-type "${ARTIFACT_TYPE}" \
    --annotation "org.opencontainers.image.title=${pack}" \
    --annotation "org.opencontainers.image.source=${SOURCE_URL}" \
    --annotation "org.opencontainers.image.description=Minecraft modpack '${pack}' shipped as an OCI artifact" \
    "${layers[@]}"
done

echo
echo ">> done. Published:"
for pack in "${PACKS[@]}"; do
  echo "   ${REGISTRY}/${pack}:${TAG}"
done
