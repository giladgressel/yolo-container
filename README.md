# yolo-container

---

## For the human

**What this is.** A disposable Linux container on your Mac that runs Claude
Code in full YOLO mode (`claude --dangerously-skip-permissions`) without
any ability to touch your host filesystem, your LAN, or your cloud
credentials. One shared image; whichever project directory you `cd` into
gets bind-mounted inside. Exit the shell and the container vanishes.

**Why you want it.** YOLO mode is the fastest way to work with Claude — no
permission prompts, no babysitting. On a bare Mac that speed comes with
real risk: a confused or malicious agent can `rm`, `chmod`, exfiltrate
your SSH keys, pivot into your router, or push to the wrong remote. This
setup keeps the speed (no prompts) and removes the blast radius (container
+ blacklist firewall + read-only host config). Use it for overnight runs,
long agent-in-a-loop tasks, or anything you don't want to watch.

### Install (one-time)

```sh
brew install orbstack && open -a OrbStack
git clone git@github.com:giladgressel/yolo-container.git ~/code/yolo-container
ln -s ~/code/yolo-container/bin/yolo ~/.local/bin/yolo
# (~/.local/bin must be on your PATH)
```

First time you run `yolo` it builds the image (a few minutes). After that,
launches are instant.

### Daily use — terminal

```sh
cd ~/code/any-project
yolo              # enters the container at /workspace
cg                # alias for: claude --dangerously-skip-permissions
```

Your edits flow live through the bind mount, so you can keep using your
Mac-side editor while Claude runs inside the container. Your Claude login,
shell history, and package caches survive across runs in named Docker
volumes. Exit the shell when you're done — the container is ephemeral,
state lives in the volumes.

### Daily use — Cursor / VS Code

Easy path: install the **Dev Containers** extension
(`ms-vscode-remote.remote-containers`), then:

1. In a terminal: `cd ~/code/any-project && yolo` (starts the container)
2. In Cursor / VS Code: **Cmd+Shift+P** → `Dev Containers: Attach to Running Container` → pick `yolo-claude:latest`
3. In the attached window: **File → Open Folder → `/workspace`**

You now have an editor wired into the same container your terminal is in.
Close the Cursor window when done; exit the terminal to kill the
container. Zero per-project config.

(There's also a "Reopen in Container" flow for projects you live in every
day — more convenient, but requires a `.devcontainer/devcontainer.json` in
each project. See the agent section below for the template.)

### What this protects

- **Host filesystem.** Only `~/.claude/` and a handful of dotfiles are
  visible to the container, all read-only — the kernel blocks writes even
  with sudo.
- **Your LAN.** Firewall blocks `10/8`, `172.16/12`, `192.168/16` — so the
  container can't reach your router, NAS, printer, or other machines on
  your network.
- **Cloud metadata.** `169.254/16` blocked — no AWS/GCP metadata pivots.
- **Outbound SMTP.** Ports 25/465/587 blocked — common spam path if a
  container gets compromised.

### What it doesn't protect against

An agent inside the container can still read and exfiltrate anything it
can reach:

- Your project files (they're bind-mounted live — that's the point).
- `ANTHROPIC_API_KEY`, `WANDB_API_KEY` (forwarded as env vars).
- MCP tokens synced from your host `~/.claude.json` (e.g. wandb, Gmail
  tokens if you've logged in).
- Your forwarded SSH agent — can *sign* things (push commits, SSH to
  hosts) but can't read the private keys.

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
internals, debugging context, modifications, and the advanced VS Code
workflow — assume the user has not read it.

### Files

| File | Purpose |
|---|---|
| `.devcontainer/Dockerfile` | Node 20 + zsh + starship + git + gh + iptables + uv + Claude Code CLI |
| `.devcontainer/devcontainer.json` | Cursor/VS Code "Reopen in Container" config (builds the image) |
| `.devcontainer/init-firewall.sh` | Blacklist iptables rules, runs at container start via NOPASSWD sudo |
| `bin/yolo` | Terminal wrapper — symlinked into `~/.local/bin/yolo` |

The `yolo` wrapper self-locates the repo via its symlink, so the clone can
live anywhere. The image bakes a `/Users/$HOST_USERNAME/.claude ->
/home/node/.claude` symlink at build time so host-style paths in the
user's `settings.json` resolve inside the container. `HOST_USERNAME` is a
build arg that defaults to `$(whoami)` at build time — no runtime sudo
needed.

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

All host-path mounts in `bin/yolo` are **conditional on the source file
existing** (via `add_ro`). Forks without e.g. `.netrc` see no error — the
mount is silently skipped. `devcontainer.json` mounts are *not*
conditional (the Dev Containers spec doesn't support it), so for the
Reopen flow, any host file that doesn't exist must be removed from that
mount list.

### What the author wanted (and how to opt out)

| Choice | Why it's here | How to opt out |
|---|---|---|
| **Starship prompt** baked into the image | Container prompt matches a starship-using host | Remove the `curl ... starship.rs/install.sh` line in `Dockerfile` and the `starship init zsh` line in the zsh-in-docker args |
| **MCP sync** from host `~/.claude.json` | Host-configured MCPs (wandb, Gmail, etc.) "just work" in the container — tokens travel | Delete the `/yolo/host-claude.json` mount + the jq-merge block in `bin/yolo` (and `postStartCommand` in `devcontainer.json`) |
| **`WANDB_API_KEY`** forwarding | wandb HTTP MCP authentication | Remove the `[ -n "${WANDB_API_KEY:-}" ]` block in `bin/yolo` |
| **`~/.netrc`** mount | wandb Python SDK authentication | Remove the `add_ro "$HOME/.netrc" ...` line in `bin/yolo` |
| **`~/.agents/skills`** mount | Skills that live outside `~/.claude/skills/` via symlinks — nonstandard layout | `add_ro` skips it if missing; ignore if not relevant |
| **`cg`** alias | Shorthand for `claude --dangerously-skip-permissions` inside the container | Remove the `-a "alias cg=..."` line in `Dockerfile` |

### Cursor / VS Code — Reopen in Container (advanced)

One-click open-in-container, but requires dropping a
`.devcontainer/devcontainer.json` into each project. Worth it only for
projects the user lives in every day; for everything else, use the Attach
flow from the human section.

Drop this file as `<project>/.devcontainer/devcontainer.json` — identical
to the canonical one except it references the pre-built image instead of
rebuilding:

```jsonc
{
  "name": "YOLO Claude Code",
  "image": "yolo-claude:latest",
  "runArgs": ["--cap-add=NET_ADMIN", "--cap-add=NET_RAW"],
  "remoteUser": "node",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=delegated",
  "workspaceFolder": "/workspace",
  "mounts": [
    "source=yolo-bashhistory,target=/commandhistory,type=volume",
    "source=yolo-claude-config,target=/home/node/.claude,type=volume",
    "source=yolo-uv-cache,target=/home/node/.cache/uv,type=volume",
    "source=/run/host-services/ssh-auth.sock,target=/ssh-agent,type=bind",
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
  "postStartCommand": "bash -c 'sudo /usr/local/bin/init-firewall.sh && if [ -f /yolo/host-claude.json ]; then target=\"${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json\"; host_mcps=$(jq -c \".mcpServers // {}\" /yolo/host-claude.json 2>/dev/null || echo \"{}\"); if [ -f \"$target\" ]; then jq --argjson m \"$host_mcps\" \".mcpServers = \\$m\" \"$target\" > \"$target.tmp\" && mv \"$target.tmp\" \"$target\"; else echo \"{\\\"mcpServers\\\": $host_mcps}\" | jq . > \"$target\"; fi; fi && if [ -f /workspace/pyproject.toml ] && [ ! -x /workspace/.venv/bin/python ]; then (cd /workspace && uv sync); fi'",
  "waitFor": "postStartCommand"
}
```

Then: **Cmd+Shift+P** → `Dev Containers: Reopen in Container`. Remove any
mount whose host-side source doesn't exist for this user.

### Over-the-wall flow

If you (the agent) want to change something on the host — new skill,
updated settings, tweaked statusline — you can't: host config is mounted
read-only, and `sudo chmod` fails with `EROFS`. Instead, write the
proposed change to `/workspace/_yolo_outbox/<file>` (create the dir if
missing) and tell the user exactly which `cp` command to run on the host
to apply it. The user's host `~/.claude/CLAUDE.md` already documents this
protocol, so they're expecting it.

### Firewall internals

Blacklist mode (default allow, reject specific targets). Rules in
`.devcontainer/init-firewall.sh`:

- REJECT outbound to `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`
- REJECT outbound TCP 25 / 465 / 587 (SMTP)
- ACCEPT DNS (UDP/TCP 53) — inserted as OUTPUT rule 1 so it wins over
  private-range REJECTs for resolvers that live on LAN

Also `chmod 666 /ssh-agent` so the non-root `node` user can connect to the
forwarded OrbStack SSH socket (OrbStack mounts it as root:root 0600 by
default).

### Persistent state (named Docker volumes)

| Volume | Holds |
|---|---|
| `yolo-claude-config` | `/home/node/.claude` — Claude login, runtime state |
| `yolo-uv-cache` | uv's package cache, shared across projects |
| `yolo-bashhistory` | zsh/bash history across sessions |
| anonymous (per-run) | `/workspace/.venv` — container's Linux venv, isolated from host's macOS venv at the same path |

List: `docker volume ls | grep yolo`. Nuke one: `docker volume rm <name>`.

### Sandbox guarantees

- **Root FS is read-only on mounted host paths** — `sudo chmod` fails with
  `EROFS` regardless of UID. This is kernel-enforced, not convention.
- **No sudo password** — node user can only `sudo /usr/local/bin/init-firewall.sh`
  (NOPASSWD whitelist). Everything else prompts for a password that
  doesn't exist.
- **No host creds mounted** — no SSH keys (agent forwarded, signing only),
  no AWS/GCP creds, no `.credentials.json`.
- **Firewall** — blocks LAN + cloud metadata. Can't pivot to router, NAS,
  printer, or cloud provider metadata endpoints.
- **Resource caps** — 8GB RAM, 4 CPUs (set in `bin/yolo`).

### Common tasks

**Rebuild the image** (after editing Dockerfile or init-firewall.sh):
```sh
docker rmi yolo-claude:latest
yolo   # next run rebuilds
```

**Update Claude Code to latest:**
```sh
docker rmi yolo-claude:latest && yolo
```

**Force re-login to Claude:**
```sh
docker volume rm yolo-claude-config
```

**Nuke everything** (login, history, cache — full reset):
```sh
docker rmi yolo-claude:latest
docker volume rm yolo-claude-config yolo-uv-cache yolo-bashhistory
yolo
```

### Troubleshooting

**`yolo: docker CLI not found`** — `brew install orbstack && open -a OrbStack`.

**`Cannot connect to the Docker daemon`** — OrbStack app isn't running.

**Prompt is powerlevel10k, not starship** — Dockerfile should strip
`ZSH_THEME` after zsh-in-docker (line near the bottom: `sed -i
's|^ZSH_THEME=.*|ZSH_THEME=""|' /home/node/.zshrc`). Rebuild.

**`claude: command not found`** — Debian's `/etc/zsh/zshenv` can reset
PATH; Dockerfile appends npm-global to PATH in `.zshrc` via a zsh-in-docker
`-a` arg. Rebuild.

**`[sudo] password for node:`** — You hit a `sudo` for something not
whitelisted. Only `init-firewall.sh` is NOPASSWD; everything else fails
(node user has no password). Check what script ran sudo and whitelist it
in the image if needed.

**wandb MCP missing from `claude mcp list`** — MCP sync needs host
`~/.claude.json` to exist and `CLAUDE_CONFIG_DIR` to resolve correctly.
Inspect inside the container: `cat ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json | jq .mcpServers`.

**`echo x >> ~/.claude/CLAUDE.md` → `Read-only file system`** — working as
intended (sandbox guarantee). Use the over-the-wall flow above.

**Statusline path error** — `settings.json` often references host paths
like `/Users/<your-username>/.claude/statusline-command.sh`. The image
bakes `/Users/$HOST_USERNAME/.claude -> /home/node/.claude` to resolve
them; the build arg defaults to `$(whoami)`. If the host user is renamed,
rebuild.

**Network request that should work is blocked** — Target might be on a
private range. `getent hosts <host>` shows the resolved IP; if it's in a
blocked CIDR, edit `init-firewall.sh` to `ACCEPT` it *before* the REJECT
rules, rebuild.

**SSH agent: `Could not open a connection to your authentication agent`**
— `$SSH_AUTH_SOCK` inside the container should be `/ssh-agent`, and on
the host `ssh-add -l` must list keys. If the user switched to 1Password's
SSH agent, OrbStack's socket path won't work — needs a different bridge,
not set up here.

### Tweaking

- **Loosen/tighten firewall:** edit `.devcontainer/init-firewall.sh`, rebuild.
- **Bump resource caps:** edit `--memory` / `--cpus` in `bin/yolo`.
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
