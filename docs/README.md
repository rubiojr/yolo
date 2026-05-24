# yolo documentation

A chapter-by-chapter tour of `yolo`, in reading order.

1. [Getting started](./01-getting-started.md) — install, first run, what
   `yolo` actually does the first time you invoke it.
2. [Daily usage](./02-usage.md) — common flows, one-off commands, named
   VMs, working with several at once, full CLI reference.
3. [Configuration](./03-configuration.md) — environment variables, CLI
   flags, CPU/memory/disk sizing.
4. [Provisioners](./04-provisioners.md) — built-in language provisioners,
   auto-detection from `$PWD`, adding your own, optional AI agents.
5. [Yolofile reference](./05-yolofile.md) — the per-project `Yolofile`
   format: front matter, body, re-provisioning, precedence.
6. [Networking](./06-networking.md) — default NAT behaviour vs.
   `YOLO_ALLOW=` MITM allow-list mode and its TLS caveats.
7. [Export & import](./07-export-import.md) — snapshot a VM's rootfs and
   state, restore it on another host.
8. [Troubleshooting](./08-troubleshooting.md) — KVM permissions, missing
   `matchlock`, broken auto-heal, dangling state, MITM cert errors.
9. [Backends](./09-backends.md) — pick between matchlock (microVM) and
   podman (containers, GUI apps), capability matrix, how the abstraction
   is wired together.

For internals (auto-heal algorithm, state file layout, provisioner
markers, project source layout) see [architecture.md](./architecture.md).
