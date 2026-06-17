---
name: yolo-developer
description: Expert in developing yolo, fast persistent per-directory matchlock/podman dev VMs written in rugo. Load when building, modifying, debugging, or extending the yolo tool itself — its rugo source (yolo.rugo, cli.rugo, yolofile.rugo), backends, provisioners, AI-agent installers, or docs.
---

# yolo Developer Skill

You are developing **yolo** itself: a fast, persistent, per-directory
[matchlock](https://github.com/jingkaihe/matchlock) microVM (and podman
container) manager with one-shot provisioning. It is written in
[rugo](https://github.com/rubiojr/rugo), a Ruby-inspired language that
compiles to a single static Go binary.

Repository: `github.com/rubiojr/yolo`

## CRITICAL

- yolo is written in **rugo**, not Go. **Load the `rugo-quickstart`
  skill** when touching `.rugo` files, and **load the
  `rugo-native-module-writer` skill** when working on the modules
  (`cli.rugo`, `yolofile.rugo`, `backends/*.rugo`).
- Provisioners and backend helpers are **plain bash** scripts that run as
  `root` inside the guest. They are embedded into the binary at build time.
- Security is paramount. Front matter values and image refs flow into
  host-side shell commands; never relax the input allowlists without
  understanding the injection surface. Ask before introducing anything
  that weakens the existing validation.
- The authoritative internals doc is `docs/architecture.md`. The backend
  contract is `backends/INTERFACE.md`. Keep both in sync with code changes.

## What yolo does (one paragraph)

Each `$PWD` gets a long-lived VM keyed by `cwd-<sha1(path)[:10]>`.
Re-running `yolo` reattaches in <1s. yolo auto-heals (recreates a gone
VM), auto-detects a language provisioner from project files, live-mounts
`$PWD` at `/work`, and can snapshot/restore a VM via `export`/`import`.
Two backends exist: **matchlock** (Firecracker microVMs, default) and
**podman** (containers, GUI-capable). The host binary is a single static
rugo artifact; nothing rugo/Go is needed in the guest (provisioners are
bash).

## Source layout

```
yolo.rugo            # the CLI entry point — main logic, subcommands, state mgmt
cli.rugo             # arg parsing, --help, --version, disk-size parsing
yolofile.rugo        # Yolofile location, front-matter parse + validation
backends/
  INTERFACE.md       # the backend contract (READ THIS before backend work)
  matchlock.rugo     # matchlock (Firecracker) backend
  matchlock/
    yolo-export.sh         # matchlock-specific bash helpers, embedded at
    yolo-import-unpack.sh  # build time
    yolo-import-retag.sh
  podman.rugo        # podman (container) backend
provisioners/
  provisioner-fedora-go.sh       # backend-agnostic, run as root in guest
  provisioner-fedora-rust.sh
  provisioner-fedora-ruby.sh
  provisioner-fedora-android.sh
  ai-agents/
    copilot.sh
    opencode.sh
docs/                # chapter-by-chapter user docs + architecture.md
skills/              # agent skills (source of truth), embedded + installed
  yolo-user/SKILL.md       # using yolo
  yolofile-author/SKILL.md # authoring Yolofiles
  yolo-developer/SKILL.md  # developing yolo (this file)
web/                 # the yolo hub — static GitHub Pages site (yolo.rbel.co)
  index.html         # hub UI; fetches hub/index.json + each hub/*/Yolofile
  install.sh         # the `curl … | bash` installer
  hub/
    index.json       # generated manifest: JSON array of slug dirs (do not hand-edit)
    <slug>/Yolofile  # one published, grab-and-go Yolofile per directory
scripts/
  gen-hub-index.sh   # regenerates web/hub/index.json from the slug dirs
Yolofile             # yolo's OWN self-hosting provisioner (Go + rugo); not the reference
rugo-quirks.md       # rugo bugs/workarounds encountered while writing yolo
README.md
```

## Build & run

```bash
# Build the static binary (rugo emits Go and invokes `go build`)
rugo build yolo.rugo                 # -> ./yolo
rugo build yolo.rugo -o yolo-linux-amd64

# Run unbuilt while hacking (compiles + runs in one step)
rugo run yolo.rugo -- go version
rugo run yolo.rugo ls

# Cross-compile: rugo honours GOOS/GOARCH/CGO_ENABLED
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 rugo build yolo.rugo -o yolo-linux-arm64

# Cheapest smoke test (used in CI)
./yolo --help >/dev/null
```

`embed "path" as name` bakes a file into the binary **at compile time**.
Adding or editing any `provisioners/*.sh`, `backends/matchlock/*.sh`, or
AI-agent script therefore requires a **rebuild** before the change takes
effect. (Yolofile bodies are the exception — they're read from disk at
runtime.)

## Rugo module rules that shape this codebase

- A module sees **only what it `require`s** — never the reverse. Modules
  (`cli.rugo`, `yolofile.rugo`, backends) cannot read or mutate
  `yolo.rugo`'s top-level vars. That is why:
  - `cli.parse_args(...)` takes `AI_AGENTS`, `DEFAULT_AI_AGENT`, `VERSION`
    as **parameters**.
  - `yolofile.validate(fm, backends, ai_agents, default_ai_agent)` returns
    a typed overrides hash and `yolo.rugo`'s main block applies the
    precedence merge itself.
- Backends are loaded via `require "backends" with matchlock, podman` and
  each exposes a single `make()` factory returning a **handle** (a hash
  whose values are constants and closures — rugo's "record" pattern; see
  the `rugo-native-module-writer` skill).
- Small pure helpers (`parse_disk_size`, the `[yolo]` log helpers) are
  **intentionally duplicated** across modules rather than shared, to keep
  each module standalone. Match that convention; don't introduce a
  cross-module dependency for a 30-line helper.

## The CLI parser quirk (do not "fix" by switching to cli module)

yolo hand-rolls its parser in `cli.rugo` instead of using rugo's native
`cli` module. The native module mishandles a bare `--` as the **first**
argument (it consumes the `--` but doesn't enter passthrough mode), which
would break the canonical `yolo -- CMD ARGS` form. Full write-up with
repro is in `rugo-quirks.md`. If you extend flag parsing, extend the
hand-written loop in `cli.rugo:parse_args`.

## State & marker model (the heart of yolo)

Per-name state lives in `$XDG_RUNTIME_DIR/yolo/` (fallback `/tmp/yolo/`):

```
<name>.vmid      # opaque backend id bound to this name
<name>.backend   # owning backend (matchlock|podman); missing => matchlock
<name>.applied   # line 1 = vm-id; subsequent lines = applied markers
<name>.cwd       # host cwd recorded at first attach (for `ls` display)
<name>.image     # per-name image pin (set by `yolo import`)
<name>.lock/     # mkdir-based inter-process lock (with pid + label files)
```

**Markers** carry a 12-hex prefix of `sha256(provisioner_source)` so
editing a script invalidates the marker and triggers a re-run:

| Shape                         | Meaning                                            |
| ----------------------------- | -------------------------------------------------- |
| `<name>:<hash12>`             | built-in embedded provisioner (hash at compile time) |
| `yolofile:<hash12>`           | project-local Yolofile **body** (hashed each attach) |
| `ai-agent:<name>:<hash12>`    | AI-agent layer, tracked independently              |

Two invalidation paths: (1) **vm-id change** — auto-heal recreates the VM,
rewrites `.applied` line 1, clears markers; (2) **content-hash change** —
edited source no longer matches the stored marker. Yolofiles hash only the
**body**, never front matter (front matter affects VM creation only).

## Auto-heal (`ensure_vm`)

Before any action needing a running VM: read stored id → resolve backend →
`list_table()` lookup. `running` → reuse. Non-running **and**
`PERSISTS_ON_STOP` (podman) → `resume()`. Non-running **and** not
persistent (matchlock) → `remove()` + fresh `start_vm`. Missing row → drop
id + fresh start. This makes every entry point idempotent after reboots /
manual `matchlock rm` / `podman rm`.

## Locking

`acquire_lock`/`release_lock` use atomic `mkdir` as the primitive, with a
PID-liveness check to reclaim stale locks. Take the lock before any
mutation that could race a concurrent `yolo` for the same name (VM create,
marker write, removal, export/import). Read-only maintenance commands
(`ls`, `du`, `status`, `id`, `logs`, `prune`) do **not** lock. The
interactive shell releases the lock **before** `exec` so other terminals
can attach concurrently.

## Adding a backend

Read `backends/INTERFACE.md` first. Then:

1. Create `backends/<name>.rugo` with a `make()` returning a handle that
   implements every constant (`NAME`, `SUPPORTS_GUI`, `SUPPORTS_EXPORT`,
   `PERSISTS_ON_STOP`, `DEFAULT_IMAGE`) and method (`start`, `stop`,
   `resume`, `remove`, `wait_ready`, `list_table`, `logs`,
   `exec_provision`, `exec_shell`, `exec_argv`, `disk_apparent`,
   `disk_real`, `image_remove`, plus the export trio when
   `SUPPORTS_EXPORT`).
2. Backends MUST be **stateless** — all per-name state is owned by
   `yolo.rugo`. A backend only talks to its runtime CLI.
3. Register it: add to the `require "backends" with …` line and the
   `BACKENDS` hash in `yolo.rugo`.
4. Update `docs/09-backends.md` capability matrix and `INTERFACE.md` if the
   contract changed.

## Adding a built-in provisioner

1. Drop `provisioners/provisioner-<name>.sh` (plain bash, `set -euo
   pipefail`, idempotent, Fedora `dnf`-based, runs as root, no implicit
   `set -e` from yolo). Echo progress as `==> [yolo:<name>] …`.
2. `embed "provisioners/provisioner-<name>.sh" as prov_<name>` and add it
   to the `PROVISIONERS` hash in `yolo.rugo`.
3. (Optional) Teach `detect_provisioner` in `yolo.rugo` to auto-select it
   from project files.
4. **Rebuild** (`rugo build yolo.rugo`).
5. Document in `docs/04-provisioners.md`.

AI-agent installers follow the same pattern under
`provisioners/ai-agents/<name>.sh`, embedded into the `AI_AGENTS` hash,
applied as a separate marker on top of the language provisioner.

## Editing agent skills

The agent skills are **source of truth in `skills/<name>/SKILL.md`** and are
**embedded into the binary at compile time** (`embed "skills/<name>/SKILL.md"
as skill_<name>` near the top of `yolo.rugo`, collected into the `SKILLS` hash).
`yolo install-skills` writes each embedded copy to
`~/.agents/skills/<name>/SKILL.md` for AI coding agents to load.

So when changing a skill:

- **Edit the repo copy** under `skills/<name>/SKILL.md` — never the installed
  `~/.agents/skills/<name>/SKILL.md` (it is a generated copy and gets
  overwritten by the next `yolo install-skills`).
- Because they're `embed`-ed, a change only ships after a **rebuild**
  (`rugo build yolo.rugo`) followed by `yolo install-skills` to refresh the
  on-disk copy.
- Adding a **new** skill: create `skills/<name>/SKILL.md`, add an
  `embed … as skill_<name>` line plus a `"<name>" => skill_<name>` entry in the
  `SKILLS` hash, then rebuild.

## Publishing a Yolofile to the hub

The **yolo hub** (`web/`) is a static GitHub Pages site (`yolo.rbel.co`)
listing curated, grab-and-go Yolofiles. Each entry is a directory under
`web/hub/<slug>/` containing a single `Yolofile`. Users consume one with:

```bash
yolo --yolofile https://yolo.rbel.co/hub/<slug>/Yolofile   # https only
```

To add an entry:

1. Create `web/hub/<slug>/Yolofile`. `<slug>` is the card name shown on the
   hub (lowercase, no spaces/quotes/backslashes).
2. **Include front matter with a `description:`** — the page parses each
   Yolofile's front matter *in the browser* and renders `description` on the
   card. Keep the usual conventions: idempotent body, `set -euo pipefail`,
   Fedora `dnf`, echo progress as `==> [yolofile] …`, and **verify checksums**
   for any downloaded binary (see `web/hub/cliamp/Yolofile` as the reference).
3. Regenerate the manifest:

   ```bash
   scripts/gen-hub-index.sh        # rewrites web/hub/index.json
   ```

   GitHub Pages has no directory listing, so `index.html` discovers entries
   via `hub/index.json` (a sorted JSON array of the slug dirs). **Never
   hand-edit `index.json`** — it is generated, and CI re-runs
   `gen-hub-index.sh` before every Pages deploy
   (`.github/workflows/static.yml`), so a stale manifest is overwritten.

The script deliberately does **not** duplicate the front-matter parser —
the Yolofiles stay the single source of truth and the browser parses them.
No rebuild is needed (the hub is plain static assets, not embedded in the
binary).

## Provisioner execution contract

Each script runs: as `root`; with host `$PWD` live-mounted at `/work`
(rw); with the guest's network (NAT by default, MITM allow-list if
`YOLO_ALLOW`); with **no implicit `set -e`** (scripts opt in). yolo pipes
the script bytes into `exec_provision` (`matchlock exec <vm> -i -u root --
bash` / `podman exec -i --user 0 <c> bash`).

## Testing & quality

There is no rugo unit-test suite for yolo. Verify changes by:

```bash
rugo build yolo.rugo && ./yolo --help >/dev/null   # parses + smoke
shellcheck provisioners/*.sh provisioners/ai-agents/*.sh backends/matchlock/*.sh
# Run a provisioner in a clean Fedora to validate it:
docker run --rm -it -v "$PWD/provisioners":/p fedora:44 bash /p/provisioner-fedora-go.sh
# End-to-end (needs /dev/kvm + matchlock, or podman):
rugo run yolo.rugo -- echo ok
rugo run yolo.rugo --backend podman -- echo ok
```

The install one-liner is verified by `scripts/verify-install*.sh` and the
`install-smoke` GitHub workflow.

## Releasing

- Bump `VERSION` in `yolo.rugo` (currently advertised by `-V`/`--version`).
  `main` carries a `-dev`-style bump after a release.
- Releases trigger on `v*` tag pushes (`.github/workflows/release.yml`):
  builds static `yolo-linux-amd64` + `yolo-linux-arm64` (CGO disabled) via
  `rugo build`, smoke-tests amd64, attaches binaries + `.sha256` to a
  GitHub release. Tags must match `^v[0-9][A-Za-z0-9._+-]*$`.

## Keep docs in sync

User-facing behaviour changes must update the relevant `docs/` chapter
(`01`–`09`), and internals changes must update `docs/architecture.md`.
The `Yolofile` reference is `docs/05-yolofile.md` — the repo-root
`Yolofile` is yolo's self-hosting provisioner, **not** the reference.
