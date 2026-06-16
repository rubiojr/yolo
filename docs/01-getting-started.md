# 1. Getting started

This chapter walks you from "nothing installed" to "I have a persistent
dev environment mounted on my project directory" in three steps.

`yolo` can back that environment with either the **matchlock** (microVM,
the default) or **podman** (container) backend. This chapter uses the
default; see [Backends](./09-backends.md) to choose.

## 1.1 Requirements

Before installing `yolo` itself:

- **Linux.**
- For the **matchlock backend (default):** KVM — `/dev/kvm` must be
  readable and writable by the user that will run `yolo`. On most distros
  adding yourself to the `kvm` group is enough — log out and back in
  afterwards. Plus **[matchlock][matchlock-install]** on your `PATH`;
  `yolo` shells out to it for every VM operation.
- For the **podman backend:** just **[podman][podman-install]** on your
  `PATH` (no KVM required). Select it with `--backend podman`,
  `YOLO_BACKEND=podman`, or `backend: podman` in a Yolofile.
- For building from source only: **[rugo][rugo-install]**. End users do
  not need it — the released `yolo` binary is a single static file with
  no runtime dependencies (provisioners run as plain `bash` inside the
  guest).

[matchlock-install]: https://github.com/jingkaihe/matchlock#install
[podman-install]: https://podman.io/docs/installation
[rugo-install]: https://github.com/rubiojr/rugo#install

Verify the host side is ready (matchlock backend):

```bash
ls -l /dev/kvm
matchlock --version
```

## 1.2 Install

End users — drop the prebuilt static binary on your `PATH`:

```bash
install -m 0755 yolo ~/.local/bin/yolo
```

From source:

```bash
# Build the static binary
rugo build yolo.rugo
install -m 0755 yolo ~/.local/bin/yolo

# Or run unbuilt while hacking on yolo itself
rugo run yolo.rugo …
```

## 1.3 Your first VM

`cd` into any project and run `yolo`:

```
~/code/my-project
❯ yolo
[yolo] starting fedora:44 VM cwd-7259073de3 for /home/rubiojr/code/my-project
[yolo] applying fedora-go to vm-b1e68449
==> [yolo:fedora-go] installing Go 1.26.3 (amd64)
…
[root@cwd-7259073de3 work]# go version
go version go1.26.3 linux/amd64
```

What just happened:

1. `yolo` derived a stable name (`cwd-<sha1-prefix>`) from your current
   directory and asked `matchlock` to start a `fedora:44` VM with that
   name.
2. Your current directory was mounted into the VM at `/work` (live,
   read-write).
3. Because the directory contained `*.go` / `go.mod`, the **fedora-go**
   provisioner was auto-detected and applied. It installs Go and the
   usual companion tools, then exits.
4. You landed in `/work` inside the guest as `root`.

Try editing a file on the host: the change is immediately visible inside
the VM under `/work`. The reverse is also true — anything the VM writes
to `/work` lands on your host filesystem.

Exit the VM (`exit` or Ctrl-D) and re-run `yolo` from the same
directory:

```
~/code/my-project
❯ yolo                                  # <1s, attaches to the same VM
[root@cwd-7259073de3 work]#
```

The VM persisted. The provisioner did not re-run — `yolo` remembered it
already applied `fedora-go` to this VM.

## 1.4 Stopping and removing

- `yolo stop` — stop the VM but keep its state on disk.
- `yolo rm` — stop **and** delete the VM and its rootfs.

> **Heads up (matchlock):** matchlock does not currently support "resume
> from stopped". After `yolo stop`, the next `yolo` builds a fresh VM
> from the OCI image and re-runs the provisioner. The **podman** backend
> behaves differently — `yolo stop` preserves the container and the next
> `yolo` resumes it instantly. See [Backends](./09-backends.md).

## 1.5 Where to go next

- Run more than one VM at a time, or use `yolo` for one-off commands:
  see [Daily usage](./02-usage.md).
- Change the base image, give the VM more memory, pin a Go version, etc.:
  see [Configuration](./03-configuration.md).
- Set up custom tooling for a project that's not Go/Rust/Ruby/Android:
  see [Provisioners](./04-provisioners.md) and the
  [Yolofile reference](./05-yolofile.md).
- Run containers instead of microVMs, or graphical apps: see
  [Backends](./09-backends.md).
