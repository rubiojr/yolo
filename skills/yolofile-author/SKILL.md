---
name: yolofile-author
description: Expert in authoring Yolofiles — per-project provisioning files for yolo dev VMs/containers, combining optional YAML-ish front matter (image, cpus, memory, disk-size, backend, gui, audio, publish, mount, ai-agent) with a bash body run as root in the guest. Load when writing, editing, reviewing, or debugging a Yolofile.
---

# Yolofile Author Skill

A **Yolofile** tells `yolo` how to set up the dev environment for a project
directory. It is one file, literally named `Yolofile`, at the root of the
directory you run `yolo` from. When present, it is preferred over yolo's
built-in language provisioners.

For using the resulting environment, **load the `yolo-user` skill**.

## Anatomy

A Yolofile has two parts, in order:

```bash
---
# 1. FRONT MATTER (optional) — VM-creation overrides, read on the HOST
image: fedora:44
cpus: 4
memory: 4G
disk-size: 64G
---
#!/usr/bin/env bash
# 2. BODY — a bash script run as ROOT inside the guest on first attach
set -euo pipefail
dnf -q install go git make
```

- **Front matter** is optional. If the file does **not** start with a line
  containing exactly `---`, the entire file is the bash body (fast legacy
  path).
- **Body** is plain bash piped to `bash` running as `root` in the guest.

The smallest useful Yolofile is just the body:

```bash
#!/usr/bin/env bash
set -euo pipefail
dnf -q install go git make
```

## Front matter rules

- Must be the **very first thing** in the file: the file begins with `---`
  + newline; the block ends at the next `---` line. An opening `---` with
  **no closing `---` is an error** (yolo refuses to start).
- It is a tiny YAML subset: one `key: value` per non-blank, non-comment
  line. **No** nesting, lists, or multi-line values.
- Keys are case-insensitive; `-` and `_` are interchangeable
  (`disk-size` = `disk_size`). Values are trimmed; one layer of
  surrounding `"…"` or `'…'` quotes is stripped. `#` comment lines and
  blank lines are ignored. Lines without `:` are silently ignored.
- Unknown keys produce a **warning**, not an error.

### Recognized keys

| Key                                   | Type    | Default            | Examples |
| ------------------------------------- | ------- | ------------------ | -------- |
| `image`                               | string  | backend default    | `fedora:44`, `registry.io:5000/foo:bar` |
| `cpus`                                | integer | `2`                | `4`, `8` |
| `memory`                              | size    | `2048` (MiB)       | `4G`, `2048M`, `2048` |
| `disk-size` (aliases `disk`, `disk_mb`) | size  | `32768` (MiB)      | `64G`, `100g`, `32768` |
| `backend`                             | string  | `matchlock`        | `matchlock`, `podman` |
| `gui`                                 | bool    | `false`            | `true`, `false` |
| `audio`                               | bool    | `false`            | `true`, `false` |
| `publish`                             | ports   | unset              | `8080`, `8080:80`, `8080:80, 5432:5432` |
| `mount`                               | mounts  | unset              | `./data:data`, `./conf:etc/app:ro` |
| `ai-agent`                            | string  | unset              | `opencode`, `copilot`, `none`, `default` |
| `description`                         | string  | —                  | free-form; ignored by yolo (annotation only) |

**Size format** (`memory`, `disk-size`): `32G`/`32g` (GiB),
`32GB`/`32gb` (trailing B allowed), `512M`/`512m` (MiB), or a bare integer
= MiB. Zero, negative, or junk values are errors.

**`image` is allowlisted to `[A-Za-z0-9._/:@+-]`.** Quotes, whitespace,
`$`, backticks, `;`, and shell metacharacters are **rejected** — the value
flows into a host-side `matchlock run` command, so this blocks injection
(e.g. `image: 'fedora:44; rm -rf ~'`). Keep image refs plain.

**`backend`** picks the runtime: `matchlock` (Firecracker microVM) or
`podman` (container, GUI-capable). It is sticky — once the VM is created,
the recorded backend wins over any later front-matter change. To switch,
`yolo rm` first.

**`publish`** forwards guest ports to the host so you can reach a VM
service. Front matter has no lists, so use a comma-separated value of
`[HOST:]GUEST` specs: `publish: 8080:80, 5432:5432`. A bare `PORT` means
`PORT:PORT`. Ports must be `1–65535` (digits only — like `image`, the
value flows into a host-side shell command). Bound to `127.0.0.1` on both
backends; the **guest** service must listen on `0.0.0.0`. Applied at VM
creation only (edit → `yolo rm` → `yolo` to change). A CLI `--publish`
flag replaces this list.

**`mount`** bind-mounts **extra** host directories into the guest, on top
of `$PWD` (always at `/work`). Repeat the key — **one `HOST:GUEST[:MODE]`
per line**; `MODE` is `ro` or `rw` (default `rw`):

```
mount: ./data:data
mount: ./conf:etc/app:ro
```

(A comma is not a separator and is rejected inside a path.)
A **relative** `GUEST` lands under `/work` (`data` → `/work/data`) and is
portable across backends; an **absolute** `GUEST` works on `podman`/
`container` but is rejected by `matchlock` (which confines mounts to
`/work`). For safety, a Yolofile `mount:` **host** path must resolve
**inside the project directory** — absolute host paths and `..` escapes
are rejected unless the user runs with `--allow-absolute-mounts` (a
Yolofile may be fetched from an untrusted URL, so it can't silently mount
`~/.ssh` or `/`). Applied at VM creation only; a CLI `--mount` replaces
this list.

