# yolo

> Fast, persistent, per-directory [matchlock][matchlock] microVMs with
> one-shot provisioning. Written in [rugo][rugo].

[matchlock]: https://github.com/jingkaihe/matchlock
[rugo]: https://github.com/rubiojr/rugo

```
~/code/my-project
❯ yolo
[yolo] starting fedora:44 VM cwd-7259073de3 for /home/rubiojr/code/my-project
[yolo] applying fedora-go to vm-b1e68449
==> [yolo:fedora-go] installing Go 1.26.3 (amd64)
…
[root@cwd-7259073de3 work]# go version
go version go1.26.3 linux/amd64
[root@cwd-7259073de3 work]# exit

~/code/my-project
❯ yolo                                  # <1s, attaches to the same VM
[root@cwd-7259073de3 work]#
```

## Features

- **Per-directory persistent microVMs.** Each `$PWD` gets its own
  long-lived Firecracker VM, keyed by a sha1 of the path. Re-running
  `yolo` reattaches in under a second.
- **Auto-heal.** If the VM was stopped or removed (host reboot, manual
  `matchlock rm`, …) `yolo` notices and recreates it transparently.
- **Auto-detected provisioning.** `yolo` sniffs your project for
  `go.mod` / `Cargo.toml` / `Gemfile` / `build.gradle` and applies a
  matching built-in provisioner. Project-specific tooling lives in an
  optional [`Yolofile`](./docs/05-yolofile.md).
- **Named VMs.** Run several persistent VMs side-by-side with `-n NAME`.
- **Your code is mounted live.** `$PWD` shows up inside the guest as
  `/work` (read-write), so edits on either side are immediately
  visible on the other.
- **Snapshot & share.** `yolo export` / `yolo import` move a fully
  provisioned VM between hosts.
- **Sensible network defaults.** Plain NAT by default with real
  upstream TLS, so `dnf install`, `curl https://…`, `go install`, and
  `git clone` just work. Opt into matchlock's allow-list MITM policy
  via `YOLO_ALLOW=…`.

## Requirements

- Linux with KVM (`/dev/kvm` readable and writable)
- [`matchlock`](https://github.com/jingkaihe/matchlock#install) on `PATH`
- For end users: just the prebuilt `yolo` binary (~2 MB static; no
  other runtime deps — provisioners are plain bash run inside the
  guest).
- For building from source: [`rugo`](https://github.com/rubiojr/rugo#install).

## Install

```bash
# One-step install on Fedora (matchlock + yolo)
curl -fsSL https://raw.githubusercontent.com/rubiojr/yolo/main/web/install.sh | bash

# Prebuilt binary
install -m 0755 yolo ~/.local/bin/yolo

# From source
rugo build yolo.rugo
install -m 0755 yolo ~/.local/bin/yolo
```

## Basic usage

```bash
# Interactive shell in this directory's VM (creates it the first time)
yolo

# Run a single command inside the VM
yolo -- go test ./...

# Open a separate persistent named VM
yolo -n notes

# List everything yolo is tracking
yolo ls

# Stop or remove
yolo stop          # preserves rootfs
yolo rm            # removes the VM and its name binding
```

Full subcommand reference: [`docs/02-usage.md`](./docs/02-usage.md) (or
`yolo --help`).

## Documentation

A chapter-by-chapter tour lives in [`docs/`](./docs/README.md):

1. [Getting started](./docs/01-getting-started.md)
2. [Daily usage](./docs/02-usage.md)
3. [Configuration](./docs/03-configuration.md)
4. [Provisioners](./docs/04-provisioners.md)
5. [Yolofile reference](./docs/05-yolofile.md)
6. [Networking](./docs/06-networking.md)
7. [Export & import](./docs/07-export-import.md)
8. [Troubleshooting](./docs/08-troubleshooting.md)

For internals (auto-heal, state file layout, provisioner markers,
source layout) see [`docs/architecture.md`](./docs/architecture.md).

## License

MIT.
