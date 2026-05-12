# 4. Provisioners

A **provisioner** is a plain bash script that runs as `root` inside the
guest VM the first time `yolo` attaches to it. `yolo` ships with a
handful of built-ins for common toolchains, and lets you write your
own.

For per-project provisioning that travels with the repo, jump straight
to the [Yolofile reference](./05-yolofile.md).

## 4.1 Walkthrough: get a Rust VM in one command

You don't pick a provisioner explicitly. `yolo` infers one from `$PWD`.
Try it:

```bash
cd ~/code/some-rust-project   # has Cargo.toml
yolo
# [yolo] applying fedora-rust to vm-xxxxxxxx
```

`yolo` saw `Cargo.toml`, picked `fedora-rust`, installed the Rust
toolchain plus `cargo-watch`, `cargo-edit`, and friends, and dropped
you into the VM. Subsequent `yolo` runs in this directory skip the
provisioner — it has already been applied to this VM.

## 4.2 Built-in provisioners

```
❯ yolo provisioners
Available provisioners:
  fedora-go
  fedora-rust
  fedora-ruby
  fedora-android
```

| Name             | Triggered by                                          | Installs |
| ---------------- | ----------------------------------------------------- | -------- |
| `fedora-go`      | `go.mod`, `go.sum`, `*.go`                            | Latest upstream Go (or `$YOLO_GO_VERSION`), `gopls`, `staticcheck`, `dlv`, `goimports`, `gofumpt`, `golangci-lint`. |
| `fedora-rust`    | `Cargo.toml`, `rust-toolchain.toml`, `rust-toolchain` | `rustup` stable toolchain plus common cargo extensions. |
| `fedora-ruby`    | `Gemfile`, `.ruby-version`, `*.gemspec`               | Ruby, bundler, build deps. |
| `fedora-android` | `build.gradle[.kts]`, `settings.gradle[.kts]`, `app/build.gradle[.kts]` | OpenJDK, Android command-line tools and SDK pieces. |

All built-ins assume a Fedora-based base image. They use `dnf` for OS
packages.

## 4.3 Provisioner resolution

When you run `yolo`, the provisioner is chosen in this order:

1. `--provisioner NAME` on the command line (explicit).
2. A `Yolofile` in the current directory (see
   [chapter 5](./05-yolofile.md)).
3. **Auto-detection** from files in `$PWD` per the table above.
4. Otherwise: no provisioner runs.

Skip provisioning entirely with `--no-provision`.

## 4.4 Forcing a different built-in

```bash
yolo --provisioner fedora-go            # ignore any Yolofile / auto-detect
yolo --provisioner fedora-rust          # force Rust even in a Go directory
```

To force a re-run after a provisioner has already been applied:

```bash
yolo provision                          # re-apply the same provisioner
yolo provision --provisioner fedora-go  # re-apply a specific one
```

This is idempotent — the provisioner scripts are written to be safe to
run again.

## 4.5 AI agents

On top of any language provisioner, `--ai-agent` installs an AI coding
agent inside the VM:

```bash
yolo --ai-agent              # installs `copilot` (default)
yolo --ai-agent opencode     # installs `opencode`
```

The agent installer runs after the language provisioner and is
remembered as a separate marker (`ai-agent:NAME`), so editing the agent
script invalidates only the agent layer.

## 4.6 Adding a new built-in provisioner

Provisioners live in [`provisioners/`](../provisioners) as plain bash
scripts and are embedded into the `yolo` binary at compile time via
rugo's `embed` directive.

1. Drop a bash script at `provisioners/provisioner-<name>.sh`:

   ```bash
   #!/usr/bin/env bash
   # provisioners/provisioner-fedora-node.sh
   set -euo pipefail
   NODE_VER="${YOLO_NODE_VERSION:-22}"
   dnf -y install "nodejs${NODE_VER}" npm
   corepack enable
   echo "node $(node --version), pnpm $(pnpm --version)"
   ```

2. Register it in `yolo.rugo`:

   ```ruby
   embed "provisioners/provisioner-fedora-node.sh" as prov_fedora_node
   PROVISIONERS = {
     "fedora-go"      => prov_fedora_go,
     "fedora-rust"    => prov_fedora_rust,
     "fedora-ruby"    => prov_fedora_ruby,
     "fedora-android" => prov_fedora_android,
     "fedora-node"    => prov_fedora_node
   }
   ```

3. (Optional) Teach `detect_provisioner` in `yolo.rugo` to recognise
   `package.json` and friends so it auto-runs.

4. Rebuild: `rugo build yolo.rugo`. The script is now baked into the
   binary.

## 4.7 Testing a provisioner

Provisioners are plain bash. Run one in any clean Fedora environment:

```bash
docker run --rm -it -v "$PWD/provisioners":/p fedora:44 \
  bash /p/provisioner-fedora-go.sh
```

Or simply lint:

```bash
shellcheck provisioners/*.sh
```

## 4.8 Custom tooling for one project

Built-in provisioners cover the common cases. For project-specific
tooling — a particular version pin, internal packages, a private
registry — drop a [Yolofile](./05-yolofile.md) at the project root.
