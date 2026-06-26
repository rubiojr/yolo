# Architecture

Internals of `yolo`: the auto-heal algorithm, state file layout,
provisioner markers, the backend abstraction, and source tree.

For user-facing behaviour, see the [tutorial chapters](./README.md). For
the backend capability matrix and selection rules, see
[backends](./09-backends.md).

## 1. Auto-heal

`yolo`'s state file points at an opaque per-name id (a `vm-xxxx` for
matchlock, a `yolo-<binding>` container name for podman and container). Before every
action that needs a running VM, `yolo`:

1. Reads the stored id from `$XDG_RUNTIME_DIR/yolo/<name>.vmid`.
2. Resolves the backend from `<name>.backend` (sticky once set; falls
   back to `matchlock` for pre-existing state).
3. Calls the backend's `list_table()` and looks up the row.
4. If status is `running` → reuse the VM.
5. If status is non-running **and** the backend's `PERSISTS_ON_STOP` flag
   is true (podman, container) → call the backend's `resume()` and reattach.
6. If status is non-running **and** the backend doesn't persist on stop
   (matchlock) → `remove()` and start a fresh VM with the same name.
7. If the row is missing → drop the stored id and start a fresh VM.

This makes `yolo` idempotent: invoking it after a host reboot, a manual
`matchlock prune` / `podman rm`, or a backend-level removal does the
right thing without arguments.

The same auto-heal pass runs for every subcommand that touches a live
VM (`yolo`, `yolo --`, `yolo provision`, `yolo export`), so a
"recovered" state can be observed from any entry point.

## 2. State files

`yolo` keeps a tiny per-name state in `$XDG_RUNTIME_DIR/yolo/`
(typically `/run/user/$UID/yolo/`, falling back to `/tmp/yolo/`):

```
<name>.vmid       # opaque backend id currently bound to this name
<name>.backend    # backend that owns this binding (matchlock | podman | container)
<name>.applied    # vm-id + provisioner marker(s) already applied
<name>.cwd        # host cwd recorded at first attach (for display)
<name>.image      # per-name image pin (set by `yolo import`)
```

`<name>.backend` was added when the second backend landed. If it's
missing, yolo treats the binding as matchlock-owned (the original
behaviour), so existing state keeps working seamlessly.

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

Backends have no `--name` of their own. `yolo` maintains the name → id
map entirely in `<name>.vmid`. Names are either:

- **Auto-derived per-CWD**: `cwd-<sha1(absolute_cwd)[:10]>`. Stable for
  a given directory, unique enough across the user's projects.
- **Explicit**: `-n NAME` or `$YOLO_NAME`.

Auto-derived names use a sha1 prefix rather than the raw path so that
the same `ls`-formatted output fits a sensible column width and doesn't
leak the full project layout into shared screenshots.

The podman backend prefixes container names with `yolo-` so its
`podman ps -a` filter only sees yolo-managed containers and doesn't
collide with the user's other podman work.

## 4. Provisioner execution

`yolo` pipes the embedded bash script (or `Yolofile` body) into the
backend's `exec_provision` channel:

- matchlock: `matchlock exec <vm> -i -u root -- bash`
- podman:    `podman exec -i --user 0 <container> bash`
- container: `container exec -i --user 0 <container> bash`

The script's stdin is the script bytes; stdout/stderr stream back to
the user's terminal.

There is no language runtime in the guest beyond `bash` itself. The
host-side `yolo` binary is a single static rugo-compiled artifact;
neither rugo nor Go is needed on the guest side.

Each script runs:

- as `root` inside the guest;
- with the host's `$PWD` live-mounted at `/work` (read-write);
- with the guest's default network configuration (NAT by default, or
  matchlock's MITM allow-list if `YOLO_ALLOW` is set; podman ignores
  `YOLO_ALLOW` and uses its own default networking);
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

## 6. Backends

