# Backends

`yolo` ships with three backends: **matchlock** (Firecracker microVMs),
**podman** (Linux containers) and **container** (Apple's `container`, which
runs Linux containers in lightweight per-container VMs on macOS). They share
the same CLI surface and provisioner model; differences in capability are
summarised below.

For the internal contract that every backend must implement, see
[`backends/INTERFACE.md`](../backends/INTERFACE.md).

## Capability matrix

| Capability                          | matchlock        | podman                        | container (Apple)             |
| ----------------------------------- | ---------------- | ----------------------------- | ----------------------------- |
| Host platform                       | Linux (KVM) **and** macOS (Apple Silicon) | Linux | macOS (Apple silicon)         |
| Isolation                           | microVM (KVM on Linux, Virtualization.framework on macOS) | Container (host kernel) | Per-container Linux VM        |
| Boot time (post first pull)         | ~1–2 s           | <1 s                          | ~1–2 s                        |
| In-guest state across `yolo stop`   | **Not preserved** (recreate on next attach) | **Preserved** (resume on next attach) | **Preserved** (resume on next attach) |
| GUI apps (Wayland)                  | No               | Yes (`--gui`)                 | No                            |
| Audio (PipeWire/PulseAudio)         | No               | Yes (`--audio`)               | No                            |
| Publish guest ports (`--publish`)   | Yes              | Yes                           | Yes                           |
| Mount extra host dirs (`--mount`)   | Yes (guest must be under `/work`) | Yes (any guest path) | Yes (any guest path)          |
| `yolo export` / `yolo import`       | Yes              | No                            | No                            |
| Egress allow-list (`YOLO_ALLOW`)    | Yes (MITM proxy) | Ignored                       | Ignored                       |
| Honours `YOLO_CPUS` / `YOLO_MEM_MB` | Yes              | Ignored (uses host)           | Yes (per-VM allocation)       |
| Disk size cap (`YOLO_DISK_MB`)      | Yes              | Ignored (uses host fs)        | Ignored (no rootfs cap)       |
| `yolo du` disk accounting           | Yes              | Yes                           | No (reports unknown)          |
| Default image                       | `fedora:44`      | `registry.fedoraproject.org/fedora-toolbox:44` | `registry.fedoraproject.org/fedora:44` |
| Required external binary on `$PATH` | `matchlock`      | `podman`                      | `container`                   |

## Selecting a backend

There are four ways to pick a backend. They are evaluated in order; the
first match wins:

1. **`<name>.backend` (sticky).** Once a VM is created, the backend that
   created it is recorded in `$XDG_RUNTIME_DIR/yolo/<name>.backend`. All
   subsequent `yolo` invocations under that name use the recorded backend,
   regardless of overrides. This avoids accidentally talking to the wrong
   runtime for an existing VM.
2. **`--backend NAME` CLI flag.** Wins over env + Yolofile for new VMs.
   `NAME` is one of `matchlock`, `podman`, `container`.
3. **`YOLO_BACKEND=NAME` env var.** Useful as a per-shell default.
4. **`backend: NAME` in Yolofile front matter.** Project-local default.
5. **Built-in default, by host OS:** `matchlock` on Linux, `container` on
   macOS. matchlock also runs on macOS (Apple Silicon, via
   Virtualization.framework), but yolo still defaults to Apple's `container`
   there because it ships as a signed Apple package with no extra host setup,
   whereas matchlock is a Homebrew opt-in. To use matchlock on macOS, select
   it explicitly (`--backend matchlock`, `YOLO_BACKEND=matchlock`, or a
   Yolofile `backend:`). Any of the explicit selections above override the
   default.

To migrate an existing binding to a different backend, you must
`yolo rm -n NAME` first.

## When to use podman

- You want to run **graphical apps**. The matchlock backend doesn't have a
  display server forwarding path; podman bind-mounts your Wayland socket.
- You want `yolo stop` to **preserve state**. Podman keeps the writable
  layer between stop and start; matchlock has no checkpoint/restore.
- You don't need full VM-level isolation. Containers share the host
  kernel.

## When to use matchlock

- You want **kernel-level isolation** for the workspace.
- You need `yolo export` / `yolo import` to move a fully provisioned
  environment between hosts.
- You want **egress allow-listing** via `YOLO_ALLOW`.

### matchlock on macOS (Apple Silicon)

