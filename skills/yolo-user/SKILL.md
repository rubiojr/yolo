---
name: yolo-user
description: Guide to using the yolo CLI — fast, persistent, per-directory matchlock microVM / podman container dev environments with one-shot provisioning. Load when running yolo to create or attach dev VMs, running commands inside them, managing named/ephemeral VMs, picking a backend, exporting/importing environments, or troubleshooting yolo usage.
---

# yolo User Skill

`yolo` gives every project directory its own fast, persistent, isolated
dev environment. Run `yolo` in a directory and you land in a root shell
inside a VM (or container) with your code live-mounted at `/work` and the
right toolchain already installed.

- To author a `Yolofile` for a project, **load the `yolofile-author`
  skill**.
- To work on yolo's own source code, **load the `yolo-developer` skill**.

## Sandboxed agents: use the podman backend

> **If you are an AI agent running in a sandbox (landlock/seccomp, no
> `/dev/kvm`), the default matchlock backend WILL NOT WORK.** matchlock
> needs KVM (a microVM), which sandboxes block. Use the **podman** backend
> for every invocation.

Pick podman for the whole session up front:

```bash
export YOLO_BACKEND=podman      # default backend for all yolo commands
```

…or pass it explicitly on every VM-creating command (`yolo`, `yolo
provision`): `yolo --backend podman -- CMD`. The choice is **sticky** —
once a VM is created its backend is recorded, so you only need to set it at
creation time.

Quick check before you start:

```bash
podman info >/dev/null 2>&1 && echo "podman OK" || echo "no podman"
ls /dev/kvm 2>/dev/null && echo "kvm present" || echo "no kvm -> matchlock unavailable"
```

Consequences of being on podman (all fine for agent use): state is
**preserved** across `yolo stop`, there is **no** `export`/`import`, no
`YOLO_ALLOW` egress filtering, and `YOLO_DISK_MB` is ignored (it uses the
host filesystem). GUI (`--gui`) and audio (`--audio`) passthrough are
podman-only and work here. See **Backends** below for the full matrix.

Prefer non-interactive `yolo -- CMD` form (not the bare interactive shell)
so commands are scriptable and exit codes propagate. A harmless `sh: line
1: /dev/tty: No such device or address` may print when there is no
controlling TTY — the command still runs; ignore it.

## Mental model (read this first)

- **One VM per `$PWD`.** The VM is keyed by a hash of the directory path.
  Re-running `yolo` in the same directory reattaches in <1s.
- **`/work` is your `$PWD`, live.** Edits on host or guest are instantly
  visible on both sides. Your project is **not** copied into the VM.
- **The rootfs is ephemeral-ish.** Packages you `dnf install` by hand live
  only as long as the VM. Put durable setup in a [Yolofile] or a custom
  image; put durable *data* under `/work` (host filesystem).
- **Provisioning runs once per VM**, the first time you attach (and again
  only if the provisioner source changes).
- **Auto-heal.** If the VM was removed (reboot, manual cleanup), the next
  `yolo` silently rebuilds it. You rarely need to clean up by hand.
- **Each `yolo` exec is its own PID namespace.** Two `yolo` shells share
  the filesystem (`/work`, `$HOME`, the disk) but **cannot see each
  other's processes**. For long-running services use a supervisor inside
  the guest.

## Requirements & install

- Linux with **KVM** (`/dev/kvm` readable+writable; add yourself to the
  `kvm` group) for the default matchlock backend. The podman backend needs
  **podman** instead. **In a sandbox without `/dev/kvm`, matchlock is
  unavailable — use podman (see "Sandboxed agents" above).**
