# 8. Troubleshooting

When `yolo` goes sideways, the issue is almost always in one of three
layers: the host (KVM, matchlock), `yolo`'s state files, or a
provisioner script. This chapter is organized that way.

## 8.1 Host setup

### `yolo: cannot open /dev/kvm` / `permission denied`

Your user can't access KVM.

```bash
ls -l /dev/kvm
# crw-rw---- 1 root kvm ... /dev/kvm

# Add yourself to the kvm group, then log out and back in:
sudo usermod -aG kvm "$USER"
```

On WSL2, install a kernel with KVM enabled or run on bare Linux —
matchlock can't run nested under most cloud VMs either.

### `yolo: matchlock: command not found`

`yolo` does not bundle `matchlock`. Install it from
[matchlock's release page][matchlock-install] and ensure it's on your
`PATH`:

```bash
which matchlock && matchlock --version
```

[matchlock-install]: https://github.com/jingkaihe/matchlock#install

### Using the podman backend instead

The `/dev/kvm` and `matchlock` requirements above apply only to the
default matchlock backend. If you can't (or don't want to) use KVM, run
with the podman backend — it needs only `podman` on your `PATH`:

```bash
which podman && podman --version
YOLO_BACKEND=podman yolo            # or: yolo --backend podman
```

See [Backends](./09-backends.md) for the capability differences.

### `Network is unreachable` inside the VM

matchlock's host networking (bridge/TAP setup) didn't initialize
correctly. Check matchlock's docs for required `sysctl`s and module
loads (typically `tun`, `kvm_intel` or `kvm_amd`). Restart matchlock's
daemon if you run one.

## 8.2 VM lifecycle

### "It says the VM is running but I can't attach"

Inspect what `yolo` thinks vs. what `matchlock` thinks:

```bash
yolo status
matchlock list
```

If `yolo` shows a vm-id that `matchlock list` doesn't, the bookkeeping
is stale:

```bash
yolo prune          # drops dead bindings
```

The next `yolo` will then auto-heal and recreate a fresh VM. See
[architecture.md § Auto-heal](./architecture.md#1-auto-heal) for what
that algorithm checks.

### `yolo stop` followed by `yolo` rebuilt the VM from scratch

Expected behaviour. matchlock has no `restart` for stopped VMs — `yolo`
treats stopped as "gone" and creates a new one (which re-runs the
provisioner). Use `yolo stop` deliberately, not as a "pause" button.

### "I removed a VM with `matchlock rm` directly. Now what?"

Either run `yolo prune` (drops the stale binding) or just `yolo` (it
will notice the VM is gone and auto-heal).

### Processes from one `yolo` shell aren't visible in another

Each `yolo` attach (and each `yolo -- CMD`) is a separate
[`matchlock exec`][matchlock-exec] invocation. `matchlock exec` runs
your command inside the VM under a fresh PID namespace and a private
`/proc` mount, so sibling sessions can't see each other's processes
via `ps`, `top`, `pgrep`, `kill`, or `/proc/<pid>` — even when both run
as `root`. This is deliberate sandboxing in matchlock; it's not a yolo
limitation and there's no yolo flag to disable it.

The VM filesystem itself **is** shared across sessions — the workspace
(`/work`), `$HOME`, and the rest of the guest disk are the same
underlying storage. Files written in one session are immediately
visible from another; only the *process view* is isolated.

If you need long-running processes that survive a session and remain
reachable from later attaches, run them under a supervisor inside the
guest (for example a `systemd` user unit) and let each `yolo` shell
talk to that supervisor.

[matchlock-exec]: https://github.com/jingkaihe/matchlock

### Disk filling up

```bash
yolo du
```

VM rootfs disks are sparse on the host but grow as the guest writes.
Common culprits: a stuck `dnf` cache, large build artifacts under
`/root`, an interrupted `go install` leaving partials. Drop into the VM
and clean up, or `yolo rm` and rebuild.

## 8.3 Provisioning

### Provisioner fails halfway through

The script ran as `root` with your stdio attached, so the error is on
your screen. After investigating, either:

- Fix the script and re-run: `yolo provision` (forces re-apply), or
- Drop the VM and try fresh: `yolo rm && yolo`.

### "I edited my Yolofile but `yolo` didn't re-provision"

`yolo` only re-runs the Yolofile when its **body** hash changes. Editing
front matter (image, cpus, memory, disk-size) is intentionally
non-triggering — those fields apply only at VM creation. To pick them
up:

```bash
yolo rm
yolo
```

See [Yolofile reference § Re-provisioning](./05-yolofile.md#re-provisioning).

### Force a re-provision regardless

```bash
yolo provision                         # use the resolved provisioner
yolo provision --provisioner fedora-go # specific one
```

Idempotent — safe to repeat.

## 8.4 Networking and TLS

### `unable to get local issuer certificate` / `unknown ca`

You have `YOLO_ALLOW` set, so matchlock is in MITM mode and the guest
doesn't trust matchlock's ephemeral CA. See
[Networking § Why TLS breaks](./06-networking.md#63-why-tls-breaks-in-mitm-mode).

Quickest fix: unset `YOLO_ALLOW` for normal use.

### `Could not resolve host: …` for an allowed host

The host is allow-listed but DNS in the guest is broken. Check
`/etc/resolv.conf` inside the VM and verify upstream resolvers are
reachable.

## 8.5 State and recovery

`yolo`'s state lives in `$XDG_RUNTIME_DIR/yolo/` (typically
`/run/user/$UID/yolo/`, falling back to `/tmp/yolo/` if `XDG_RUNTIME_DIR`
is unset):

```
<name>.vmid     # the matchlock vm-id currently bound to this name
<name>.applied  # vm-id + list of provisioners already applied to it
```

Full layout and semantics are in
[architecture.md § State files](./architecture.md#2-state-files).

To nuke `yolo`'s view of the world without touching matchlock:

```bash
rm -rf "${XDG_RUNTIME_DIR:-/tmp}/yolo"
```

The next `yolo` will create a fresh VM (matchlock-side VMs you didn't
remove will leak — list them with `matchlock list` and clean up by
hand).

To nuke everything for a clean slate, list every named VM and remove
it, then drop the local state:

```bash
yolo ls                                  # note each NAME in the first column
yolo rm -n NAME                          # repeat for each one
rm -rf "${XDG_RUNTIME_DIR:-/tmp}/yolo"
```

## 8.6 Getting help

If none of the above applies, collect:

```bash
yolo --version
matchlock --version
uname -a
yolo status
yolo logs | tail -200
```

…and open an issue at <https://github.com/rubiojr/yolo>.
