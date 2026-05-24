# Backend interface

Every backend lives at `backends/<name>.rugo` and exposes a single public
factory:

```ruby
def make()
  # returns a backend handle: a hash whose keys are the methods/constants
  # below. yolo.rugo builds a registry at startup and dispatches all
  # backend-specific operations through this handle.
end
```

The handle is a plain hash with closure-valued keys (rugo's "record"
pattern — see the rugo-native-module-writer skill). Consumers call methods
via dot-access: `be = matchlock.make(); be.start(opts)`.

## Constants

| Key                  | Type   | Required | Notes                                                                 |
| -------------------- | ------ | -------- | --------------------------------------------------------------------- |
| `NAME`               | string | yes      | `"matchlock"`, `"podman"`, …                                          |
| `SUPPORTS_GUI`       | bool   | yes      | true when the backend wires up a display server into the guest        |
| `SUPPORTS_EXPORT`    | bool   | yes      | true when `export_archive` / `import_archive` are implemented         |
| `PERSISTS_ON_STOP`   | bool   | yes      | true when `stop()` preserves in-guest state across the next `start()` |
| `DEFAULT_IMAGE`      | string | yes      | OCI ref used when no per-VM image is configured                       |

## Lifecycle

```
be.list_table()                 -> {id => [status, image]}
be.start(opts)                  -> id          # creates + boots; returns opaque id
be.stop(id)                     -> ()          # PERSISTS_ON_STOP backends preserve state
be.resume(id)                   -> ()          # only called when PERSISTS_ON_STOP=true
                                                # and the container is in a non-running
                                                # state. matchlock implements as a no-op.
be.remove(id)                   -> ()          # destructive; safe to call on already-gone
be.wait_ready(id)               -> ()          # blocks until exec channel is usable
be.logs(id, extra)              -> ()          # streams VM/container log to the user's terminal
```

`opts` (passed to `start`) is a hash with:

- `name`       — yolo's per-name binding (used for hostname/container name)
- `image`      — OCI image ref
- `cpus`       — string, integer count
- `mem_mb`     — string, MiB
- `disk_mb`    — string, MiB (advisory; backends without disk limits may ignore)
- `workspace`  — guest path where the host `cwd` is mounted
- `cwd`        — host absolute path to mount at `workspace`
- `user`       — `"uid:gid"` or `""`
- `allow`      — egress allow-list (matchlock-only meaning; podman ignores)
- `gui`        — bool; when true, backend must wire a display server. Only
                 honoured when `SUPPORTS_GUI` is true; yolo refuses earlier
                 otherwise.

## Exec channels

```
be.exec_provision(id, src, workspace)        # pipe `src` (bash) as root, blocks until done
be.exec_shell(id, workspace, tty)            # interactive bash login shell
be.exec_argv(id, workspace, tty, argv)       # passthrough argv
```

`tty` is `"-it"` when a controlling TTY is available, `"-i"` otherwise (same
convention docker/podman use). Backends that don't speak the `-it` syntax
should interpret it semantically.

## Storage accounting

```
be.disk_apparent(id)            -> int (bytes, -1 if unknown)
be.disk_real(id)                -> int (bytes, -1 if unknown)
```

Used by `yolo du`. Return `-1` when the backend can't introspect on-disk size.

## Image registry

```
be.image_remove(tag)            -> ()          # no-op when SUPPORTS_EXPORT is false
```

## Export / import (optional)

When `SUPPORTS_EXPORT` is true:

```
be.export_archive(opts)         -> ()
be.import_archive(opts)         -> tag   # returns the locally-pinned image tag
```

`yolo` calls these only when the backend's flag is true; otherwise it errors
out with a friendly message at the CLI layer.

## Stateless backends

Backends MUST be stateless across calls. All per-name state (vm-id,
`.applied`, `.image`, `.cwd`, `.backend`) lives in `$XDG_RUNTIME_DIR/yolo/`
and is managed by `yolo.rugo`. Backends only ever interact with the
underlying runtime (matchlock CLI, podman CLI, …).
