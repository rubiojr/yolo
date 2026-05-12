# Architecture

Internals of `yolo`: the auto-heal algorithm, state file layout,
provisioner markers, and source tree.

For user-facing behaviour, see the [tutorial chapters](./README.md).

## 1. Auto-heal

`yolo`'s state file points at a `vm-xxxxxxxx`. Before every action that
needs a running VM, `yolo`:

1. Reads the stored vm-id from `$XDG_RUNTIME_DIR/yolo/<name>.vmid`.
2. Calls `matchlock list` and looks up the row.
3. If status is `running` → reuse the VM.
4. If status is `stopped`, `failed`, or the row is missing →
   `matchlock kill && matchlock rm` (best-effort), drop the stored
   vm-id, start a fresh VM, and persist the new id.

This makes `yolo` idempotent: invoking it after a host reboot, a manual
`matchlock prune`, or a `matchlock rm` does the right thing without
arguments.

The same auto-heal pass runs for every subcommand that touches a live
VM (`yolo`, `yolo --`, `yolo provision`, `yolo export`), so a
"recovered" state can be observed from any entry point.

## 2. State files

`yolo` keeps a tiny per-name state in `$XDG_RUNTIME_DIR/yolo/`
(typically `/run/user/$UID/yolo/`, falling back to `/tmp/yolo/`):

```
<name>.vmid       # the matchlock vm-id currently bound to this name
<name>.applied    # vm-id + provisioner marker(s) already applied
```

The `.applied` marker contains the vm-id on the first line and the
applied provisioner markers on subsequent lines:

```
vm-b1e68449
fedora-go:2ade95cded20
ai-agent:copilot:7f3a8b12e6c4
```

Markers can take one of three shapes — all three include a 12-hex
prefix of `sha256(provisioner_source)` so that editing the script (a
Yolofile body, an embedded provisioner, or an AI-agent installer) and
rebuilding/re-running invalidates the marker automatically:

| Shape                                  | Meaning                                          |
| -------------------------------------- | ------------------------------------------------ |
| `<provisioner-name>:<hash12>`          | A built-in embedded provisioner, e.g. `fedora-go:<hash>`. The hash is recomputed at compile time, so rebuilding `yolo` with an edited provisioner script triggers a re-provision on next attach. |
| `yolofile:<hash12>`                    | A project-local Yolofile body. The hash is computed each attach from the on-disk body, so editing the file triggers a re-run. |
| `ai-agent:<name>:<hash12>`             | An AI-agent layer applied via `--ai-agent NAME`. Tracked independently of the language provisioner. |

### Marker invalidation

There are two independent invalidation paths:

1. **vm-id change.** The marker is tied to the vm-id on the first line
   of `.applied`. When auto-heal recreates the VM under a new vm-id,
   the file is rewritten with the new id and an empty marker list, so
   provisioners re-run on the next attach.
2. **Content hash change.** Even if the vm-id is unchanged, editing
   the provisioner source changes the hash suffix, the stored marker
   no longer matches, and the provisioner re-runs.

For Yolofiles this means **editing the body is all you need** — no
`--force`, no `yolo provision`. For embedded provisioners it means a
rebuild of `yolo` from edited sources will re-provision every existing
VM on next attach.

