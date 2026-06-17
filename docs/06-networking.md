# 6. Networking

`yolo` exposes two networking modes from matchlock. Pick the one that
matches what you trust the VM with.

## 6.1 Default: plain NAT (recommended)

Out of the box, `yolo` starts VMs **without** matchlock's
`--allow-host` flag. The guest gets working outbound TCP/UDP with real
upstream TLS certificates. Everything you'd expect to work just works:

```bash
yolo -- dnf install -y git          # works
yolo -- curl https://example.com    # real cert, no warnings
yolo -- go install golang.org/x/tools/gopls@latest
yolo -- git clone https://github.com/foo/bar
```

There is **no host-level egress filtering** in this mode — the VM
reaches the same internet as your host.

## 6.2 Restricted egress: `YOLO_ALLOW`

To restrict the guest's outbound traffic to a specific allow-list of
hosts:

```bash
YOLO_ALLOW="github.com,registry.fedoraproject.org" yolo
```

Setting `YOLO_ALLOW` switches matchlock into its **MITM allow-list
mode**. Internally, matchlock:

- intercepts every outbound TLS connection,
- terminates it with an ephemeral per-VM certificate authority,
- checks the SNI against your allow-list,
- and re-originates the connection to the real upstream.

That gives you policy enforcement (matchlock can deny connections to
non-listed hosts) and observability (matchlock can log the actual SNI),
but it breaks the TLS chain inside the guest.

## 6.3 Why TLS breaks in MITM mode

When `YOLO_ALLOW` is set, matchlock presents its **ephemeral per-VM CA
certificate** to the guest, and `yolo` **does not install that CA into
the guest's trust store**. (See
[matchlock#2](https://github.com/jingkaihe/matchlock/issues/2).)

Concretely:

```bash
YOLO_ALLOW="example.com" yolo -- curl https://example.com
# curl: (60) SSL certificate problem: unable to get local issuer certificate
```

`dnf install`, `git clone https://…`, `go install`, `pip install`, and
anything else that does HTTPS will fail with verification errors.

Workarounds, in order of preference:

1. **Bake the CA into a custom base image.** If you're going to use
   MITM mode regularly, build an OCI image where matchlock's CA is
   trusted at the system level, and set `YOLO_IMAGE=` to point at it.
2. **Use HTTP-only mirrors.** Some package mirrors offer plain HTTP. The
   MITM proxy doesn't break those.
3. **Disable TLS verification per tool.** `curl --insecure`,
   `GIT_SSL_NO_VERIFY=1`, `pip --trusted-host`, and so on. Acceptable
   for throwaway experiments, **not** for any real work.

## 6.4 When to use which mode

| Goal                                                  | Mode                |
| ----------------------------------------------------- | ------------------- |
| Day-to-day development                                | Default (NAT)       |
| Throwaway untrusted code, restricted egress required  | `YOLO_ALLOW=…` with a custom CA-baked image |
| HTTP-only workloads on locked-down networks           | `YOLO_ALLOW=…` (TLS issues don't apply) |

If you're not certain you need the allow-list policy, don't set
`YOLO_ALLOW`. The default mode is what almost every user wants.

## 6.5 Common symptoms

| Symptom                                          | Likely cause                                       |
| ------------------------------------------------ | -------------------------------------------------- |
| `unable to get local issuer certificate`         | MITM mode, CA not installed in guest               |
| `curl: (35) … alert unknown ca`                  | MITM mode, CA not installed in guest               |
| `Network is unreachable`                         | matchlock host networking not set up — see Troubleshooting |
| Specific host fails, others work, MITM enabled   | Host is not in `YOLO_ALLOW`                        |

See [Troubleshooting](./08-troubleshooting.md) for more.

## 6.7 Publishing guest ports to the host

The two modes above are about **outbound** traffic. To reach a service
running **inside** the VM from your host — a dev web server, an API, a
database — publish its port.

Publish with `--publish` (alias `-p`), repeatable:

```bash
# guest service on :8080, reachable on the host at 127.0.0.1:8080
yolo --publish 8080 -- python3 -m http.server 8080 --bind 0.0.0.0

# remap: host 8080 -> guest 80, plus expose postgres
yolo --publish 8080:80 --publish 5432:5432
```

…or declare it once per project in a [Yolofile](./05-yolofile.md#publish)'s
front matter (comma-separated, since front matter has no lists):

```bash
---
publish: 8080:80, 5432:5432
---
#!/usr/bin/env bash
set -euo pipefail
dnf -q install nginx postgresql-server
```

Then from the host:

```bash
curl http://127.0.0.1:8080
```

Both backends (matchlock and podman) support publishing. Key points:

- **Spec format is `[HOST_PORT:]GUEST_PORT`.** A bare `PORT` means
  `PORT:PORT`, so the host port is deterministic.
- **Ports bind to `127.0.0.1`** (loopback) on the host — the service is
  reachable from the host machine, not from the LAN. yolo intentionally
  does not expose published ports on `0.0.0.0`.
- **The guest service must listen on `0.0.0.0`**, not `127.0.0.1`.
  A server bound to the guest's loopback can't be reached through the
  forward.
- **Publishing is fixed at VM creation**, like `cpus` / `memory` /
  `disk-size`. To change the published ports of an existing VM,
  `yolo rm` then re-attach. On matchlock, a `yolo stop` + reattach
  recreates the VM and re-applies the current `--publish` / `publish:`
  set anyway.
- A CLI `--publish` flag **replaces** any Yolofile `publish:` set for that
  run (replace, not merge — matching the other resource overrides).
