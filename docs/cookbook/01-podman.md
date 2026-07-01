# Cookbook: Podman on the matchlock backend

Run Podman inside a `yolo` [matchlock](../09-backends.md) microVM. matchlock
gives the guest its own kernel and real root, so a container engine runs
cleanly there (the container backends can't host one).

The only thing Podman needs is matchlock's **privileged mode**, which you turn
on with one line in the Yolofile. yolo handles the rest (it boots a
container-ready guest kernel for you).

**Requirements:** yolo **v0.10.0+**, matchlock healthy (`matchlock diagnose`).

## 1. Yolofile

```bash
---
backend: matchlock
privileged: true
image: fedora:44
cpus: 2
disk_mb: 8192
---
#!/usr/bin/env bash
set -euo pipefail

# fuse-overlayfs is required: matchlock's rootfs is itself an overlay,
# so Podman's overlay driver has to stack on fuse-overlayfs.
dnf install -y --setopt=install_weak_deps=False podman fuse-overlayfs

install -d /etc/containers
cat > /etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
```

`privileged: true` is the key line: it runs the VM privileged (so it can host a
container engine) and boots a container-ready guest kernel, **downloaded once**
(a few MB, cached under `~/.cache/yolo/kernels/`) and reused after. Setting it
on any other backend is an error.

> Prefer flags/env? `yolo --matchlock-privileged` or
> `YOLO_MATCHLOCK_PRIVILEGED=1` do the same without touching the Yolofile, and
> `yolo --matchlock-kernel file:///abs/path` boots a kernel you built yourself.

## 2. Use Podman

The first `yolo` in that directory boots and provisions the VM; after that
Podman is ready.

```bash
# run a container
yolo -- podman run --rm docker.io/library/alpine:latest echo "hello from a container"

# reach the internet from inside a container
yolo -- podman run --rm docker.io/library/alpine:latest wget -qO- https://example.com
```

Custom networks and container-to-container DNS work too:

```bash
yolo -- bash -lc '
  podman network exists demo || podman network create demo
  podman run -d --name svc --network demo docker.io/library/alpine:latest \
    sh -c "while true; do printf \"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nhi\n\" | nc -lp 8000; done"
  sleep 2
  podman run --rm --network demo docker.io/library/alpine:latest wget -qO- http://svc:8000/
  podman rm -f svc
'
```

Or open a shell and use Podman interactively: run `yolo`, then `podman …`.

## Publishing a port to the host

Add a `publish:` line to the Yolofile, then run the server with
**`--network=host`** in the **foreground**:

```bash
# in the Yolofile front matter:  publish: 8080:80   (host :8080 -> guest :80)

# terminal 1 — server stays in the foreground
yolo -- podman run --rm --network=host docker.io/library/nginx:alpine

# terminal 2
curl http://127.0.0.1:8080
```

- Use `--network=host`, **not** `-p` — matchlock forwards to the guest's
  loopback, which `-p` doesn't reliably reach.
- Match the container's port to the **guest** side of `publish:` (nginx serves
  `:80`, so `publish: 8080:80`).
- The port is open only while the server runs.

## Troubleshooting

`privileged:` and the matchlock settings apply at VM **creation** — after
changing them, `yolo rm` and re-attach.

| Symptom | Fix |
| --- | --- |
| `privileged mode requires the matchlock backend` | You set `privileged:` (or `--matchlock-privileged`) but the backend isn't matchlock. Add `backend: matchlock` (or `--backend matchlock`). |
| `cannot set user namespace` / `netavark: nftables error` | The VM isn't privileged — make sure `privileged: true` took effect (`yolo rm` and re-attach after adding it). |
| `'overlay' is not supported over overlayfs` | The `storage.conf` (fuse-overlayfs) step didn't run. |
| Kernel download fails | Check your connection. To bypass it, build a kernel with `scripts/build-kernels.sh` and set `--matchlock-kernel file:///abs/path`. |

## Notes

- matchlock doesn't preserve state across `yolo stop` — a stopped VM is rebuilt
  and re-provisioned on the next attach, so Podman is reinstalled each time.
- Podman's image store lives on fuse-overlayfs here. For faster, persistent
  storage, attach a dedicated disk with `YOLO_MATCHLOCK_DISK` (see
  [Backends](../09-backends.md)).
- **Docker** works too but needs extra setup; see matchlock's
  [`docker-in-sandbox` example](https://github.com/jingkaihe/matchlock/tree/main/examples/docker-in-sandbox).
