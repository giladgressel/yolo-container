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

**Compute-node use needs a one-time podman config.** Rootless podman assumes a
systemd login session that SSH-adopted compute-node sessions don't have, so
`yolo` fails to build there until you add two small files under
`~/.config/containers/`. Hand this README's *Rootless podman on compute nodes*
section (below the divider) to Claude and it'll write them for you — they're
per-user and `~/.config` is NFS-shared, so it's a ~30-second one-time step.

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
| `.devcontainer/Dockerfile` | Node 20 + zsh + starship + git + git-lfs + gh + uv + Claude Code CLI |
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

### Rootless podman on compute nodes (per-user config, required)

Rootless podman's defaults assume a **systemd-logind user session**: it keeps
transient state under `/run/user/$UID`, logs events to `journald`, and drives
cgroup setup through `systemd`/`sd-bus`. When you SSH into a SLURM compute node,
`pam_slurm_adopt` drops you into the job's cgroup but gives you **no logind
session** — so every one of those defaults fails. You must supply per-user
config under `~/.config/containers/`. These files are **not in this repo**:
they're personal (they carry your username and node-local `/tmp` paths).
`~/.config` is NFS-shared, so you write them once and they apply on every node.

Two files. Replace `gressel` with your own username throughout.

`~/.config/containers/storage.conf` — keep images off NFS (the overlay driver
needs xattrs NFS can't do; `/tmp` is node-local xfs):

```toml
[storage]
driver = "overlay"
graphroot = "/tmp/podman-gressel/storage"
runroot = "/tmp/podman-gressel/runroot"

[storage.options.overlay]
# No subuid/subgid ranges (cluster AD identity) → single-UID mapping; let
# overlay fall back to our uid when a layer's chown fails, instead of aborting.
ignore_chown_errors = "true"
```

`~/.config/containers/containers.conf` — strip the three logind dependencies:

```toml
[engine]
# Default transient dir is /run/user/$UID (logind-created, absent here).
tmp_dir = "/tmp/podman-gressel/run/libpod/tmp"
# Default events logger "journald" needs a user systemd session.
events_logger = "file"
# Default cgroup manager "systemd" drives cgroups via sd-bus (user D-Bus);
# without it crun fails at container-create with
# "sd-bus call: Interactive authentication required". cgroupfs writes cgroups
# directly, no D-Bus. Harmless on nodes that DO have systemd too.
cgroup_manager = "cgroupfs"
```

Symptoms when these are missing/incomplete, roughly in the order you hit them:

| Error | Missing setting |
|---|---|
| `creating events dirs: mkdir /run/user/$UID: permission denied` | `tmp_dir` |
| image-layer writes fail on NFS / overlay xattr errors | `storage.conf` graphroot on `/tmp` |
| `sd-bus call: Interactive authentication required` at a `RUN`/create step | `cgroup_manager = "cgroupfs"` |

Caveat (also noted in `storage.conf`): `/tmp` is node-local, so the built image
doesn't carry across nodes — the first `yolo` on each new node rebuilds (a few
minutes). Everything after that on the same node is instant.

### Single-UID mode — the container runs as root

This cluster account has **no subuid/subgid ranges**, so rootless podman
falls back to single-UID mapping: the host UID maps to container uid 0 and
nothing else is mappable. Two consequences, both handled in the Dockerfile
and wrapper:

- **Build.** apt postinst scripts and the git-delta `dpkg` chown files to
  GIDs that don't exist in single-UID mode (adm, shadow, man, …); the real
  chown then fails with `EINVAL` and aborts the install. The build runs apt
  and that dpkg under `fakeroot` with `FAKEROOTDONTTRYCHOWN=1`, which fakes
  those chowns instead of issuing them. apt's `_apt` sandbox user is also
  disabled (`APT::Sandbox::User "root"`). All harmless when proper subuid
  ranges exist.
- **Runtime.** `USER node` (uid 1000) can't start (`setresgid` `EINVAL`),
  so there is **no `USER node`** in the image — everything runs as root
  with `HOME=/home/node`. Running as root inside a rootless container is
  unprivileged on the host, so this doesn't widen the blast radius. The
  wrapper passes `-e IS_SANDBOX=1` so Claude allows
  `--dangerously-skip-permissions` as root (it otherwise refuses, erroring
  "cannot be used with root/sudo privileges"). The old `node`-ownership
  chowns are dropped (root owns everything).

If your account *does* get subuid ranges (e.g. admins run `usermod
--add-subuids`), this image still builds and runs — the fakeroot chowns
just get faked instead of applied, which nothing depends on.

### Git worktree support

