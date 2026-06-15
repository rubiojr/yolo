# 2. Daily usage

Everyday workflows with `yolo`. The CLI reference is at the end of this
chapter; the walkthroughs come first.

## 2.1 The default flow: a VM per directory

`yolo` (no arguments) is what you use 95% of the time. It:

- ensures a VM exists for `$PWD` (creates it if missing, auto-heals if
  it disappeared),
- runs any applicable provisioner the **first** time it sees this VM,
- drops you into an interactive `bash` shell inside the guest with
  `/work` set to your current directory.

```bash
cd ~/code/my-project
yolo                              # interactive shell in the project's VM
```

Re-running `yolo` in the same directory reattaches to the same VM in
under a second.

## 2.2 One-shot commands

To run a single command instead of an interactive shell, put it after
`--`:

```bash
yolo -- go test ./...
yolo -- bash -c 'go build && ./myapp --selftest'
```

The command's stdout/stderr stream back to your terminal. The exit code
of the command is propagated to `yolo`'s exit code, so this composes
cleanly with shell pipelines and CI.

## 2.3 Multiple persistent VMs

Sometimes one VM per directory isn't what you want — maybe you need a
VM for ad-hoc work, or two VMs side by side that share the same source
tree. Use `-n NAME` to give a VM an explicit name:

```bash
yolo -n notes                     # interactive shell in VM "notes"
yolo -n api                       # a separate VM "api"
yolo -n notes -- vi todo.md       # one-off in "notes"
```

`-n` overrides the auto-derived per-directory name. The named VM lives
until you explicitly `yolo -n NAME rm` it.

List everything `yolo` is tracking:

```
❯ yolo ls
NAME                       VM-ID                 STATUS        IMAGE
cwd-7259073de3             vm-b1e68449           running       fedora:44
notes                      vm-4c9a02f1           running       fedora:44
api                        vm-8d3f2a90           stopped       fedora:44
```

See disk consumption:

```
❯ yolo du
NAME                       VM-ID                 STATUS      USED          ALLOCATED
cwd-7259073de3             vm-b1e68449           running     4.2 GiB       32 GiB
notes                      vm-4c9a02f1           running     612 MiB       32 GiB
TOTAL                                                        4.8 GiB       64 GiB
```

## 2.4 Auto-heal

`yolo` is idempotent: if the VM behind a name has been removed by a host
reboot, a `matchlock rm`, or anything else, the next `yolo` invocation
notices and silently rebuilds. You should never need to manually
`matchlock kill && matchlock rm` to recover.

For a deeper look at the algorithm, see
[architecture.md § Auto-heal](./architecture.md#1-auto-heal).

## 2.5 Cleaning up

```bash
yolo stop                         # stop, preserve state on disk
yolo rm                           # stop + delete VM and its rootfs
yolo -n notes rm                  # remove a specific named VM
yolo prune                        # drop name bindings whose VMs are gone
```

`yolo prune` is the "garbage collect" command — it removes stale local
bookkeeping for VMs that `matchlock` no longer knows about. Safe to run
at any time.

## 2.6 Inspecting a VM

```bash
yolo status                       # state + vm-id + applied provisioners
yolo id                           # just the vm-id (scriptable)
yolo logs                         # the VM's serial console log
```

All three accept `-n NAME` to target a non-default VM.

## 2.7 CLI reference

```
yolo                            Ensure VM, auto-provision (once), shell in.
yolo -- CMD ARGS...             Run CMD inside the VM.
yolo --provisioner NAME [...]   Use a specific provisioner (overrides Yolofile).
yolo --yolofile PATH|URL [...]  Use a Yolofile from a local path or https URL.
yolo --ephemeral [...]          Use a throwaway VM and empty temp workspace.
yolo --no-provision [...]       Skip auto-provisioning (alias: --no-provisioner).
yolo --ai-agent [NAME] [...]    Also install an AI agent (default: opencode).
                                Known agents: copilot, opencode.
yolo -n NAME [...]              Use a named VM instead of the per-CWD one.
yolo --disk-size SIZE [...]     Override rootfs disk size for this run.
                                Accepts 32G, 32g, 512M, 512m, or a bare MiB
                                integer. Takes effect when the VM is first
                                created.

yolo ls                         List tracked VMs with live status.
yolo du                         List tracked VMs with disk usage.
yolo status [-n NAME]           Print state + vm-id + applied provisioners.
yolo id     [-n NAME]           Print the vm-id (scriptable).
yolo logs   [-n NAME]           Tail the VM's serial log.

yolo stop   [-n NAME]           Stop the VM (preserves state).
yolo rm     [-n NAME]           Stop + remove the VM and its name binding.
yolo prune                      Drop name bindings whose VM is gone.

yolo provision [--provisioner NAME] [-n NAME]
                                Force re-apply a provisioner (idempotent).
yolo provisioners               List embedded provisioners and detected Yolofile.

yolo export [-n NAME] [-o FILE] Snapshot the VM's current rootfs and yolo
                                state into a single .tar.gz bundle.
yolo import FILE [-n NAME] [--force]
                                Import a bundle on another host; see
                                docs/07-export-import.md.
```

`yolo --help` prints the same list with environment-variable defaults
appended.