Editing front matter does **not** change the body hash (front matter
only affects VM creation; see
[Yolofile reference § Re-provisioning](./05-yolofile.md#re-provisioning)).

## 3. Naming

Matchlock has no `--name` of its own. `yolo` maintains the name → vm-id
map entirely in `<name>.vmid`. Names are either:

- **Auto-derived per-CWD**: `cwd-<sha1(absolute_cwd)[:10]>`. Stable for
  a given directory, unique enough across the user's projects.
- **Explicit**: `-n NAME` or `$YOLO_NAME`.

Auto-derived names use a sha1 prefix rather than the raw path so that
the same `ls`-formatted output fits a sensible column width and doesn't
leak the full project layout into shared screenshots.

## 4. Provisioner execution

`yolo` pipes the embedded bash script (or `Yolofile` body) into
`matchlock exec <vm> -i -u root -- bash`. The script's stdin is the
script bytes; stdout/stderr stream back to the user's terminal.

There is no language runtime in the guest beyond `bash` itself. The
host-side `yolo` binary is a single static rugo-compiled artifact;
neither rugo nor Go is needed on the guest side.

Each script runs:

- as `root` inside the guest;
- with the host's `$PWD` live-mounted at `/work` (read-write);
- with the guest's default network configuration (NAT by default, or
  matchlock's MITM allow-list if `YOLO_ALLOW` is set);
- with **no implicit `set -e`** — provisioner scripts opt in to
  `set -euo pipefail` themselves.

## 5. Provisioner resolution

When the user runs `yolo`, the resolution order is:

1. **`--provisioner NAME`** (explicit). Looked up in the embedded
   `PROVISIONERS` map; unknown names are an error.
2. **`./Yolofile`** in `$PWD`. If present, becomes the active
   provisioner with marker `yolofile:<hash12>`.
3. **Auto-detection** from files in `$PWD`:
   - `go.mod` / `go.sum` / `*.go` → `fedora-go`
   - `Cargo.toml` / `rust-toolchain.toml` / `rust-toolchain` → `fedora-rust`
   - `Gemfile` / `.ruby-version` / `*.gemspec` → `fedora-ruby`
   - `build.gradle[.kts]` / `settings.gradle[.kts]` / `app/build.gradle[.kts]` → `fedora-android`
4. Otherwise no provisioner runs.

`--no-provision` skips this whole pass.

`--ai-agent NAME` layers an additional pass on top, looked up in the
`AI_AGENTS` map, tracked as a separate marker.

## 6. Locking

`yolo` takes a flock on the per-name state file before any mutation
that could race with another concurrent `yolo` for the same name (VM
creation, marker write, removal). This prevents two `yolo` instances
in the same directory from both deciding to create a fresh VM.
Maintenance subcommands (`ls`, `du`, `status`, `id`, `logs`, `prune`)
read state without locking.

## 7. Source layout

```
yolo.rugo                                       # the CLI (a single rugo script)
Yolofile                                        # bootstraps a yolo dev VM with Go + rugo
provisioners/
  provisioner-fedora-go.sh
  provisioner-fedora-rust.sh
  provisioner-fedora-ruby.sh
  provisioner-fedora-android.sh
  ai-agents/
    copilot.sh
    opencode.sh
  yolo-export.sh                                # host-side helper, embedded
  yolo-import-unpack.sh                         # host-side helper, embedded
  yolo-import-retag.sh                          # host-side helper, embedded
docs/
  README.md                                     # chapter index
  01-getting-started.md
  …
  08-troubleshooting.md
  architecture.md                               # this file
rugo-quirks.md                                  # notes for the rugo author
README.md                                       # the slim user-facing readme
```

Each `provisioners/*.sh` file is read at build time via rugo's `embed`
directive in `yolo.rugo` and baked into the binary. Adding a new
provisioner therefore requires a rebuild (`rugo build yolo.rugo`).

## 8. The `Yolofile` at the repo root

The `Yolofile` checked into this repository is `yolo`'s own
self-hosting provisioner — it installs Go and `rugo` so you can build
`yolo` itself inside a `yolo` VM. It is **not** the canonical Yolofile
reference; that lives in [chapter 5](./05-yolofile.md).

## 9. Caveats baked into the design

The following behaviours are intentional design trade-offs, documented
here so they show up under "architecture" rather than as surprises:

- **The VM rootfs is ephemeral by design.** `dnf install` etc. only
  survives as long as the VM does. Persistent dev tooling should live
  either under `/work` (which is the host filesystem) or in a custom
  OCI image. This is why provisioners exist.
- **`yolo stop` does not preserve runtime state.** Matchlock has no
  resume-from-stopped, so `yolo stop && yolo` rebuilds and reprovisions.
  This is documented in
  [Troubleshooting § VM lifecycle](./08-troubleshooting.md#82-vm-lifecycle).
- **The OCI image is pulled on first boot.** `fedora:44` is ~150 MB.
  Subsequent starts are sub-second once matchlock has cached the
  rootfs (`matchlock image ls`).
- **rugo is pre-1.0.** The language is fun and productive but still
  alpha. See [`rugo-quirks.md`](../rugo-quirks.md) for issues
  encountered while writing `yolo`.