If `$PWD` is a linked git worktree (Orca, `git worktree add`, …), its
`.git` is a *file* pointing at `.git/worktrees/<name>` in the main repo,
which lives outside the `$PWD` bind mount. The wrapper detects this (reads
the `gitdir:` pointer, resolves `commondir`) and bind-mounts the main
repo's `.git` at the same host path inside the container, so `git` works.
A warning is printed if the main `.git` can't be resolved.

### Extra project mounts (`.yolo-mounts`)

`$PWD` is always mounted as `/workspace`, but projects often need data that
lives *outside* the project dir — centralized datasets, shared scratch, a
common model cache on the cluster. Rather than retyping `-v` flags every
run, drop a `.yolo-mounts` manifest at the repo root and the wrapper mounts
those paths automatically on every `yolo`. Override the location with
`YOLO_MOUNTS_FILE`.

One mount per line, same syntax as `podman -v`:

```
# Lines starting with # and blank lines are ignored.

/data/shared/corpus                  # same path inside, READ-ONLY
/data/shared/corpus:/data/corpus     # custom target inside, READ-ONLY
/data/shared/outputs/$USER:/out:rw   # explicitly writable (prompts — see below)
~/datasets:/datasets                 # leading ~ expands to $HOME
```

A bare path mounts at the *identical* path inside the container, so absolute
paths baked into configs or code still resolve. Missing sources print a
warning and are skipped — never fatal — so a manifest checked into the
project doesn't break on a machine where some path is absent. Commit it to
share the layout with your team, or keep it untracked for per-machine paths.

