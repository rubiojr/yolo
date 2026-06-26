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
| Host platform                       | Linux (KVM)      | Linux                         | macOS (Apple silicon)         |
| Isolation                           | KVM microVM      | Container (host kernel)       | Per-container Linux VM        |
| Boot time (post first pull)         | ~1–2 s           | <1 s                          | ~1–2 s                        |
| In-guest state across `yolo stop`   | **Not preserved** (recreate on next attach) | **Preserved** (resume on next attach) | **Preserved** (resume on next attach) |
| GUI apps (Wayland)                  | No               | Yes (`--gui`)                 | No                            |
| Audio (PipeWire/PulseAudio)         | No               | Yes (`--audio`)               | No                            |
| Publish guest ports (`--publish`)   | Yes              | Yes                           | Yes                           |
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
5. **Built-in default: `matchlock`.**

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
  backends.

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
