# yolo-container — SLURM / podman branch

> Branch: `slurm-podman`. For the macOS / OrbStack version, see `main`.

---

## For the human

**What this is.** A disposable Linux container that runs Claude Code in full
YOLO mode (`claude --dangerously-skip-permissions`) on a SLURM cluster.
Runs on either the login node or inside an SSH'd interactive compute
allocation. One shared image; whichever project directory you `cd` into
gets bind-mounted inside. Exit the shell and the container vanishes.

**Why you want it.** YOLO mode is the fastest way to work with Claude — no
permission prompts, no babysitting. Running it directly on a shared
cluster account is risky: a confused agent can `rm`, rewrite dotfiles,
clobber configs, or push to the wrong remote. This setup keeps the speed
(no prompts) and removes most of the blast radius (container + read-only
host config + cluster's own egress policy). Use it for overnight runs,
long agent-in-a-loop tasks, or anything you don't want to watch.

### Install (one-time)

The cluster already has `podman` preinstalled. No daemon to start.

```sh
git clone git@github.com:giladgressel/yolo-container.git ~/code/yolo-container
cd ~/code/yolo-container && git checkout slurm-podman
ln -s ~/code/yolo-container/bin/yolo ~/.local/bin/yolo
# (~/.local/bin must be on your PATH — check with: echo $PATH)
```

First time you run `yolo` it builds the image (a few minutes). After that,
launches are instant.

### Daily use — login node

Quick and dirty, no GPU:

```sh
cd ~/code/any-project
yolo              # enters the container at /workspace
cg                # alias for: claude --dangerously-skip-permissions
```

Your edits flow live through the bind mount. Claude login, shell history,
and package caches survive across runs in named podman volumes. Exit the
shell when done — the container is ephemeral, state lives in the volumes.

### Daily use — GPU compute node (the normal path)

Standard cluster workflow here is the "sleep-job + SSH in" trick (see
`~/rtx6000pro_golden.sh`): `sbatch` a job that sleeps forever to hold a
node, print its IP, then SSH into it interactively. Inside that SSH
session, `yolo` works exactly the same way — and auto-detects the GPU:

```sh
bash ~/rtx6000pro_golden.sh 12h          # allocate a node, prints the IP
ssh <node-ip>                            # drops you into an interactive shell on the GPU node
cd ~/code/any-project && yolo            # container picks up /dev/nvidia*
```

Inside the container you should see the GPU via `nvidia-smi`. Because
SLURM has put your SSH session inside a cgroup tied to the allocation,
the container only sees the GPU(s) you were granted.

### Daily use — Cursor / VS Code

Use **Remote-SSH** to connect Cursor/VS Code to the compute node (same IP
`rtx6000pro_golden.sh` prints). Then either:

1. Open a terminal in the remote window, run `yolo`, and work in the
   terminal; or
2. Install the **Dev Containers** extension on the remote, set
   `dev.containers.dockerPath` to `podman`, and use `Dev Containers:
   Attach to Running Container` → pick `yolo-claude:latest` after you've
   started one with `yolo` in a terminal.

### What this protects

- **Your home dotfiles.** `~/.claude/`, `~/.gitconfig`, `~/.netrc`, and a
  handful of others are visible to the container read-only — the kernel
  blocks writes even with sudo.
- **Your project files outside $PWD.** Only the directory you ran `yolo`
  from is bind-mounted as `/workspace`.
- **The rest of the cluster.** Container is rootless and has no special
  capabilities — it can't touch `/etc`, shared `/storage` paths you
  didn't mount in, or other users' homes.

### What it doesn't protect against

An agent inside the container can still read and exfiltrate anything it
can reach:

- Your project files (they're bind-mounted live — that's the point).
- `ANTHROPIC_API_KEY`, `WANDB_API_KEY` (forwarded as env vars).
- MCP tokens synced from your host `~/.claude.json` (e.g. wandb, Gmail).
- Your forwarded SSH agent — can *sign* things (push commits, SSH to
  other hosts) but can't read the private keys.
- Network egress — no in-container firewall on this branch. The cluster
  perimeter is your only egress control.

Use this for your own code or code you trust. It's a convenience sandbox
so you're not afraid to run YOLO mode — not a zero-trust boundary for
untrusted workloads.

### If something breaks or you want to customize

Hand the rest of this README to Claude. Everything below the divider is
written for an LLM tasked with installing, debugging, or modifying this
setup on your behalf.

---

## For the coding agent

You are an LLM maintaining this setup on the user's behalf. The human has
the "what" and "how to use it" above. Everything below is install
internals, debugging context, and modifications — assume the user has not
read it.

### Files

| File | Purpose |
|---|---|
| `.devcontainer/Dockerfile` | Node 20 + zsh + starship + git + gh + uv + Claude Code CLI |
| `.devcontainer/devcontainer.json` | VS Code / Cursor "Reopen in Container" config (builds the image) |
| `bin/yolo` | Terminal wrapper — symlinked into `~/.local/bin/yolo` |

The `yolo` wrapper self-locates the repo via its symlink, so the clone
can live anywhere. The image bakes a `/home/$HOST_USERNAME/.claude ->
/home/node/.claude` symlink at build time so host-style paths in the
user's `settings.json` resolve inside the container. `HOST_USERNAME` is a
build arg that defaults to `user` (devcontainer.json passes
`${localEnv:USER}` on a Linux host, e.g. `gressel`). The symlink is
skipped if `HOST_USERNAME=node` to avoid self-referencing.

### Container engine

This branch uses **rootless `podman`** (preinstalled on the cluster). The
`yolo` wrapper calls `$YOLO_ENGINE` which defaults to `podman`; set
`YOLO_ENGINE=docker` to use docker instead if you somehow have it. All
semantics are the same: `podman run`, `podman build`, `podman volume ls`.

### What's shared from the host

Read-only bind mounts (kernel rejects writes from inside the container):

- `~/.claude/CLAUDE.md` — global instructions
- `~/.claude/settings.json` + `settings.local.json`
- `~/.claude/skills/`
- `~/.claude/statusline-command.sh`
- `~/.config/starship.toml` (the wrapper falls back to
  `~/.dotfiles/starship.toml` if the standard location is empty)
- `~/.netrc` → wandb SDK auth
- `~/.gitconfig` → commits carry the host user's name/email

Synced at container start (host → container one-way, `mcpServers` only):

- `mcpServers` block from `~/.claude.json` merged into
  `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json` inside the container. Tokens
  travel; no other runtime state does.

Env forwarded from host (only if set): `WANDB_API_KEY`, `ANTHROPIC_API_KEY`.

SSH agent: `$SSH_AUTH_SOCK` is bind-mounted as `/ssh-agent` and
re-exported. Whatever agent your login shell has (openssh, forwarded from
your laptop, 1Password — anything exposing a unix socket in the
`SSH_AUTH_SOCK` env var) carries into the container. If `SSH_AUTH_SOCK`
is unset on the host, the mount is skipped silently.

All host-path mounts in `bin/yolo` are **conditional on the source file
existing** (via `add_ro`). Forks without e.g. `.netrc` see no error — the
mount is silently skipped. `devcontainer.json` mounts are *not*
conditional (the Dev Containers spec doesn't support it), so for the
Reopen flow, any host file that doesn't exist must be removed from that
mount list.

### GPU passthrough (auto-detect)

`bin/yolo` picks one of three modes, in priority order:

1. **CDI** — if `nvidia-ctk` is installed on the host and
   `/etc/cdi/nvidia*.yaml` (or `/var/run/cdi/...`) exists, passes
   `--device nvidia.com/gpu=all`. This is the "right" way, but most HPC
   sites don't set it up.
2. **Devices + driver libs** — if `/dev/nvidiactl` exists, bind-mounts
   the `/dev/nvidia*` character devices plus the userspace driver libs
   (`libcuda.so`, `libnvidia-ml.so`, `libnvidia-ptxjitcompiler.so`,
   `libnvidia-nvvm.so`) from `/usr/lib64/`, plus `nvidia-smi`. This is
   what this cluster uses. The container's CUDA runtime dlopens the
   mounted libs.
3. **None** — no GPU available (login node). Skip silently.

Under an interactive SLURM allocation, the SSH session is already inside
the cgroup that restricts GPU device visibility, so mounting *all*
`/dev/nvidia*` still only exposes the allocated GPU(s).

**Note:** the base image (`node:20`, Debian 12) ships no CUDA runtime
libraries. Driver userspace libs get bind-mounted from the host, so
`nvidia-smi` works inside. But to actually run CUDA workloads you need
CUDA runtime libs — either install them in your project's venv
(`pip install torch` etc.) or add them to the base image. PyTorch /
TensorFlow wheels bundle their own CUDA runtime, so if you're using
those, this works out of the box.

### What the author wanted (and how to opt out)

| Choice | Why it's here | How to opt out |
|---|---|---|
| **Starship prompt** baked into the image | Container prompt matches a starship-using host | Remove the `curl ... starship.rs/install.sh` line in `Dockerfile` and the `starship init zsh` line in the zsh-in-docker args |
| **MCP sync** from host `~/.claude.json` | Host-configured MCPs (wandb, Gmail, etc.) "just work" in the container — tokens travel | Delete the `/yolo/host-claude.json` mount + the jq-merge block in `bin/yolo` (and `postStartCommand` in `devcontainer.json`) |
| **`WANDB_API_KEY`** forwarding | wandb HTTP MCP authentication | Remove the `[ -n "${WANDB_API_KEY:-}" ]` block in `bin/yolo` |
| **`~/.netrc`** mount | wandb Python SDK authentication | Remove the `add_ro "$HOME/.netrc" ...` line in `bin/yolo` |
| **`~/.agents/skills`** mount | Skills that live outside `~/.claude/skills/` via symlinks — nonstandard layout | `add_ro` skips it if missing; ignore if not relevant |
| **`cg`** alias | Shorthand for `claude --dangerously-skip-permissions` inside the container | Remove the `-a "alias cg=..."` line in `Dockerfile` |
| **GPU auto-mount** | Claude needs GPU inside the container for training work | Just run on a CPU-only node; auto-detect finds nothing and skips |
| **No firewall** | Rootless podman can't do iptables cleanly; cluster perimeter already gates egress | N/A — there's nothing to opt out of |

### Cursor / VS Code — Reopen in Container (advanced)

The main flow is Remote-SSH into the compute node, then run `yolo` in a
terminal. If you live in one project every day and want one-click
open-in-container on top of that, drop this file as
`<project>/.devcontainer/devcontainer.json` — identical to the canonical
one except it references the pre-built image instead of rebuilding:

```jsonc
{
  "name": "YOLO Claude Code",
  "image": "yolo-claude:latest",
  "remoteUser": "node",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind",
  "workspaceFolder": "/workspace",
  "mounts": [
    "source=yolo-bashhistory,target=/commandhistory,type=volume",
    "source=yolo-claude-config,target=/home/node/.claude,type=volume",
    "source=yolo-uv-cache,target=/home/node/.cache/uv,type=volume",
    "source=${localEnv:SSH_AUTH_SOCK},target=/ssh-agent,type=bind",
    "source=${localEnv:HOME}/.claude/CLAUDE.md,target=/home/node/.claude/CLAUDE.md,type=bind,readonly",
    "source=${localEnv:HOME}/.claude/settings.json,target=/home/node/.claude/settings.json,type=bind,readonly",
    "source=${localEnv:HOME}/.claude/settings.local.json,target=/home/node/.claude/settings.local.json,type=bind,readonly",
    "source=${localEnv:HOME}/.claude/skills,target=/home/node/.claude/skills,type=bind,readonly",
    "source=${localEnv:HOME}/.claude/statusline-command.sh,target=/home/node/.claude/statusline-command.sh,type=bind,readonly",
    "source=${localEnv:HOME}/.claude.json,target=/yolo/host-claude.json,type=bind,readonly",
    "source=${localEnv:HOME}/.config/starship.toml,target=/home/node/.config/starship.toml,type=bind,readonly",
    "source=${localEnv:HOME}/.netrc,target=/home/node/.netrc,type=bind,readonly",
    "source=${localEnv:HOME}/.gitconfig,target=/home/node/.gitconfig,type=bind,readonly"
  ],
  "containerEnv": {
    "NODE_OPTIONS": "--max-old-space-size=4096",
    "CLAUDE_CONFIG_DIR": "/home/node/.claude",
    "SSH_AUTH_SOCK": "/ssh-agent"
  },
  "remoteEnv": {
    "WANDB_API_KEY": "${localEnv:WANDB_API_KEY}",
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}"
  },
  "postStartCommand": "bash -c 'if [ -f /yolo/host-claude.json ]; then target=\"${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json\"; host_mcps=$(jq -c \".mcpServers // {}\" /yolo/host-claude.json 2>/dev/null || echo \"{}\"); if [ -f \"$target\" ]; then jq --argjson m \"$host_mcps\" \".mcpServers = \\$m\" \"$target\" > \"$target.tmp\" && mv \"$target.tmp\" \"$target\"; else echo \"{\\\"mcpServers\\\": $host_mcps}\" | jq . > \"$target\"; fi; fi && if [ -f /workspace/pyproject.toml ] && [ ! -x /workspace/.venv/bin/python ]; then (cd /workspace && uv sync); fi'",
  "waitFor": "postStartCommand"
}
```

GPU passthrough is NOT wired into this devcontainer.json — the Dev
Containers extension doesn't expose an easy way to auto-detect devices.
For GPU work, use the `yolo` wrapper + Attach flow instead.

Then: **Cmd+Shift+P** → `Dev Containers: Reopen in Container`. Remove any
mount whose host-side source doesn't exist for this user. Set
`dev.containers.dockerPath` to `podman` in VS Code settings.

### Over-the-wall flow

If you (the agent) want to change something on the host — new skill,
updated settings, tweaked statusline — you can't: host config is mounted
read-only, and `sudo chmod` fails with `EROFS`. Instead, write the
proposed change to `/workspace/_yolo_outbox/<file>` (create the dir if
missing) and tell the user exactly which `cp` command to run on the host
to apply it. The user's host `~/.claude/CLAUDE.md` already documents this
protocol, so they're expecting it.

### SLURM from inside the container

Not wired in this branch. The image has no `sbatch`/`squeue`/`srun`, no
munge socket, no slurm.conf. If Claude needs to submit or check jobs, the
simplest path is `ssh <login-node> squeue -u $USER` etc. — the forwarded
ssh-agent makes this work without passwords. (Your login shell on the
compute node can also ssh to the login node if it's in known_hosts.)

If you want SLURM commands *inside* the container, the cleanest approach
is to install `slurm-client` + `libmunge2` in the Debian image and
bind-mount `/var/run/munge/` plus whatever slurm.conf the site uses (find
it with `scontrol show config | grep SLURM_CONF`). Protocol compat
between Debian slurm-client and RHEL9 slurmd is usually fine within a
major version, but test before relying on it.

### Persistent state (named podman volumes)

| Volume | Holds |
|---|---|
| `yolo-claude-config` | `/home/node/.claude` — Claude login, runtime state |
| `yolo-uv-cache` | uv's package cache, shared across projects |
| `yolo-bashhistory` | zsh/bash history across sessions |
| anonymous (per-run) | `/workspace/.venv` — container's Linux venv, isolated from host's venv at the same path (glibc mismatch between RHEL9 host and Debian container) |

List: `podman volume ls | grep yolo`. Nuke one: `podman volume rm <name>`.

### Sandbox guarantees

- **Root FS is read-only on mounted host paths** — `sudo chmod` fails
  with `EROFS` regardless of UID. This is kernel-enforced, not
  convention.
- **No password sudo** inside the container — the `node` user has no
  password set. `sudo` prompts and fails.
- **No host creds mounted** — no SSH keys (agent forwarded, signing
  only), no AWS/GCP creds, no `.credentials.json`.
- **SLURM cgroup** — when running on a compute node inside an interactive
  allocation, the container inherits your SSH session's cgroup. CPU,
  memory, and GPU visibility are enforced by SLURM.

### Common tasks

**Rebuild the image** (after editing Dockerfile):
```sh
podman rmi yolo-claude:latest
yolo   # next run rebuilds
```

**Update Claude Code to latest:**
```sh
podman rmi yolo-claude:latest && yolo
```

**Force re-login to Claude:**
```sh
podman volume rm yolo-claude-config
```

**Nuke everything** (login, history, cache — full reset):
```sh
podman rmi yolo-claude:latest
podman volume rm yolo-claude-config yolo-uv-cache yolo-bashhistory
yolo
```

### Troubleshooting

**`yolo: podman CLI not found`** — not expected on this cluster. Check
`which podman`; if missing, `module load` whatever provides it or ask
cluster admins.

**Prompt is powerlevel10k, not starship** — Dockerfile should strip
`ZSH_THEME` after zsh-in-docker (line near the bottom: `sed -i
's|^ZSH_THEME=.*|ZSH_THEME=""|' /home/node/.zshrc`). Rebuild.

**`claude: command not found`** — Debian's `/etc/zsh/zshenv` can reset
PATH; Dockerfile appends npm-global to PATH in `.zshrc` via a
zsh-in-docker `-a` arg. Rebuild.

**`[sudo] password for node:`** — the node user has no password. Nothing
inside the container is supposed to need sudo. If something does, it's a
regression — check what script is asking and drop the sudo call.

**wandb MCP missing from `claude mcp list`** — MCP sync needs host
`~/.claude.json` to exist and `CLAUDE_CONFIG_DIR` to resolve correctly.
Inspect inside the container: `cat ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json | jq .mcpServers`.

**`echo x >> ~/.claude/CLAUDE.md` → `Read-only file system`** — working
as intended (sandbox guarantee). Use the over-the-wall flow above.

**Statusline path error** — `settings.json` often references host paths
like `/home/<your-username>/.claude/statusline-command.sh`. The image
bakes `/home/$HOST_USERNAME/.claude -> /home/node/.claude` to resolve
them; the build arg defaults to `$(whoami)` via the wrapper. If the host
user changes, rebuild.

**GPU not visible inside the container** — check in this order:
1. `ls /dev/nvidia*` on the host — empty means no GPU on this node (you
   ran `yolo` on the login node).
2. `yolo` output line should say `gpu=devices` or `gpu=cdi`. `gpu=none`
   means detection found no GPU.
3. Inside the container: `nvidia-smi`. If it complains about driver
   version mismatch, the host's `/usr/lib64/libcuda.so*` is a newer
   major than whatever CUDA runtime your Python env has. Upgrade your
   torch/cuda wheels or use a CUDA-flavored base image.

**SSH agent: `Could not open a connection to your authentication agent`**
— `$SSH_AUTH_SOCK` inside the container should be `/ssh-agent`, and on
the host `ssh-add -l` must list keys. If the host's `$SSH_AUTH_SOCK` is
unset, the mount is skipped silently and agent forwarding won't work.
Check by running `echo $SSH_AUTH_SOCK` on the host before launching.

**SELinux denials in `/var/log/audit/audit.log`** — the wrapper passes
`--security-opt label=disable` which should avoid relabeling host paths.
If you're hitting denials anyway, you may have a per-user SELinux
policy that overrides; ask cluster admins.

**`podman build` pulls from docker.io and fails** — cluster egress may
block docker.io. Try adding `--pull=never` after pulling manually in a
shell that can reach it, or configure a local registry mirror in
`~/.config/containers/registries.conf`.

### Tweaking

- **Bump/remove resource caps:** none are set in `bin/yolo` on this
  branch — SLURM's cgroup governs. If you want hard container-level
  caps, add `--memory` / `--cpus` to the `args` array.
- **Add a system package to base:** edit the `apt-get install` block in
  `.devcontainer/Dockerfile`, rebuild.
- **Per-project system deps:** drop a `.devcontainer/Dockerfile` in the
  project:
  ```dockerfile
  FROM yolo-claude:latest
  USER root
  RUN apt-get update && apt-get install -y libpq-dev && rm -rf /var/lib/apt/lists/*
  USER node
  ```
  Then `Dev Containers: Reopen in Container` from that repo picks up the
  local Dockerfile on top of the base image.
- **CUDA-flavored base image:** change `FROM node:20` in `Dockerfile` to
  an nvidia/cuda image with node layered on (or vice versa) if you want
  CUDA runtime libs in the base instead of per-project venvs.