**Read-only by default — this is the important part.** These directories are
usually shared with the whole team, and the container writes as your *real
host user*, so a bad write to shared data is real and permanent (file
ownership won't save you — the dirs are group-writable). Therefore:

- Every manifest mount is **read-only** unless its line explicitly ends in
  `:rw`. A typo or any other option falls back to read-only — it fails safe.
- Any `:rw` mount triggers a **loud warning listing the writable host paths,
  then a typed `yes` confirmation** before the container starts. You can't
  hand Claude write access to shared data by accident.
- Set `YOLO_ALLOW_WRITE=1` to skip the prompt for scripted / non-interactive
  runs. With no TTY and no `YOLO_ALLOW_WRITE=1`, a `:rw` mount **aborts**
  (fail-closed) rather than silently proceeding.
- Best practice: point `:rw` at a *per-user output subdir*
  (`.../outputs/$USER`), never at the whole shared dataset.

> Note: "let Claude add new files but never modify existing ones" isn't
> something the Linux mount layer can enforce for group-writable shared data
> (the sticky bit blocks deletes/renames but not content overwrites). So the
> model is the binary `ro` (safe default) vs. confirmed `:rw`. If you want
> writes that *can't* corrupt shared data at all, mount `:ro` and have Claude
> write outputs into `/workspace` instead.

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
- `~/.modal.toml` → Modal CLI auth (skipped if absent)

Synced at container start (host → container one-way, `mcpServers` only):

- `mcpServers` block from `~/.claude.json` merged into
  `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json` inside the container. Tokens
  travel; no other runtime state does.

Env forwarded from host (each only if set): `WANDB_API_KEY`,
`ANTHROPIC_API_KEY`, `GH_TOKEN` (pre-auths the `gh` CLI),
`ORCA_WORKTREE_ID` (tells Claude it's in an Orca-managed worktree; other
`ORCA_*` vars are skipped — they reference host-only paths or an
unreachable hook port).

SSH agent: a live agent socket is bind-mounted as `/ssh-agent` and
re-exported. Whatever agent your login shell has (openssh, forwarded from
your laptop, 1Password — anything exposing a unix socket) carries into the
container. `bin/yolo` resolves the socket in this order: the live
`$SSH_AUTH_SOCK` it inherits; else the stable `~/.ssh/agent.sock` symlink
(see below). It refreshes that symlink to whatever it settles on, then
mounts the symlink so the source path is stable. If neither is live it
prints a warning and skips the mount (git-over-SSH won't work in the
container).

**Why the symlink** — tmux freezes `$SSH_AUTH_SOCK` at session-create
time. If you start tmux + yolo from one client (say a VS Code terminal),
disconnect, then reattach the same tmux from another client (Ghostty),
the pane still points at the *old* forwarded socket, which died with the
first connection. Pointing `$SSH_AUTH_SOCK` at a stable `~/.ssh/agent.sock`
symlink that each fresh shell re-points at the current agent decouples the
path (safe to freeze in tmux) from the target (refreshed per connection).
Add this to a shell rc that runs on every login. Put it in a cluster-local
file outside the dotfiles repo so it doesn't follow you to other machines —
here it's sourced from `~/.config/zsh/secrets.zsh` (always sourced), which
covers every node reached via ProxyJump (`ise-*`, `cs-*`, `dt-*`, `ee-*`)
without a per-host file per family:

```sh
if [ -S "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$HOME/.ssh/agent.sock" ]; then
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ln -sf "$SSH_AUTH_SOCK" "$HOME/.ssh/agent.sock"
fi
[ -e "$HOME/.ssh/agent.sock" ] && export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
```

A *running* container's mount is pinned at launch, so switching clients
still means **re-running yolo** (the container restart) to pick up the new
socket — the symlink just makes that a clean restart, and `claude --resume`
brings the session back (history lives in the `yolo-claude-config` volume,
not the container). Caveat: `~/.ssh` is NFS-shared but agent sockets are
node-local, so this one symlink is owned by whichever node you last
connected from — correct for one-node-at-a-time use, but two concurrent
nodes would fight over it.

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
    "source=yolo-uv-data,target=/home/node/.local/share/uv,type=volume",
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

**Single-UID caveat:** on an account without subuid ranges (see "Single-UID
mode" above), `"remoteUser": "node"` won't start — the container can only
run as root. Drop the `remoteUser` line (or set it to `root`) and the
config/volume paths still resolve via `HOME=/home/node`. The `yolo` wrapper
handles this automatically; only the hand-rolled devcontainer.json needs
the tweak.

### Over-the-wall flow

If you (the agent) want to change something on the host — new skill,
updated settings, tweaked statusline — you can't: host config is mounted
read-only, and `sudo chmod` fails with `EROFS`. Instead, write the
proposed change to `/workspace/_yolo_outbox/<file>` (create the dir if
missing) and tell the user exactly which `cp` command to run on the host
to apply it. The user's host `~/.claude/CLAUDE.md` already documents this
protocol, so they're expecting it.

### SLURM from inside the container

The image has no `sbatch`/`squeue`/`srun`, no munge socket, no slurm.conf —
and deliberately so. Instead of putting a slurm client *in* the container
(which means matching the site's slurm version and solving munge auth under
single-UID userns), the **`cluster`** helper (`bin/cluster`) ssh'es to your
login node over the forwarded ssh-agent and runs slurm there. Zero version
risk, no munge plumbing, and it works from any node the container runs on.

```sh
cluster squeue --me
cluster sacct -j 12345 --format=JobID,State,Elapsed,MaxRSS
cluster bash batch_submit.sh --gpu pro runs/exp.sh   # from your project dir
cluster scancel 12345
```

`bin/yolo` bind-mounts `cluster` onto the container's PATH, so it's available
in every container from any project (no rebuild).

**One-time per-user setup (each labmate does this on their own account):**

```sh
mkdir -p ~/.config/yolo
cp cluster.env.example ~/.config/yolo/cluster.env
$EDITOR ~/.config/yolo/cluster.env        # login host, your username, key name
```

Nothing user-specific is committed: `bin/cluster` reads everything from the
environment, and `bin/yolo` sources your private `~/.config/yolo/cluster.env`
and forwards it in. Your SSH **key never leaves the agent** — the config only
names *which* loaded key to pin (pinning avoids "Too many authentication
failures" when the agent carries several keys; also note the container runs as
uid 0, so the username is required or ssh tries `root@`).

**Path translation.** The container mounts your project at `/workspace`, but a
submitted job runs on a compute node in the *host* filesystem, where
`/workspace` doesn't exist. `bin/yolo` forwards the real launch path as
`YOLO_WS_HOST` (it differs per project — `/home/you/proj`, not a fixed home),
and `cluster` rewrites `/workspace/...` → that path (in both the working dir
and arguments) so job scripts baking in `$CWD` / `--output=$CWD/logs/...`
resolve. This assumes your home/project dir is on shared storage (NFS) visible
from the login and compute nodes — the normal HPC case.

> If you ever *do* want native slurm inside the container instead, the
> alternative is to bind-mount the host's own slurm binaries + `/usr/lib64/slurm`
> + `libmunge.so` + the munge socket + slurm.conf (using the host binaries
> sidesteps the Debian-vs-host version mismatch). It was not chosen here because
> of the munge-uid-under-single-UID-userns unknown; the ssh path is simpler and
> proven.

### Server-resident SSH key (detached operation)

By default `cluster` and `git push` authenticate with your **forwarded
ssh-agent**. That agent is borrowed from your laptop, so it dies the moment the
laptop detaches (lid closes, tmux reattached from another client) — and no
forwarding scheme can fix that, because a forwarded agent is *defined* by the
laptop being present. If you want the agent to keep managing jobs and pushing
while you're disconnected, give the cluster **its own** key.

Generate one passphrase-less key **on the cluster** (born there, so the private
half never crosses the network; revocable independently of your laptop keys) and
register its public half in two places — `authorized_keys` (compute→login ssh
for slurm; NFS home covers both nodes) and GitHub (push):

```sh
# On the cluster login/compute node — NOT inside the container:
ssh-keygen -t ed25519 -f ~/.ssh/yolo_server -N "" -C "yolo-server-$(hostname)"
chmod 600 ~/.ssh/yolo_server

cat ~/.ssh/yolo_server.pub >> ~/.ssh/authorized_keys   # compute -> login ssh
chmod 600 ~/.ssh/authorized_keys

# GitHub: paste ~/.ssh/yolo_server.pub at Settings -> SSH keys, or `gh ssh-key add`
```

Then point your config at it and re-run `yolo`:

```sh
echo 'YOLO_SLURM_KEYFILE=~/.ssh/yolo_server' >> ~/.config/yolo/cluster.env
```

`bin/yolo` mounts that key read-only into the container and forwards its path;
`cluster` then uses `ssh -i … -o IdentitiesOnly=yes` and **skips the ssh-agent
entirely** (`YOLO_SLURM_KEYFILE` takes precedence over `YOLO_SLURM_KEY`), and an
in-container `~/.ssh/config` block pins `github.com` to the same key so `git
push` works too (remote must be the SSH form `git@github.com:owner/repo.git`).
When the keyfile is absent, everything falls back to the forwarded-agent path, so
the connected case is unchanged.

*Trade-off:* a passphrase-less key on the server is a standing credential inside
the container's blast radius, usable when nobody's watching. That's a deliberate
choice consistent with the already-open radius (the agent can already submit jobs
as you); it's `chmod 600` and revocable on its own. Not doing per-repo deploy
keys — an account-wide key is fine here. Revisit only if the threat model changes.

### Persistent state (named podman volumes)

| Volume | Holds |
|---|---|
| `yolo-claude-config` | `/home/node/.claude` — Claude login, runtime state |
| `yolo-uv-cache` | `/home/node/.cache/uv` — uv's package cache, shared across projects |
| `yolo-uv-data` | `/home/node/.local/share/uv` — uv-managed Python interpreters, so uv doesn't re-download CPython every run |
| `yolo-bashhistory` | zsh/bash history across sessions |
| anonymous (per-run) | `/workspace/.venv` — container's Linux venv, isolated from host's venv at the same path (glibc mismatch between RHEL9 host and Debian container) |

List: `podman volume ls | grep yolo`. Nuke one: `podman volume rm <name>`.

### Sandbox guarantees

- **Read-only host paths even as root** — the container runs as root
  (single-UID mode, see above), but mounted host config is bind-mounted
  read-only, so writes fail with `EROFS` regardless of UID. This is
  kernel-enforced, not convention. Note: because it runs as root, `sudo`
  *inside* the container does work (root needs no password) — it just
  can't escape the rootless userns or write the read-only mounts. Root
  here is unprivileged on the host.
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
yolo --update        # aliases: --rebuild, -u
```
The Dockerfile pins Claude Code at `@latest`, but `@latest` is a constant
string, so a plain rebuild hits the layer cache and reinstalls the *same*
stale CLI. `yolo --update` runs `build --pull --no-cache` to force a real
refresh (also re-pulls the `node:20` base), then prints the resulting
Claude Code version and exits. (The old `podman rmi yolo-claude:latest &&
yolo` also works but doesn't `--no-cache`, so it can keep a cached CLI.)

**Force re-login to Claude:**
```sh
podman volume rm yolo-claude-config
```

**Nuke everything** (login, history, cache — full reset):
```sh
podman rmi yolo-claude:latest
podman volume rm yolo-claude-config yolo-uv-cache yolo-uv-data yolo-bashhistory
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

**`[sudo] password for node:`** — not expected on this branch: the
container runs as root (single-UID mode), so `sudo` is a no-op that needs
no password. If you see this prompt you're somehow running as a non-root
user — check that the image has no `USER node` line and that the run isn't
overriding the user.

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
the host `ssh-add -l` must list keys. `bin/yolo` now prints a warning at
launch if it can't find a live socket, so a fresh `yolo` won't silently
start broken — heed that warning and reconnect with agent forwarding
before continuing.

**SSH worked, then stopped after I reconnected from another client** —
the classic case: you started tmux + yolo from a VS Code terminal,
disconnected, then reattached the same tmux from Ghostty (or vice-versa).
The tmux pane froze the *old* forwarded socket, which died with the first
connection, and the already-running container's `/ssh-agent` mount is
pinned to it. Recovery: make sure your new shell refreshed the symlink
(`ls -l ~/.ssh/agent.sock` should point at a live socket; `ssh-add -l`
lists keys), then **exit Claude and re-run `yolo`** — the new container
grabs the live socket. `claude --resume` brings your session back. You do
*not* need to restart tmux. See "What's shared from the host → SSH agent"
for the symlink mechanism that makes the re-run pick up the live socket
even from a stale tmux pane.

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
