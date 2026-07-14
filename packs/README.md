# packs/

Each folder here becomes a published modpack. One rule:

- **`base/`** (optional) is shared by every pack - stored and downloaded
  once. Put content common to all your packs here.
- **Every other folder** is one modpack, published under its folder name
  with the base layer applied first, then its own files.

Inside a pack, use the folder names a server expects (`mods/`, `config/`,
`plugins/`, ...); they are applied straight into the server's `/data`.

The `base`, `tech`, and `magic` folders here are examples so the template
works immediately - replace them with your own. The `EXAMPLE-*.txt` files
are placeholders; delete them and add your real `.jar`s.

See the main [README](../README.md) for the full walkthrough.
