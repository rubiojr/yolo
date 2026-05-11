# yolo

> Fast, persistent, per-directory [matchlock][matchlock] microVMs with one-shot
> provisioning. Written in [rugo][rugo].

[matchlock]: https://github.com/jingkaihe/matchlock
[rugo]: https://github.com/rubiojr/rugo

`yolo` wraps `matchlock` so you can drop into an isolated Fedora microVM for
the current directory with a single keystroke. The VM persists across
invocations, the directory you started in is live-mounted as `/work`, and a
provisioner installs your toolchain the first time you attach. Re-running
`yolo` is sub-second after the first time.

```
~/code/my-project
❯ yolo
[yolo] starting fedora:44 VM cwd-7259073de3 for /home/rubiojr/code/my-project
[yolo] rendering provisioner fedora-go
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

## Why

[matchlock][matchlock] is a great primitive — Firecracker microVMs you can
spin up from any OCI image, with vsock-based exec, FUSE-mounted workspaces,
and per-VM network policy. But out of the box you manage every VM by hand
(`matchlock run -d` → copy the `vm-xxxxxxxx` ID → `matchlock exec vm-…`).

`yolo` adds:

- **Per-directory persistence** — each `$PWD` gets its own long-lived VM,
  keyed by a sha1 of the path. Re-running `yolo` reattaches in <1s.
- **Auto-heal** — if the VM was stopped or removed (host reboot, manual
  `matchlock rm`, etc.), `yolo` notices and recreates it transparently.
- **One-shot provisioning** — bash provisioners are compiled into the
  binary, rendered on first attach, idempotently skipped thereafter, and
  invalidated automatically when the VM is recreated.
- **Naming** — matchlock has no `--name` of its own; `yolo` maintains a
  name → vm-id map in `$XDG_RUNTIME_DIR/yolo/`.
- **Working directory in the VM** — `$PWD` is mounted as `/work` (live
  read-write) and your shell lands there.
- **No-fuss network defaults** — plain NAT by default (so `dnf install`,
  `curl https://…`, `go install` etc. just work). Opt into matchlock's MITM
  allow-list policy with `YOLO_ALLOW=…`.

## Requirements

- Linux with KVM (`/dev/kvm` readable and writable)
- [`matchlock`][matchlock-install] in `PATH`
- [`rugo`][rugo-install] to run/build the script

[matchlock-install]: https://github.com/jingkaihe/matchlock#install
[rugo-install]: https://github.com/rubiojr/rugo#install

## Install

```bash
# Run from source
rugo run yolo.rugo …

# Or build a single static binary
rugo build yolo.rugo
install -m 0755 yolo ~/.local/bin/yolo
```

## Usage

```
yolo                            Ensure VM, auto-provision (once), shell in.
yolo -- CMD ARGS...             Run CMD inside the VM.
yolo --provisioner NAME [...]   Use a different provisioner (default: fedora-go).
yolo --no-provision [...]       Skip auto-provisioning.
yolo -n NAME [...]              Use a named VM instead of the per-CWD one.

yolo ls                         List tracked VMs with live status.
yolo status [-n NAME]           Print state + vm-id + applied provisioners.
yolo id     [-n NAME]           Print the vm-id (scriptable).
yolo logs   [-n NAME]           Tail the VM's serial log.

yolo stop   [-n NAME]           Stop the VM (preserves state).
yolo rm     [-n NAME]           Stop + remove the VM and its name binding.
yolo prune                      Drop name bindings whose VM is gone.

yolo provision [--provisioner NAME] [-n NAME]
                                Force re-apply a provisioner (idempotent).
yolo provisioners               List embedded provisioners.
```

### Common flows

```bash
# Drop into a fresh fedora:44 VM with Go installed and your CWD mounted
yolo

# Run one command without an interactive shell
yolo -- go test ./...

# Use a different image
YOLO_IMAGE=registry.fedoraproject.org/fedora:41 yolo

# Open a separate persistent VM under a name
yolo -n api
yolo -n web

# Tear it down when done
yolo stop          # stops, state preserved
yolo rm            # nukes the VM and removes the name binding
```

