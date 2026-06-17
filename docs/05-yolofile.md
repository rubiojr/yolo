# 5. Yolofile reference

A `Yolofile` is a per-project file (always named `Yolofile`, always at the
root of the directory you run `yolo` from) that tells `yolo` how to set up
the microVM for that directory.

This chapter starts with a quick tutorial, then covers the full file
format. For higher-level provisioner concepts (built-ins, AI agents,
auto-detection) see [chapter 4](./04-provisioners.md).

## Tutorial

The smallest useful Yolofile is three lines of bash:

```bash
# ~/code/my-project/Yolofile
#!/usr/bin/env bash
set -euo pipefail
dnf -q install go git make
```

Drop it at the root of your project and run:

```bash
cd ~/code/my-project
yolo
# [yolo] applying yolofile:2ade95cded20 to vm-xxxxxxxx
# (your bash body runs as root inside the VM)
```

After provisioning, you land in `/work` with your project mounted and
Go installed. Subsequent `yolo` invocations in this directory reattach
in under a second and **skip** the Yolofile — the content hash hasn't
changed.

Edit the Yolofile and re-run `yolo` — the hash changes, so the script
runs again automatically. You don't need `--force` or `yolo provision`.

If you also want to tune the VM itself (more memory, a different base
image, …), add a YAML-style front matter block at the very top:

```bash
---
image: fedora:44
cpus: 4
memory: 4G
disk-size: 64G
---
#!/usr/bin/env bash
set -euo pipefail
dnf -q install go git make
```

Front matter is read by `yolo` on the host side **before** the VM is
created. It does **not** trigger re-provisioning (matchlock cannot
resize an existing rootfs); to apply new resource limits you have to
`yolo rm` the VM first.

The rest of this chapter is the canonical reference for the file
format.

## File structure

A Yolofile has two parts, in order:

1. **Front matter** *(optional)* — a YAML-ish block of VM-creation overrides
   (plus optional metadata such as `description`) wrapped between two `---`
   delimiter lines.