matchlock is not Linux-only: on Apple Silicon it runs the same micro-VM
model on **Virtualization.framework** instead of Firecracker, with the same
CLI and yolo backend. It is the way to get `export`/`import` and egress
allow-listing on a Mac (Apple's `container` backend has neither).

- Install it with Homebrew: `brew tap jingkaihe/essentials && brew install
  matchlock`. yolo's `install.sh` flags whether it is present but does not
  install it for you on macOS.
- Select it explicitly — `container` is still the macOS default:
  `yolo --backend matchlock`, `export YOLO_BACKEND=matchlock`, or a Yolofile
  `backend: matchlock`.
- It needs a host with **Virtualization.framework hypervisor support**
  (`matchlock diagnose` checks this). It will not boot inside a nested VM
  that lacks nested virtualization — `matchlock diagnose` reports
  "Hypervisor support is disabled" and yolo fails fast on attach.
- Like on Linux, `yolo stop` does **not** preserve state (matchlock has no
  checkpoint/restore), so a stopped VM is rebuilt + re-provisioned on the
  next attach.

## When to use container (Apple)

- You are on **macOS** (Apple silicon) and want yolo dev VMs without
  installing Docker Desktop or a Linux VM yourself. Apple's
  [`container`](https://github.com/apple/container) runs each container in
  its own lightweight Linux VM with a real kernel.
- You want `yolo stop` to **preserve state** (it resumes via
  `container start` on the next attach, like podman).
- The `container` system service must be running first
  (`container system start`); yolo expects the `container` binary on
  `$PATH`, exactly as it expects `podman` or `matchlock` for those
  backends. Install it from the
  [latest release](https://github.com/apple/container/releases/tag/1.0.0).
  If the CLI is missing, yolo fails fast with that install link rather than
  a cryptic error.

Notes and current limitations of the container backend:

- **GUI and audio passthrough are not supported** (there is no Wayland or
  PipeWire socket to forward on macOS). `--gui` / `--audio` are refused;
  use the podman backend on Linux for those.
- **`yolo export` / `yolo import` are not supported** (the export archive
  format is matchlock-specific), same as podman.
- **`yolo du` reports the disk size as unknown.** Apple's `container` does
  not expose per-container on-disk size, so yolo cannot account for it.
- `YOLO_CPUS` and `YOLO_MEM_MB` **are** honoured (the per-container VM gets
  its own CPU/RAM allocation — the default 1 GiB is too small for real
  provisioning). `YOLO_DISK_MB` is ignored.
- **DNS / networking is fixed up automatically.** Apple's `container` gives
  each VM a per-VM resolver (the vmnet gateway) that does not resolve
  external names, *and* the VM has no working IPv6 egress. yolo handles both:
  - it passes `--dns 1.1.1.1` on `container run` (override with
    `YOLO_CONTAINER_DNS`, space-separated, e.g.
    `YOLO_CONTAINER_DNS="1.1.1.1 8.8.8.8"`), and
  - before each provisioner runs it **self-heals the resolver in-guest** —
    if an external name still can't be resolved (e.g. on a container that
    was created/resumed *before* the right `--dns`), it rewrites
    `/etc/resolv.conf` with the configured nameserver(s) — and forces
    Fedora's `dnf` onto IPv4 (`ip_resolve=4`) so dnf doesn't stall on the
    dead IPv6 route.

  > A `container`'s DNS is fixed at **create** time and can't be
  > reconfigured on an existing container — the same reason Apple's own
  > tooling recreates a stale builder. Because yolo *persists and reuses*
  > containers, the self-heal step above is what makes a container created
  > before a DNS change start resolving again without a manual
  > `yolo rm`/recreate.


## GUI mode (`--gui`)

GUI mode is Wayland-only. When enabled it:

- Bind-mounts `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` from the host into the
  container at the same path.
- Sets `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` in the container.
- Bind-mounts `/dev/dri` if it exists, for hardware-accelerated rendering.
- Bind-mounts the user D-Bus socket (`$XDG_RUNTIME_DIR/bus`) if present,
  so notification daemons and similar can be reached.

X11 is intentionally unsupported. If you need to run X11-only apps,
install XWayland inside the container and let it bridge — Wayland
compositors that support it will forward XWayland clients to the
container's Wayland socket.

### Quick start

```
mkdir ~/gui && cd ~/gui
cat > Yolofile <<'YML'
---
backend: podman
gui: true
image: fedora-toolbox:44
---
#!/usr/bin/env bash
set -euo pipefail
dnf install -y gnome-text-editor
YML
yolo -- gnome-text-editor
```

## Audio passthrough (`--audio`)

Audio passthrough is podman-only (matchlock refuses it). When enabled it:

- Bind-mounts the host **PipeWire** socket (`$XDG_RUNTIME_DIR/pipewire-0`)
  into the container at the same path, if present.
- Bind-mounts the host **PulseAudio** / pipewire-pulse socket
  (`$XDG_RUNTIME_DIR/pulse/native`) if present, and sets `PULSE_SERVER` so
  PulseAudio clients connect with no extra config.
- Sets `XDG_RUNTIME_DIR` in the container so clients locate the sockets.

At least one of the two sockets must exist on the host, otherwise the
invocation fails. It is independent of `--gui`: a terminal app (e.g. a TUI
music player) can take `--audio` without `--gui`.

> **ALSA apps:** programs that talk to ALSA directly (rather than
> Pulse/PipeWire) need an ALSA→Pulse bridge **inside the image**. Install
> `alsa-plugins-pulseaudio` (or `pipewire-alsa`) and point ALSA at pulse:
>
> ```
> printf 'pcm.!default pulse\nctl.!default pulse\n' > /etc/asound.conf
> ```

### Quick start

```
mkdir ~/audio && cd ~/audio
cat > Yolofile <<'YML'
---
backend: podman
audio: true
image: fedora:44
---
#!/usr/bin/env bash
set -euo pipefail
dnf install -y alsa-plugins-pulseaudio mpg123
printf 'pcm.!default pulse\nctl.!default pulse\n' > /etc/asound.conf
YML
yolo -- mpg123 some-file.mp3
```

## Mounting host directories (`--mount`)

In addition to your `$PWD` (always mounted at `/work`), you can bind-mount
extra host directories into the guest with the repeatable `--mount` flag or
the Yolofile `mount:` front-matter key. The spec is `HOST:GUEST[:MODE]`,
where `MODE` is `ro` or `rw` (default `rw`):

```bash
# a read-write shared cache and a read-only config dir
yolo --mount ~/.cache/shared:cache --mount ./conf:etc/app:ro
```

```bash
---
# the same, from a Yolofile (comma-separated, paths inside the project only)
mount: ./cache:cache, ./conf:etc/app:ro
---
```

### Guest path resolution

The `GUEST` side is interpreted **relative to the workspace** when it is a
relative path: `cache` becomes `/work/cache` on every backend. An
**absolute** `GUEST` (e.g. `/data`) is honoured on `podman` and
`container`, which can bind-mount at any path.

**matchlock can only mount under the workspace.** Its volume mechanism
places every mount under `--workspace` (`/work`), so an absolute `GUEST`
that is not itself under `/work` is rejected with a clear error. Use a
relative guest path (which lands under `/work`) for portable Yolofiles.

### Read-only vs read-write

`MODE` defaults to `rw`. `ro` makes the mount read-only:

| Backend   | How `ro` is enforced                                              |
| --------- | ---------------------------------------------------------------- |
| matchlock | `-v HOST:guest:ro` (vs `:host_fs` for read-write)                |
| podman    | `-v HOST:GUEST:ro`                                               |
| container | `--mount type=bind,source=HOST,target=GUEST,readonly`           |

### Host-path safety

`--mount` paths you type on the command line are trusted: any absolute
host path is allowed. A Yolofile `mount:` host path, however, **must
resolve inside the project directory** — a Yolofile can be committed to a
repo or fetched from an `https://` URL, and silently mounting `~/.ssh` or
`/` read-write would widen its blast radius well beyond the `$PWD`-and-root
access it already has. To deliberately allow a Yolofile to mount host
paths outside the project, pass `--allow-absolute-mounts`.

Like `--publish`, mounts are applied **at VM creation only**. Editing
`mount:` (or passing a different `--mount`) does not remount an existing
VM — `yolo rm` and re-attach to apply the change.

### SELinux relabeling (podman)

On SELinux-enforcing hosts (Fedora, RHEL, …) an unlabeled bind mount is
**inaccessible** to the containerized process — you would see
`Permission denied` (or `crun: getcwd: Operation not permitted`) the moment
anything touches `/work`. To prevent that, the **podman** backend mounts
`/work` and every `--mount` with the shared SELinux option (`:z`), which
relabels the mounted tree to `container_file_t`. Notes:

- This **changes the SELinux labels** of the files under your project
  directory (and any `--mount` source). The shared `:z` variant keeps the
  host and other tools working; yolo deliberately avoids the exclusive `:Z`.
- It is a **no-op** where SELinux is not enforcing (other distros, the
  matchlock and container backends), so it is always applied and never
  needs configuration.
- The relabel is recursive, so the first boot over a very large project
  directory can take a moment.

## Stop/start semantics

The backends interpret `yolo stop` differently. The CLI is the same; the
side effects are not.

```
yolo                  # boot or attach
yolo stop             # matchlock:           kill VM, state lost
                      # podman / container:  stop, state preserved on disk
yolo                  # matchlock:           build a fresh VM and re-provision
                      # podman / container:  start, instant attach
```

This shows up in `yolo status`. For matchlock, a stopped/missing VM is
recreated transparently by the auto-heal pass. For podman and container,
the same pass notices the stopped/exited state and resumes via
`podman start` / `container start` instead.

## Source layout

```
backends/
  INTERFACE.md             # contract every backend implements
  matchlock.rugo           # microVM backend
  matchlock/
    yolo-export.sh         # matchlock-specific shell helpers
    yolo-import-unpack.sh  # (embedded into the binary at build time)
    yolo-import-retag.sh
  podman.rugo              # container backend (Linux)
  container.rugo           # Apple `container` backend (macOS)
```

To add another backend, drop `backends/<name>.rugo` with a `make()`
factory matching the INTERFACE contract, then register it in
`yolo.rugo`'s `require "backends" with …` line and `BACKENDS` hash.