Every backend lives at `backends/<name>.rugo` and exposes a single
public factory function `make()` returning a *handle* — a hash with
constants (`NAME`, `SUPPORTS_GUI`, `SUPPORTS_EXPORT`, `PERSISTS_ON_STOP`,
`DEFAULT_IMAGE`) and closure-valued methods (`start`, `stop`, `resume`,
`remove`, `wait_ready`, `list_table`, `logs`, `exec_provision`,
`exec_shell`, `exec_argv`, `disk_apparent`, `disk_real`, `image_remove`,
and — only when `SUPPORTS_EXPORT` — `export_archive`, `import_unpack`,
`import_retag`).

`yolo.rugo` builds a registry at startup:

```ruby
require "backends" with matchlock, podman, container

BACKENDS = {
  "matchlock" => matchlock.make(),
  "podman"    => podman.make(),
  "container" => container.make()
}
```

All matchlock/podman-specific code lives inside the backend modules.
`yolo.rugo` only ever talks to backends through the handle.

The full contract is documented in
[`backends/INTERFACE.md`](../backends/INTERFACE.md). User-facing
backend behaviour is documented in
[`docs/09-backends.md`](./09-backends.md).

## 7. Locking

`yolo` takes a flock on the per-name state file before any mutation
that could race with another concurrent `yolo` for the same name (VM
creation, marker write, removal). This prevents two `yolo` instances
in the same directory from both deciding to create a fresh VM.
Maintenance subcommands (`ls`, `du`, `status`, `id`, `logs`, `prune`)
read state without locking.

## 8. Source layout

```
yolo.rugo                                       # the CLI (a single rugo script)
Yolofile                                        # bootstraps a yolo dev VM with Go + rugo
backends/
  INTERFACE.md                                  # backend contract
  matchlock.rugo                                # matchlock (Firecracker) backend
  matchlock/
    yolo-export.sh                              # matchlock-specific helpers,
    yolo-import-unpack.sh                       # embedded at build time
    yolo-import-retag.sh
  podman.rugo                                   # podman (container) backend
  container.rugo                                # Apple `container` backend (macOS)
provisioners/
  provisioner-fedora-go.sh                      # backend-agnostic, run in guest
  provisioner-fedora-rust.sh
  provisioner-fedora-ruby.sh
  provisioner-fedora-android.sh
  ai-agents/
    copilot.sh
    opencode.sh
docs/
  README.md                                     # chapter index
  01-getting-started.md
  …
  08-troubleshooting.md
  09-backends.md                                # backend chapter
  architecture.md                               # this file
rugo-quirks.md                                  # notes for the rugo author
README.md                                       # the slim user-facing readme
```

Each `provisioners/*.sh` and `backends/matchlock/*.sh` file is read at
build time via rugo's `embed` directive and baked into the binary.
Adding a new provisioner or backend helper script therefore requires a
rebuild (`rugo build yolo.rugo`).

## 9. The `Yolofile` at the repo root

The `Yolofile` checked into this repository is `yolo`'s own
self-hosting provisioner — it installs Go and `rugo` so you can build
`yolo` itself inside a `yolo` VM. It is **not** the canonical Yolofile
reference; that lives in [chapter 5](./05-yolofile.md).

## 10. Caveats baked into the design

The following behaviours are intentional design trade-offs, documented
here so they show up under "architecture" rather than as surprises:

- **The matchlock rootfs is ephemeral by design.** `dnf install` etc.
  only survives as long as the VM does. Persistent dev tooling should
  live either under `/work` (which is the host filesystem) or in a
  custom OCI image. This is why provisioners exist. The podman backend
  preserves the writable layer across `stop`/`start`, but a `yolo rm`
  still throws it away.
- **`yolo stop` semantics depend on the backend.** Matchlock has no
  resume-from-stopped, so `yolo stop && yolo` rebuilds and reprovisions.
  Podman preserves state across stop. See
  [Troubleshooting § VM lifecycle](./08-troubleshooting.md#82-vm-lifecycle)
  and [Backends](./09-backends.md).
- **The OCI image is pulled on first boot.** Subsequent starts are
  sub-second once the image is cached.
- **rugo is pre-1.0.** The language is fun and productive but still
  alpha. See [`rugo-quirks.md`](../rugo-quirks.md) for issues
  encountered while writing `yolo`.