- **matchlock** on `PATH` (the default backend). Verify:
  `ls -l /dev/kvm && matchlock --version`. (Skip this if you're on podman.)

```bash
# One-step install (Fedora / Ubuntu 26.04 LTS): installs matchlock + yolo
curl -fsSL https://yolo.rbel.co/install.sh | bash
# Or drop the prebuilt static binary on PATH
install -m 0755 yolo ~/.local/bin/yolo
```

## Core workflow

```bash
cd ~/code/my-project

yolo                       # attach (create first time); interactive root shell
yolo -- go test ./...      # run ONE command in the VM; exit code propagates
yolo -- bash -c 'go build && ./app --selftest'

yolo -n notes              # a separate, explicitly-named persistent VM
yolo -n notes -- vi todo.md
```

`yolo` with no args is what you use ~95% of the time. Everything after
`--` is run verbatim inside the VM (no interactive shell), which composes
cleanly with scripts and CI.

## Provisioners (automatic toolchain setup)

The first attach auto-detects a provisioner from files in `$PWD`:

| Detected files                                            | Provisioner    | Installs |
| -------------------------------------------------------- | -------------- | -------- |
| `go.mod` / `go.sum` / `*.go`                             | `fedora-go`    | Go + gopls, staticcheck, dlv, goimports, gofumpt, golangci-lint |
| `Cargo.toml` / `rust-toolchain[.toml]`                   | `fedora-rust`  | rustup stable + cargo tools |
| `Gemfile` / `.ruby-version` / `*.gemspec`                | `fedora-ruby`  | Ruby, bundler, build deps |
| `build.gradle[.kts]` / `settings.gradle[.kts]`           | `fedora-android` | OpenJDK + Android SDK pieces |

```bash
yolo provisioners                 # list built-ins + what would auto-run here
yolo --provisioner fedora-go      # force a specific one (overrides Yolofile)
yolo --no-provision               # pure base image, skip provisioning
yolo provision                    # force re-apply (idempotent)
```

Resolution order: `--provisioner NAME` > `./Yolofile` > auto-detection >
nothing. For project-specific tooling, drop a **Yolofile** (see the
`yolofile-author` skill).

## AI coding agents

Layer an AI agent on top of the language provisioner:

```bash
yolo --ai-agent                   # installs opencode (default)
yolo --ai-agent copilot           # installs copilot
yolo --no-ai-agent                # explicitly opt out
```

Authenticate inside the VM with the relevant provider key (e.g.
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). Can also be pinned via a Yolofile's
`ai-agent:` front matter (CLI flag always wins).

## Subcommand reference

```
yolo                            Ensure VM, auto-provision once, shell in.
yolo -- CMD ARGS...             Run CMD inside the VM (exit code propagates).
yolo ls                         List tracked VMs with live status.
yolo du                         List tracked VMs with disk usage.
yolo status [-n NAME]           Print state + vm-id + applied provisioners.
yolo id     [-n NAME]           Print just the vm-id (scriptable).
yolo logs   [-n NAME]           Show the VM's serial/console log.
yolo stop   [-n NAME]           Stop the VM (podman preserves state).
yolo rm     [-n NAME]           Stop + remove the VM and its name binding.
yolo prune                      Drop name bindings whose VM is gone.
yolo provision [--provisioner NAME] [-n NAME]   Force re-apply (idempotent).
yolo provisioners               List provisioners + detected Yolofile.
yolo install-skills             Install bundled agent skills into ~/.agents/skills.
yolo export [-n NAME] [-o FILE] Snapshot rootfs + state to a .tar.gz (matchlock).
yolo import FILE [-n NAME] [--force]   Restore a bundle on another host.
yolo -V | --version             Print version.
yolo -h | --help                Full help with env-var defaults.
```

## Flags

- `-n NAME` / `--name NAME` — target a named VM instead of the per-CWD one.
- `--provisioner NAME` / `-P` — force a built-in provisioner.
- `--yolofile PATH|URL` — use a Yolofile from elsewhere (`https://` only;
  `http://` rejected). Its front matter + body both apply.
- `--ephemeral` — throwaway VM with an empty temp `/work`; removed when the
  shell or `-- CMD` exits. Combine with `--provisioner` or `--yolofile`.
- `--no-provision` (alias `--no-provisioner`) — skip provisioning.
- `--ai-agent [NAME]` / `--no-ai-agent` — manage the AI agent layer.
- `--backend NAME` / `-b` — `matchlock` (default) or `podman`.
- `--gui` / `--no-gui` — bind-mount the host Wayland socket (podman only).
- `--audio` / `--no-audio` — bind-mount the host PipeWire/PulseAudio socket
  so guest apps can play sound (podman only). Independent of `--gui`; a TUI
  can take `--audio` alone. ALSA-only apps need an ALSA→Pulse bridge in the
  image (e.g. `alsa-plugins-pulseaudio` + `/etc/asound.conf` defaulting to
  pulse).
- `--disk-size SIZE` — rootfs size for THIS creation (`32G`, `512M`, or
  bare MiB). Only takes effect when the VM is first created.
- `--publish [HOST:]GUEST` / `-p` — publish a guest port to the host on
  `127.0.0.1` (e.g. `--publish 8080:80`; a bare `8080` means `8080:8080`).
  Repeatable. Works on both backends. The guest service must listen on
  `0.0.0.0`. Set at VM creation only; also a Yolofile `publish:` key
  (comma-separated). Reach it from the host with `curl 127.0.0.1:HOST`.

## Environment variables

| Var               | Default     | Effect |
| ----------------- | ----------- | ------ |
| `YOLO_IMAGE`      | backend default | OCI image (e.g. `fedora:44`). |
| `YOLO_CPUS`       | `2`         | vCPU count. |
| `YOLO_MEM_MB`     | `2048`      | Guest memory (MiB). |
| `YOLO_DISK_MB`    | `32768`     | Rootfs disk (MiB, matchlock only). |
| `YOLO_WORKSPACE`  | `/work`     | Guest mount point for `$PWD`. |
| `YOLO_NAME`       | `cwd-<sha1>`| Override the auto-derived name. |
| `YOLO_BACKEND`    | `matchlock` | Default backend. |
| `YOLO_USER`       | unset       | `--user uid:gid` for non-root exec. |
| `YOLO_ALLOW`      | unset       | Egress allow-list → matchlock MITM mode (see Networking). |
| `YOLO_GO_VERSION` | latest      | Pin Go in `fedora-go`. |

```bash
# bigger VM for one run
YOLO_CPUS=8 YOLO_MEM_MB=8192 YOLO_DISK_MB=65536 yolo
# different base image, just this run
YOLO_IMAGE=registry.fedoraproject.org/fedora:41 yolo
```

Precedence (high→low): CLI flag > Yolofile front matter > `$YOLO_*` env >
built-in default. A `yolo import` image pin overrides the resolved image.

## Backends: matchlock vs podman

| Capability                       | matchlock (default) | podman              |
| -------------------------------- | ------------------- | ------------------- |
| Isolation                        | KVM microVM         | container (host kernel) |
| State across `yolo stop`         | **lost** (recreate) | **preserved** (resume) |
| GUI apps (Wayland, `--gui`)      | no                  | yes                 |
| Audio (`--audio`)                | no                  | yes                 |
| Publish ports (`--publish`)      | yes                 | yes                 |
| `export` / `import`              | yes                 | no                  |
| `YOLO_ALLOW` egress allow-list   | yes                 | ignored             |
| `YOLO_DISK_MB` cap               | yes                 | ignored (host fs)   |
| Default image                    | `fedora:44`         | `fedora-toolbox:44` |

The backend is **sticky**: once a VM is created the choice is recorded; to
switch, `yolo rm -n NAME` first, then re-attach with the new backend. Pick
podman when you need GUI apps or stop-to-preserve state; pick matchlock for
kernel-level isolation, export/import, or egress allow-listing.

```bash
yolo --backend podman --gui -- gnome-text-editor
```

## Networking

- **Default = plain NAT.** Real upstream TLS; `dnf`, `curl https://…`,
  `go install`, `git clone` all just work. No host-level egress filtering.
- **`YOLO_ALLOW="host1,host2"`** switches matchlock into MITM allow-list
  mode (policy + observability). Caveat: the guest doesn't trust
  matchlock's ephemeral CA, so HTTPS breaks with `unable to get local
  issuer certificate`. Only use it with a CA-baked custom image, HTTP-only
  mirrors, or per-tool `--insecure` (throwaway only). If unsure, don't set
  it.

## Export / import (matchlock only)

Move a fully-provisioned environment between hosts:

```bash
yolo export                          # -> ./yolo-export-<name>-<ts>.tar.gz
yolo export -n notes -o /tmp/notes.tar.gz
# ... transfer the bundle ...
yolo import /tmp/notes.tar.gz                 # restore under original name
yolo import /tmp/notes.tar.gz -n copy --force # rename / overwrite
yolo -n copy                                  # first attach boots the captured rootfs
```

Included: rootfs changes (installed packages, `/root`, configs outside
`/work`) + applied provisioner markers. **Not** included: your `/work`
project files (host-side — re-clone on the destination), running
processes, RAM/CPU state. The bundle is **not encrypted** — treat it like
a disk image.

## Cleanup

```bash
yolo stop          # matchlock: state lost; podman: state preserved
yolo rm            # remove VM + binding + rootfs
yolo prune         # GC stale bindings whose VM is gone (safe anytime)
```

## Troubleshooting essentials

- **`cannot open /dev/kvm` / permission denied** → `sudo usermod -aG kvm
  "$USER"`, then re-login. **In a sandbox (no `/dev/kvm` at all), KVM can't
  be granted — switch to podman: `export YOLO_BACKEND=podman`.**
- **`matchlock: command not found`** → install matchlock; it is not
  bundled. (Not needed on the podman backend.)
- **`yolo stop` then `yolo` rebuilt from scratch** → expected on matchlock
  (no resume-from-stopped); use podman if you need stop-to-preserve.
- **Stale "running" VM you can't attach** → `yolo status` vs `matchlock
  list`; `yolo prune` then `yolo` auto-heals.
- **Edited Yolofile didn't re-provision** → only the **body** hash
  triggers re-run; front-matter (image/cpus/memory/disk) changes need
  `yolo rm` then `yolo`.
- **Disk filling up** → `yolo du`; clean caches in the guest or `yolo rm`.
- **TLS `unknown ca` errors** → you have `YOLO_ALLOW` set (MITM mode);
  unset it for normal use.
- Collect for bug reports: `yolo --version`, `matchlock --version`,
  `uname -a`, `yolo status`, `yolo logs | tail -200`.

The full manual lives in the repo `docs/` (chapters 01–09 +
`architecture.md`), mirrored by `yolo --help`.
