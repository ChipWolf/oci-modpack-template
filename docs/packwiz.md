# Defining packs with packwiz (advanced)

The main template commits mod `.jar` files straight into `packs/<name>/`.
That is the simplest path and needs no tooling.

If you would rather track mods **declaratively** (by Modrinth or CurseForge
project and version, with hashes, in small text files) instead of committing
binaries, define each pack with [packwiz](https://packwiz.infra.link/) and
let CI resolve the actual jars and bake them into the OCI artifact. Your
source repo stays text-only and reviewable; the published artifact still
carries the real jars a server needs, so nothing changes for the server
operator: it is the same `oci://` pull.

---

## Redistribution: read this first

> [!WARNING]
> Baking jars into an OCI artifact **re-hosts other people's mods on your
> registry**. Only publish a baked pack from a **private** repo and registry,
> for **your own servers**, unless every mod's license grants you permission
> to redistribute it.
>
> - **CurseForge** marks files whose authors opted out of third-party
>   distribution. The API withholds a download URL for those, so the CI bake
>   **fails** on them rather than re-hosting them. Treat that failure as a
>   licensing signal, not a bug to work around. Re-hosting CurseForge jars
>   also runs against their terms in most readings.
> - **Modrinth** mods carry per-project licenses. Many are all-rights-reserved
>   or copyleft with conditions. Check each mod's license before you publish a
>   baked pack anywhere public.
>
> Pure packwiz (see the comparison below) sidesteps this: it ships only
> metadata, and each server downloads jars from the original host. Prefer that
> for anything public unless you hold redistribution rights.

---

## When baking is worth it (the break-even)

Pure packwiz already works with `itzg/docker-minecraft-server`: point a server
at `PACKWIZ_URL=https://.../pack.toml` and it resolves and downloads every mod
from Modrinth or CurseForge at each start. For a single server you rarely
restart, that is the simpler choice, and it is always current.

Baking the jars into an OCI artifact adds a CI step, and it pays off as you
scale in either direction:

- **Many servers or frequent restarts.** Pure packwiz re-resolves from
  Modrinth, the CurseForge API, and the packwiz installer host on every cold
  start, so a rate limit or an upstream outage delays or blocks startup. A
  baked pack is pulled once from GHCR, often in the same network, with no
  upstream dependency at boot. Event fleets, playtest spin-ups, and autoscaled
  servers cross the break-even quickly.
- **Many packs sharing components.** A shared base layer is stored once in the
  registry and downloaded once per server, no matter how many packs reference
  it (see the [README](../README.md)).
- **Reproducibility and offline.** The exact jar bytes live in the layer,
  addressed by digest, so a deleted or replaced upstream version cannot break
  you, and an airgapped server can run from a single pull.

Below the break-even, one rarely-restarted server, pure packwiz wins on
simplicity. Above it, the one-time bake buys faster, more reliable starts.

---

## 1. Define the pack

Install packwiz (`go install github.com/packwiz/packwiz@latest`, Nix, or a
[CI build artifact](https://nightly.link/packwiz/packwiz/workflows/go/main);
packwiz publishes no release binaries). Then, in a metadata folder for the
pack, generate the files:

```sh
packwiz init                       # writes pack.toml + index.toml
packwiz modrinth add sodium        # adds mods/sodium.pw.toml
packwiz modrinth add lithium
```

`pack.toml` is the manifest:

```toml
name = "tech"
author = "you"
version = "1.0.0"
pack-format = "packwiz:1.1.0"

[index]
file = "index.toml"
hash-format = "sha256"
hash = "..."

[versions]
minecraft = "1.21.1"
fabric = "0.16.9"
```

Each mod is one `mods/<slug>.pw.toml`. A Modrinth mod records the CDN URL and
hash directly, so nothing else is needed to fetch it:

```toml
name = "Sodium"
filename = "sodium-fabric-0.6.0+mc1.21.1.jar"
side = "client"

[download]
url = "https://cdn.modrinth.com/data/AANobbMI/versions/.../sodium-fabric-0.6.0%2Bmc1.21.1.jar"
hash-format = "sha512"
hash = "..."

[update.modrinth]
mod-id = "AANobbMI"
version = "..."
```

A CurseForge mod instead uses `mode = "metadata:curseforge"` and carries no
URL; the jar is resolved through the CurseForge API at bake time (subject to
the redistribution warning above).

Commit only these text files. Do not commit jars.

---

## 2. Bake the jars in CI

There is no packwiz command that downloads all mods to a folder. The jars are
pulled by [`packwiz-installer`](https://github.com/packwiz/packwiz-installer),
a Java tool (JRE 8+). Serve the pack locally, run the installer against it for
the `server` side, then strip the metadata so only the downloaded jars remain
in `packs/<name>/`, where this template's `build-and-push.sh` picks them up.

```yaml
# In your publish workflow, before "Build and publish packs".
- name: Set up Java
  uses: actions/setup-java@v4
  with:
    distribution: temurin
    java-version: "21"

- name: Bake packwiz packs into packs/
  run: |
    set -euo pipefail
    tmp="${RUNNER_TEMP}/packwiz-installer"; mkdir -p "$tmp"
    curl -fsSL -o "$tmp/bootstrap.jar" \
      https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar  # renovate: repository=packwiz/packwiz-installer-bootstrap
    curl -fsSL -o "$tmp/installer.jar" \
      https://github.com/packwiz/packwiz-installer/releases/download/v0.5.14/packwiz-installer.jar  # renovate: repository=packwiz/packwiz-installer

    # For each packwiz source dir (holding pack.toml), materialise into
    # packs/<name>/ so build-and-push.sh tars the real jars into a layer.
    for src in packwiz/*/; do
      name="$(basename "$src")"
      dest="packs/${name}"; mkdir -p "$dest"

      ( cd "$src" && packwiz serve --port 8080 >/tmp/serve.log 2>&1 & echo $! >/tmp/serve.pid )
      for _ in $(seq 1 30); do
        curl -fsS http://127.0.0.1:8080/pack.toml >/dev/null && break || sleep 1
      done

      java -jar "$tmp/bootstrap.jar" \
        -g \
        -s server \
        http://127.0.0.1:8080/pack.toml \
        --pack-folder "$dest" \
        --bootstrap-main-jar "$tmp/installer.jar" \
        --bootstrap-no-update

      kill "$(cat /tmp/serve.pid)" 2>/dev/null || true
      # Drop packwiz metadata; the downloaded jars stand in for it.
      find "$dest" -name '*.pw.toml' -delete
      rm -f "$dest/index.toml" "$dest/pack.toml" "$dest/packwiz.json"
    done
```

Pin the two installer versions (the `# renovate:` comments let Renovate bump
them). `--bootstrap-no-update` with `--bootstrap-main-jar` skips the bootstrap
self-update so the run does not depend on the installer's release API being
reachable.

From here the existing pipeline is unchanged: `build-and-push.sh` turns each
`packs/<name>/` into a deterministic layer and pushes the OCI artifact.

---

## packwiz baked into OCI vs pure packwiz

| | Baked into OCI (this recipe) | Pure packwiz (`PACKWIZ_URL`) |
| --- | --- | --- |
| **What the server pulls** | Finished jars, from your registry | Metadata, then jars from each origin at start |
| **Redistribution** | You re-host the jars (needs permission; private-only for restricted mods) | Only metadata is shared; jars come from the original host |
| **Start-time deps** | GHCR only | Modrinth, CurseForge API, packwiz installer host |
| **Reproducible / offline** | Yes: exact bytes pinned by digest | No: depends on upstream availability each start |
| **Layer reuse across packs** | Yes, shared layers stored once | No image layers |
| **Update flow** | Edit metadata, CI re-bakes a new tag | Edit metadata at the source URL, servers pick it up on restart |
| **Where failures surface** | In CI, before anyone plays | At server start, per server |

Use pure packwiz for a public, single-server, always-current setup. Use the
baked OCI path for a private fleet where reproducible, fast, self-contained
starts matter more than automatic currency.
