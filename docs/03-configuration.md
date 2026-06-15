# 3. Configuration

Almost everything `yolo` does is configurable through environment
variables, with a couple of CLI flags layered on top for one-off
overrides.

## 3.1 Quick recipes

A bigger VM for a Rust build:

```bash
YOLO_CPUS=8 YOLO_MEM_MB=8192 YOLO_DISK_MB=65536 yolo
```

A tight, throwaway VM for a single script:

```bash
YOLO_DISK_MB=4096 YOLO_MEM_MB=512 yolo --no-provision -- ./script.sh
```

A different base image, just for this run:

```bash
YOLO_IMAGE=registry.fedoraproject.org/fedora:41 yolo
```

A bigger rootfs for this invocation only (no env var needed):

```bash
yolo --disk-size 64G
```

For per-project configuration that travels with the repo, use a
[Yolofile](./05-yolofile.md) instead of environment variables.

## 3.2 Environment variables

| Var               | Default        | Effect |
| ----------------- | -------------- | ------ |
| `YOLO_IMAGE`      | `fedora:44`    | OCI image to use (any matchlock-supported reference). |
| `YOLO_CPUS`       | `2`            | vCPU count. Matchlock's stock default is 1. |
| `YOLO_MEM_MB`     | `2048`         | Guest memory in MiB. Matchlock's stock default is 512. |
| `YOLO_DISK_MB`    | `32768`        | Guest rootfs disk in MiB (32 GiB). Also settable per-invocation with `--disk-size`. |
| `YOLO_WORKSPACE`  | `/work`        | Guest mount point for `$PWD`. |
| `YOLO_NAME`       | `cwd-<sha1>`   | Override the auto-derived name. |
| `YOLO_USER`       | unset          | Pass `--user uid:gid` to matchlock for non-root execution. |
| `YOLO_ALLOW`      | unset          | Enables matchlock's MITM allow-list mode — see [Networking](./06-networking.md). |
| `YOLO_GO_VERSION` | _latest_       | Pin the Go version in `fedora-go`. Default resolves `https://go.dev/VERSION?m=text`. |
| `XDG_RUNTIME_DIR` | `/tmp`         | Where `yolo` keeps its name → vm-id state files. |

> **Matchlock's stock 5120 MiB disk fills up during a Go-toolchain
> provision.** `yolo`'s 32 GiB default is intentionally generous; you can
> shrink it for cheap one-off runs but the built-in provisioners assume
> there's at least ~10 GiB available.

## 3.3 CLI flags

`-n NAME` (also `--name`)
:   Target a specific named VM instead of the per-CWD one. See
    [Daily usage § Multiple persistent VMs](./02-usage.md#23-multiple-persistent-vms).

`--provisioner NAME`
:   Skip auto-detection and force a specific embedded provisioner
    (`fedora-go`, `fedora-rust`, `fedora-ruby`, `fedora-android`).
    Overrides a project-local Yolofile.

`--yolofile PATH|URL`
:   Use a Yolofile from a local path or an `https://` URL instead of
    `./Yolofile`. Its front matter still applies before VM creation and
    its body is used as the provisioner.

`--ephemeral`
:   Use a generated throwaway VM name and an empty temporary host
    workspace mounted at `/work`. The VM/container and temp directory are
    removed after the shell or `-- CMD` exits. Works standalone, with
    `--provisioner NAME`, or with `--yolofile PATH|URL`.

`--no-provision` (alias `--no-provisioner`)
:   Skip provisioning entirely — pure base image.

`--disk-size SIZE`
:   Override `YOLO_DISK_MB` for this run. Accepts `32G`, `32g`, `512M`,
    `512m` (case-insensitive, optional trailing `B`/`b`), or a bare
    integer (interpreted as MiB). **Only takes effect when the VM is
    first created** — matchlock cannot resize an existing rootfs.

`--ai-agent [NAME]`
:   After running the normal language provisioner, layer an AI agent
    installer on top. Currently `opencode` (default if you pass
    `--ai-agent` with no argument) and `copilot`. May also be set via
    the `ai-agent:` front-matter key in a Yolofile.

`-- CMD ARGS...`
:   Everything after `--` is the command to run inside the VM instead of
    an interactive shell.

## 3.4 Sizing notes

The defaults are tuned for moderate development workloads. Adjustments
worth knowing about:

- The `fedora-go` provisioner needs **~10 GiB** of disk at peak: ~600 MB
  for the dnf base, ~200 MB for the Go tarball, plus build caches for
  `gopls`, `golangci-lint`, `dlv`, etc.
- Bumping memory above 2 GiB mostly helps `go install` of larger
  projects and parallel compilers.
- `YOLO_CPUS` controls vCPU count. There's no reason to set it higher
  than your host has physical (or hyper-threaded) cores.
- The rootfs is sparse — `YOLO_DISK_MB=65536` only **allows** the guest
  to grow to 64 GiB. It does not pre-allocate that space on the host.
  See `yolo du` for actual usage.

## 3.5 Precedence

For each resource setting, the value that wins is, from highest to
lowest priority:

1. **CLI flag** (e.g. `--disk-size`).
2. **Yolofile front matter** (see [Yolofile reference](./05-yolofile.md)).
3. **`$YOLO_*` environment variable.**
4. **Built-in default** (`fedora:44`, 2 CPU, 2048 MiB, 32768 MiB).

A per-VM image pin set by `yolo import` overrides the resolved `image`
from the steps above. See
[Export & import](./07-export-import.md).