**`gui`/`audio`** only take effect with `backend: podman` (bind-mount the
host Wayland / PipeWire sockets). They are refused under matchlock.

**`ai-agent`** layers an AI coding agent on top of the body. Values:
a known agent (`opencode`, `copilot`); `default`/`true` (= the built-in
default, currently `opencode`); `none`/`false`/empty (opt out). A CLI
`--ai-agent`/`--no-ai-agent` flag always overrides this.

## The body

- Runs as **root** inside the guest, once per **body content hash**.
- Your project (`$PWD`) is live-mounted at `/work` (read-write).
- Has the guest's network (NAT by default → real TLS; `dnf`/`curl`/`go
  install`/`git clone` work out of the box).
- **No implicit `set -e`.** Add `set -euo pipefail` yourself.
- Must be **idempotent** — yolo re-runs it whenever the body changes, and
  users may force re-runs with `yolo provision`.
- Built-in provisioner scripts assume a **Fedora base** and use `dnf`. If
  you change `image:` to a non-Fedora base, use that distro's package
  manager in the body.

### Persistence model (important)

- Changes the body makes to the **rootfs** (installed packages, files under
  `/root`, `/etc`, `/usr/local`, …) persist for the life of the VM and are
  captured by `yolo export`.
- Durable **project data** belongs under `/work` (the host filesystem) —
  it outlives the VM entirely.
- On **matchlock**, `yolo stop` discards the rootfs (next attach rebuilds +
  re-provisions). On **podman**, stop preserves it. Don't rely on
  by-hand-installed state surviving a matchlock stop — put it in the
  Yolofile.

## Re-provisioning (how edits take effect)

yolo stores a marker `yolofile:<sha256(body)[:12]>` per VM.

- **Edit the body → it re-runs automatically** on next `yolo`. No
  `--force`, no `yolo provision` needed.
- **Edit only the front matter → it does NOT re-provision.** Resource
  values (`image`, `cpus`, `memory`, `disk-size`) apply only at VM
  **creation** (matchlock can't resize/re-image an existing rootfs). To
  apply them:

  ```bash
  yolo rm    # destroys the VM + rootfs
  yolo       # recreates with the new front matter
  ```

This is deliberate: yolo won't silently destroy rootfs state just because
you tweaked a memory number.

## Precedence

For each resource setting, highest wins: **CLI flag** (e.g. `--disk-size`)
> **Yolofile front matter** > **`$YOLO_*` env var** > **built-in default**
(`fedora:44`, 2 CPU, 2048 MiB, 32768 MiB). A per-VM image pinned by
`yolo import` overrides everything for that name.

## Scope (which commands read front matter)

Front matter is parsed only for VM-creating subcommands: `yolo` (attach),
`yolo provision`, `yolo export`. Maintenance commands (`rm`, `stop`,
`logs`, `id`, `status`, `prune`, `ls`, `du`, `import`) **never** parse it —
so a broken Yolofile can't block recovery.

## Authoring checklist

- [ ] First line is `---` only if you want front matter (and there is a
      matching closing `---`).
- [ ] Body starts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- [ ] Script is idempotent (safe to re-run): guard installs, use `-y`/
      `assumeyes`, `mkdir -p`, `ln -sf`, etc.
- [ ] Package manager matches the `image:` distro (default Fedora → `dnf`).
- [ ] Durable tooling goes in the Yolofile; durable data goes under
      `/work`.
- [ ] `image:` is a plain allowlisted ref (no shell metacharacters).
- [ ] Echo progress (`echo "==> installing X"`) so users see what runs.

## Examples

### Minimal (legacy, no front matter)

```bash
#!/usr/bin/env bash
set -euo pipefail
dnf -q install go git make
```

### Bigger Rust build VM

```bash
---
cpus: 8
memory: 16G
disk-size: 100G
---
#!/usr/bin/env bash
set -euo pipefail
dnf -q install gcc git make
curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
```

### Custom base image (nothing to install)

```bash
---
image: registry.internal.example.com:5000/yolo/rust-base:2026-03
cpus: 4
memory: 8G
---
#!/usr/bin/env bash
set -euo pipefail
echo "base image already has everything; nothing to do"
```

### Podman + GUI (Wayland app)

```bash
---
backend: podman
gui: true
image: fedora-toolbox:44
---
#!/usr/bin/env bash
set -euo pipefail
dnf install -y gnome-text-editor
```
Run with: `yolo -- gnome-text-editor`

### With an AI agent pinned

```bash
---
image: fedora:44
ai-agent: opencode
---
#!/usr/bin/env bash
set -euo pipefail
dnf -q install go git make
```

### Node toolchain on Fedora

```bash
---
description: Node 22 dev environment
memory: 4G
---
#!/usr/bin/env bash
set -euo pipefail
NODE_VER="${YOLO_NODE_VERSION:-22}"
dnf -q install "nodejs${NODE_VER}" npm git
corepack enable
echo "==> node $(node --version), npm $(npm --version)"
```