2. **Body** — a plain `bash` script, run as `root` inside the guest microVM
   via `matchlock exec -i -- bash` the first time you attach (and again
   whenever the body changes — see [Re-provisioning](#re-provisioning)).

## Detection

`yolo` looks for a file literally named `Yolofile` in the current working
directory. If found, it is preferred over the built-in provisioners
(`fedora-go`, `fedora-rust`, …). Use `--no-provisioner` to skip it for a
single run; use `--provisioner NAME` to force a specific built-in instead.

Use `--yolofile PATH|URL` to provide a Yolofile from another local path or
from an `https://` URL. Explicit Yolofiles override `./Yolofile`; `http://`
URLs are rejected.

For throwaway environments, `--ephemeral --yolofile PATH|URL` provisions the
Yolofile into an empty temporary workspace and removes the VM/container and
workspace after the shell or command exits.

## Front matter

Front matter, when present, **must be the very first thing in the file** —
the file must begin with a line containing exactly `---` (followed by a
newline). The block ends at the next `---` line. Everything before the
opening `---` is parsed as front matter; everything after the closing `---`
is the bash body.

If the file does not start with `---`, the entire file is treated as the
body. This is the fast path for legacy Yolofiles — no front matter parsing
runs, and the file's sha256 (used for the re-provisioning marker) is
bit-identical to what it was before front matter existed.

### Syntax

Front matter is a tiny subset of YAML. Each non-blank, non-comment line is
a single `key: value` pair.

- **Keys** are case-insensitive. `-` and `_` are interchangeable, so
  `disk-size`, `Disk-Size`, and `disk_size` all refer to the same key.
- **Values** are everything after the first `:` on the line, trimmed of
  surrounding whitespace. A single layer of surrounding `"..."` or `'...'`
  quotes is stripped.
- **Comments** — lines whose first non-blank character is `#` — are ignored.
- **Blank lines** inside the block are ignored.
- Lines without a `:` are ignored (no error).
- Indentation is not meaningful. Nested mappings and lists are **not**
  supported. Multi-line values are **not** supported.
- An opening `---` with no matching closing `---` is an **error** —
  `yolo` exits without starting a VM, because executing a stray `---`
  delimiter as bash would be silly.

### Recognized keys

| Key                                      | Type    | Default      | Example values                          |
| ---------------------------------------- | ------- | ------------ | --------------------------------------- |
| `image`                                  | string  | *(backend default)* | `fedora:44`, `registry.io:5000/foo:bar` |
| `cpus`                                   | integer | `2`          | `4`, `8`                                |
| `memory`                                 | size    | `2048` (MiB) | `4G`, `2048M`, `2048`                   |
| `disk-size` *(aliases: `disk`, `disk_mb`)* | size    | `32768` (MiB)| `64G`, `100g`, `32768`                  |
| `backend`                                | string  | `matchlock`  | `matchlock`, `podman`                   |
| `gui`                                    | bool    | `false`      | `true`, `false`                         |
| `audio`                                  | bool    | `false`      | `true`, `false`                         |
| `publish`                                | ports   | *(none)*     | `8080`, `8080:80`, `8080:80, 5432:5432` |
| `ai-agent`                               | string  | *(unset)*    | `opencode`, `copilot`, `none`, `default` |
| `description`                            | string  | *(unset)*    | `Dev VM for the billing API`            |

Unknown keys produce a warning (`Yolofile: ignoring unknown front matter
key '...'`) but do not stop the run, so you can add a comment-like key
during development without breaking the build.

#### `backend`

Which runtime executes the VM: `matchlock` (Firecracker microVMs) or
`podman` (containers, with optional GUI support). Once a VM is created
the backend choice is recorded in `<name>.backend` and becomes sticky —
subsequent `yolo` invocations under that name use the recorded backend
regardless of any front matter override. To switch a project to a
different backend, `yolo rm` it first, then re-attach with the new
`backend:`.

See [Backends](./09-backends.md) for the capability matrix.

#### `gui`

Boolean. When `true` and `backend` is `podman`, the container is created
with the host's Wayland socket bind-mounted so graphical apps render on
the host compositor. Has no effect when `backend` is `matchlock`
(matchlock would refuse the invocation; see `--gui` in `yolo --help`).

#### `audio`

Boolean. When `true` and `backend` is `podman`, the container is created
with the host's PipeWire/PulseAudio socket(s) bind-mounted so apps can
play sound. Independent of `gui` — a terminal app can use `audio: true`
without `gui`. Has no effect when `backend` is `matchlock` (it would
refuse the invocation; see `--audio` in `yolo --help`). Apps that use
ALSA directly need an ALSA→Pulse bridge in the image; see
[Backends](./09-backends.md#audio-passthrough---audio).

#### `publish`

Publish one or more guest ports to the host so you can reach a service
running inside the VM (a dev web server, a database, etc.). Equivalent to
passing `--publish` on the command line.

Front matter can't express lists, so `publish` takes a **comma-separated**
value. Each entry is `[HOST_PORT:]GUEST_PORT`:

```bash
---
# one port, same number on both sides (8080 -> 8080)
publish: 8080
---
```

```bash
---
# remap host 8080 -> guest 80, and expose postgres on 5432
publish: 8080:80, 5432:5432
---
```

Rules and behaviour:

- A bare `PORT` is expanded to `PORT:PORT`, so the host port is always
  deterministic (on `podman`, a bare port would otherwise pick a random
  host port).
- Each port must be an integer in `1–65535`. Anything else — extra colons,
  non-numeric text, out-of-range numbers — is an error. The digits-only
  shape is also a safety property: the value flows into a host-side
  `matchlock run` / `podman run` command, like `image`.
- Ports are bound on **`127.0.0.1`** (loopback) on both backends, so a
  published service is reachable from the host but not from your LAN.
- The **guest** service must listen on `0.0.0.0` (not `127.0.0.1`), or the
  forwarded connection has nothing to talk to.
- Publishing happens at **VM creation** only (like `cpus` / `memory` /
  `disk-size`). Editing `publish:` does **not** re-publish on an existing
  VM — `yolo rm` then `yolo` to apply the change.
- A CLI `--publish` flag **replaces** the front-matter list for that run.

See [Networking § Publishing guest ports](./06-networking.md#67-publishing-guest-ports-to-the-host)
for a full walkthrough.

#### `image`

The OCI image `matchlock` boots into. For safety, `yolo` only accepts a
conservative character set in front matter: `[A-Za-z0-9._/:@+-]`. This is
stricter than the OCI spec but covers every reasonable registry, port,
tag, and digest reference. Quotes, whitespace, `$`, backticks, `;`, and
shell metacharacters are rejected because the value flows into a
host-side `matchlock run` shell command.

> ⚠️ The Yolofile is run as part of `yolo` invocations on your host
> shell; treat it like any other repo-supplied script. The `image`
> allowlist exists specifically to prevent a hostile `image:` value
> (e.g. `image: 'fedora:44; rm -rf ~'`) from escaping the shell command
> that boots the VM.

If a per-VM image has been pinned via `yolo import` (see `yolo import
--help`), the pinned image wins over the Yolofile.

#### `cpus`

A positive integer. Non-integers and `0` are an error.

#### `memory` and `disk-size`

Both accept the same human-readable size format:

- `32G` / `32g` (GiB)
- `32GB` / `32gb` (same — trailing `B`/`b` is allowed)
- `512M` / `512m` / `512MB` / `512mb` (MiB)
- A bare integer is interpreted as **MiB** (for parity with the
  `$YOLO_MEM_MB` / `$YOLO_DISK_MB` environment variables).

Negative or zero values, missing/invalid units, and trailing junk are all
errors.

#### `ai-agent`

Layer an AI coding agent on top of the language provisioner, equivalent to
passing `--ai-agent NAME` on the command line. Recognised values:

- A known agent name (`opencode`, `copilot`). Unknown names are an error.
- `default` / `true` — install the built-in default agent (currently
  `opencode`); the same as passing `--ai-agent` with no name.
- `none` / `false` / empty string — explicitly opt out; equivalent to
  `--no-ai-agent`.

Precedence: a CLI flag (`--ai-agent` or `--no-ai-agent`) always wins over
the front-matter value, which in turn wins over the unset default of "no
agent". The agent layer is tracked under its own re-provisioning marker
(`ai-agent:NAME`), so swapping it in/out via front matter triggers exactly
the agent install, not a full re-provision of the language stack.

#### `description`

A free-form, human-readable note describing what the Yolofile sets up.

It is **purely documentation**: `yolo` accepts the key (so it does not emit
the unknown-key warning) but never reads, validates, or displays the value,
and it has no effect on the VM. Use it to annotate the file for whoever
reads it next:

```bash
---
image: fedora:44
description: Build + test VM for the billing API (Go 1.23, postgres client)
---
#!/usr/bin/env bash
set -euo pipefail
dnf -q install go postgresql
```

Because the value never reaches a shell or the terminal, there is no
character allowlist or length limit (unlike `image`). It does, however,
share the one-line front-matter constraint: the value is everything after
the first `:` on a single line — multi-line descriptions are not supported.

## Body

Anything after the closing `---` (or the entire file, if there is no
front matter) is treated as a bash script and piped to `bash` running
as `root` inside the guest microVM.

The provisioner script:

- Runs once per **content hash** — see [Re-provisioning](#re-provisioning).
- Has no implicit `set -e`. Add `set -euo pipefail` yourself.
- Has access to the guest's network and any host paths that `matchlock`
  exposes (your `$PWD` is live-mounted at `/work` by default).
- Should be **idempotent** — `yolo` may re-run it if the content changes.

## Re-provisioning

`yolo` stores a `marker` per VM derived from
`sha256(yolofile_body)[:12]`. On every attach it compares the current
hash to the stored one and re-runs the provisioner if they differ.

This intentionally hashes **only the body**, not the front matter:

- **Editing the body re-provisions.** Adding a new `dnf install` line or
  changing a Go version will re-run the script on next attach.
- **Editing front matter does NOT re-provision.** Resource values
  (`memory`, `disk-size`, `cpus`, `image`) only take effect at VM
  **creation**. `matchlock` cannot resize or re-image an existing rootfs.
  To apply new front matter, you have to `yolo rm` the VM and let `yolo`
  recreate it:

  ```
  yolo rm     # remove the VM and its rootfs
  yolo        # next attach picks up the new front matter
  ```

  This is also why `yolo` does not implicitly re-create on front-matter
  changes: you would lose any state in the rootfs (installed packages,
  caches) without an explicit confirmation.

## Precedence

For each resource setting, the value that "wins" is, from highest to
lowest priority:

1. **CLI flag** — currently only `--disk-size SIZE` is exposed as a flag.
2. **Yolofile front matter** — what this document describes.
3. **`$YOLO_*` environment variable** — `$YOLO_IMAGE`, `$YOLO_CPUS`,
   `$YOLO_MEM_MB`, `$YOLO_DISK_MB`.
4. **Built-in default** — `fedora:44`, 2 CPU, 2048 MiB, 32768 MiB.

Per-VM image pins set by `yolo import FILE [-n NAME]` are applied
inside `start_vm` and override the resolved `image` from the steps
above.

## Scope

Front matter is parsed and applied only for subcommands that may create
or recreate a VM:

- `yolo` (the default — attach, creating the VM if needed)
- `yolo provision`
- `yolo export`

Maintenance subcommands — `yolo ls`, `yolo stop`, `yolo rm`, `yolo logs`,
`yolo id`, `yolo status`, `yolo prune`, `yolo provisioners`, `yolo
import`, `yolo du` — **do not parse front matter at all**, so a syntax
error in your Yolofile cannot brick `yolo rm` or block recovery.

## Examples

### Legacy Yolofile (no front matter)

```bash
#!/usr/bin/env bash
set -euo pipefail
dnf -q install go git make
```

Behaviour: built-in defaults for image, CPUs, memory, and disk size. The
sha256 of this file is unchanged from the pre-front-matter era, so
upgrading `yolo` will not trigger a spurious re-provision.

### Front matter for a bigger Rust build VM

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

### Custom base image (private registry)

```bash
---
image: registry.internal.example.com:5000/yolo/rust-base:2026-03
cpus: 4
memory: 8G
---
#!/usr/bin/env bash
set -euo pipefail
echo "image already has everything we need; nothing to do"
```

### Override disk size for one-off runs

The body and front matter stay the same; pass `--disk-size` on the CLI:

```
yolo --disk-size 256G
```

This wins over any `disk-size` in the Yolofile front matter for the
**creation** of the VM. Subsequent `yolo` invocations attach to the same
VM and ignore both flag and front matter (existing rootfs is not
resized).
