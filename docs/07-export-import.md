# 7. Export & import

`yolo export` snapshots a VM's current rootfs **and** `yolo`'s own state
into a single tarball. `yolo import` restores it on another host so the
next `yolo -n NAME` boots from the captured rootfs with provisioners
already applied.

This is the workflow when you want to share a fully-provisioned dev
environment with a teammate, or move a VM between machines without
re-running expensive provisioners.

## 7.1 Exporting a VM

```bash
# Export the per-CWD VM to ./yolo-export-<name>-<timestamp>.tar.gz
yolo export

# Export a named VM to a specific file
yolo export -n notes -o /tmp/notes.tar.gz
```

The bundle contains:

- the VM's current rootfs (as a matchlock-compatible image layer),
- the relevant pieces of `yolo`'s state directory (the applied
  provisioner marker, so re-provisioning isn't triggered after import),
- a small manifest used by `yolo import` to reconstruct everything.

The source VM is **not** disturbed by `yolo export`. It keeps running.

> ⚠️ The bundle is **not encrypted**. Anything written to the rootfs —
> SSH keys, credentials, history — ends up in the tarball. Treat it
> like a disk image.

## 7.2 Importing on another host

Transfer the bundle (`scp`, USB stick, whatever), then on the
destination:

```bash
yolo import /tmp/notes.tar.gz                  # import under its original name
yolo import /tmp/notes.tar.gz -n notes-copy    # rename on import
yolo import /tmp/notes.tar.gz --force          # overwrite an existing binding
```

What `yolo import` does:

1. Unpacks the bundle.
2. Pins a **per-VM custom matchlock image** built from the captured
   rootfs.
3. Restores the `yolo` state files so the imported VM is tracked under
   the chosen name.

The VM itself is **not** started by `import`. The next time you run
`yolo -n NAME`, matchlock boots the pinned image and you land in a VM
with everything the source had.

```bash
yolo -n notes-copy        # boots from the imported rootfs, no re-provisioning
```

## 7.3 What is and isn't included

Included:

- Anything written to the VM's rootfs (installed packages, configuration
  files outside `/work`, caches under `/root`, etc.).
- The applied provisioner marker, so `yolo` knows not to re-run the
  provisioner on first attach.

**Not** included:

- The host bind-mount at `/work` — your project directory lives on the
  host filesystem; the bundle does not duplicate it. You'll typically
  want to copy or re-clone your repository on the destination host
  before running `yolo` there.
- Any matchlock-level state (network policies, host routes).
- Running processes, in-memory state, kernel state. A bundle is a
  filesystem snapshot, not a VM checkpoint.

## 7.4 Image pinning and precedence

After `yolo import`, the imported name is bound to a custom matchlock
image. This pin **overrides** `YOLO_IMAGE`, `Yolofile` front-matter
`image:`, and the built-in default for that specific name. If you later
want to switch back to `fedora:44` for that name, `yolo -n NAME rm` it
and start a fresh VM.

See [Configuration § Precedence](./03-configuration.md#35-precedence)
for the full resolution order.

## 7.5 Common failure cases

| Symptom                                       | Cause / fix                                              |
| --------------------------------------------- | -------------------------------------------------------- |
| `import: name NAME already exists`            | Use `--force` to overwrite, or pick a different `-n`.    |
| `import: bundle missing manifest`             | Truncated transfer. Re-copy the tarball.                 |
| First `yolo -n NAME` re-runs the provisioner  | The provisioner script changed between hosts; the marker hash no longer matches. Use `--no-provision` if you want to skip. |
| `matchlock: image not found` after import     | The pinned image lives under `~/.local/share/matchlock/` (or matchlock's configured root). Re-run `yolo import` against the bundle. |

For more troubleshooting see [chapter 8](./08-troubleshooting.md).