## Configuration (env vars)

| Var               | Default        | Effect |
| ----------------- | -------------- | ------ |
| `YOLO_IMAGE`      | `fedora:44`    | OCI image to use (any matchlock-supported reference) |
| `YOLO_CPUS`       | `2`            | vCPU count (matchlock's stock default is 1) |
| `YOLO_MEM_MB`     | `2048`         | Guest memory in MiB (matchlock's stock default is 512) |
| `YOLO_DISK_MB`    | `16384`        | Guest rootfs disk in MiB (16 GiB). **Matchlock's stock default is 5120 MiB which fills up during a Go-toolchain provision.** Lower it for cheap one-offs, raise it for heavier workloads. |
| `YOLO_WORKSPACE`  | `/work`        | Guest mount point for `$PWD` |
| `YOLO_NAME`       | `cwd-<sha1>`   | Override the auto-derived name |
| `YOLO_USER`       | unset          | Pass `--user uid:gid` to matchlock for non-root execution |
| `YOLO_ALLOW`      | unset (no MITM)| Comma list of allow-listed hosts. **Setting this enables matchlock's MITM proxy, which breaks TLS verification inside the guest** (matchlock generates an ephemeral per-VM CA and does not inject it into the guest's trust store). Useful only when you bake a custom image whose tools don't verify certs, or for HTTP-only flows. |
| `YOLO_GO_VERSION` | _latest_       | Pin the Go version in the `fedora-go` provisioner. By default the provisioner resolves `https://go.dev/VERSION?m=text`. |
| `XDG_RUNTIME_DIR` | `/tmp`         | Where `yolo` keeps its name → vm-id state files. |

### Sizing notes

- The `fedora-go` provisioner needs **~10 GiB** of disk at peak: ~600 MB for
  the dnf base, ~200 MB for the Go tarball, plus build caches for `gopls`,
  `golangci-lint`, `dlv`, etc. The 16 GiB default leaves comfortable headroom.
- Bumping memory above 2 GiB mostly helps `go install` of larger projects.
- For a tighter footprint, e.g. ephemeral one-shot runs: `YOLO_DISK_MB=4096
  YOLO_MEM_MB=512 yolo --no-provision -- script.sh`.

## State files

`yolo` keeps a tiny per-name state in `$XDG_RUNTIME_DIR/yolo/`:

```
<name>.vmid     # the matchlock vm-id currently bound to this name
<name>.applied  # vm-id + list of provisioners already applied to it
```

The `.applied` marker contains the vm-id on the first line and applied
provisioner names on subsequent lines, e.g.:

```
vm-b1e68449
fedora-go
```

When the VM is recreated under a new vm-id (auto-heal), the marker is
implicitly invalidated and the provisioner re-runs.

## Provisioners

Provisioners live in [`provisioners/`](./provisioners) as rugo source files,
embedded into the binary at compile time via rugo's `embed` directive.

A provisioner is a **rugo script-generator**: it runs on the host, uses
rugo's string interpolation to template a bash script tailored to host
architecture, and prints that script on stdout. `yolo` captures the output
and pipes it into the VM via `matchlock exec <vm> -i -u root -- bash`,
streaming the output to your terminal.

### Built-in provisioners

| Name        | What it installs |
| ----------- | ---------------- |
| `fedora-go` | Upstream Go (latest from go.dev, or `$YOLO_GO_VERSION`), plus `gopls`, `staticcheck`, `dlv`, `goimports`, `gofumpt`, `golangci-lint`. Targets Fedora-based images. |

```bash
yolo provisioners
# Available provisioners (default: fedora-go):
# * fedora-go
```

### Adding a new provisioner

1. Drop a file at `provisioners/provisioner-<name>.rugo`:

   ```ruby
   # provisioners/provisioner-fedora-node.rugo
   use "os"
   node_ver = os.getenv("YOLO_NODE_VERSION")
   if node_ver == ""
     node_ver = "22"
   end
   script = <<~BASH
     set -euo pipefail
     dnf -y install nodejs#{node_ver} npm
     corepack enable
     echo "node $(node --version), pnpm $(pnpm --version)"
   BASH
   puts script
   ```

2. Register it in `yolo.rugo`:

   ```ruby
   embed "provisioners/provisioner-fedora-node.rugo" as prov_fedora_node
   PROVISIONERS = {
     "fedora-go"   => prov_fedora_go,
     "fedora-node" => prov_fedora_node
   }
   ```

3. Rebuild: `rugo build yolo.rugo`. The script is now baked into the binary.

### Testing a provisioner without a VM

Provisioners are plain rugo programs — run one on the host to inspect the
bash it would emit:

```bash
rugo run provisioners/provisioner-fedora-go.rugo | less
```

## Networking

By default, `yolo` starts VMs **without** matchlock's `--allow-host` flag,
which leaves matchlock in plain-NAT mode. The guest gets working outbound
TCP/UDP with real upstream TLS certs — `dnf install`, `curl https://…`,
`go install …`, `git clone https://github.com/…` all work normally.

Setting `YOLO_ALLOW="…"` switches matchlock into its MITM interception
mode, restricts egress to the listed hosts, and replaces every TLS cert
chain with matchlock's ephemeral per-VM CA. **The guest does not trust
this CA** (matchlock currently does not inject it into the guest's trust
store, see [matchlock#2][matchlock-2]). So most HTTPS tools will break
unless you build an image with the CA pre-installed or use `--insecure`
flags.

[matchlock-2]: https://github.com/jingkaihe/matchlock/issues/2

## How auto-heal works

`yolo`'s state file points at a `vm-xxxxxxxx`. Before every action `yolo`:

1. Reads the stored vm-id.
2. Calls `matchlock list` and looks up the row.
3. If status is `running` → reuse.
4. If status is `stopped`/`failed`/missing → `matchlock kill` + `matchlock
   rm`, drop the state file, start a fresh VM, store the new id.

This makes `yolo` idempotent: invoking it after a host reboot,
`matchlock prune`, or a manual `matchlock rm` does the right thing without
arguments.

## Working with multiple VMs

```bash
yolo                       # this directory's VM
yolo -n notes              # named VM 'notes'
yolo -n notes -- vi list   # one-off in 'notes'
yolo ls
# NAME                       VM-ID                 STATUS        IMAGE
# cwd-7259073de3             vm-b1e68449           running       fedora:44
# notes                      vm-4c9a02f1           running       fedora:44
yolo -n notes stop
yolo prune                 # drop stale bindings whose VMs are gone
```

## Caveats and gotchas

- **VM filesystem is ephemeral** — anything you `dnf install` lives only as
  long as the VM does. Persistent dev tooling should live in your `$PWD`
  (mounted at `/work`) or in a custom OCI image.
- **`yolo stop` is destructive for non-mounted state** — matchlock has no
  `restart` for stopped VMs, so `yolo stop` followed by `yolo` will recreate
  the VM from scratch (and re-run the provisioner). Use it deliberately.
- **First boot pulls the OCI image** — `fedora:44` is ~150 MB. Subsequent
  starts are sub-second once matchlock has cached the rootfs (`matchlock
  image ls`).
- **rugo is alpha** — the language is fun and productive but pre-1.0. See
  [`rugo-quirks.md`](./rugo-quirks.md) for issues encountered while writing
  `yolo`.

## Project layout

```
yolo.rugo                                   # the CLI
provisioners/
  provisioner-fedora-go.rugo                # default provisioner
rugo-quirks.md                              # notes for the rugo author
README.md                                   # this file
```

## License

MIT.
