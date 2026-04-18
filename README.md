# yolo-container

OrbStack container for running `claude --dangerously-skip-permissions` without
it being able to touch the Mac. One shared image, bind-mount whatever project
you `cd` into.

## Files

| File | Purpose |
|---|---|
| `.devcontainer/Dockerfile` | Node 20 + zsh + starship + git + gh + iptables + uv + Claude Code CLI |
| `.devcontainer/devcontainer.json` | Cursor/VS Code "Reopen in Container" config (builds the image) |
| `.devcontainer/init-firewall.sh` | Blacklist iptables rules (runs at container start) |
| `bin/yolo` | Terminal wrapper — `cd` anywhere, run `yolo` (symlink into `~/.local/bin/`) |

## Setup

```sh
brew install orbstack && open -a OrbStack   # one-time
git clone <this-repo-url> ~/code/yolo-container
ln -s ~/code/yolo-container/bin/yolo ~/.local/bin/yolo
# (~/.local/bin must be on PATH)
cd ~/code/some-project && yolo              # first run builds the image
```

The `yolo` wrapper self-locates the repo via the symlink, so you can clone
anywhere. The image bakes a `/Users/$HOST_USERNAME/.claude -> ~/.claude` symlink
so host-style paths in your `settings.json` resolve inside the container;
`HOST_USERNAME` defaults to `$(whoami)` at build time.

## Daily use

### Terminal (primary)

```sh
cd ~/code/some-project
yolo                                         # enters container at /workspace
claude --dangerously-skip-permissions
```

`$PWD` is bind-mounted live → edits flow both ways with the Mac.

### Cursor / VS Code — attach (recommended)

Zero per-project config. Extension: install **"Dev Containers"** (ms-vscode-remote).

1. Terminal: `cd ~/code/some-project && yolo`
2. Cursor: **Cmd+Shift+P** → `Dev Containers: Attach to Running Container` → pick `yolo-claude:latest`
3. In the attached window: **File → Open Folder → `/workspace`**
4. When done: close Cursor window (terminal still has the container). Exit terminal → container goes away.

### Cursor / VS Code — reopen (for projects you live in)

One-click open-in-container, but requires `.devcontainer/devcontainer.json` per
project. Only worth it if you use that project frequently.

Drop this as `project/.devcontainer/devcontainer.json`, identical to the canonical
one except it references the pre-built image instead of rebuilding:

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
    "source=${localEnv:HOME}/.dotfiles/starship.toml,target=/home/node/.config/starship.toml,type=bind,readonly",
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

Then: Cmd+Shift+P → `Dev Containers: Reopen in Container`.

## What's shared from the host

Read-only (host is source-of-truth; kernel rejects writes from container):

- `~/.claude/CLAUDE.md` — global instructions
- `~/.claude/settings.json` + `settings.local.json`
- `~/.claude/skills/`
- `~/.claude/statusline-command.sh`
- `~/.dotfiles/starship.toml` → container prompt matches host
- `~/.netrc` → wandb SDK auth
- `~/.gitconfig` → commits carry your name/email

Synced at container start (host → container one-way, just the MCP list):
- `mcpServers` block from `~/.claude.json` → container's `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`.
  Tokens travel; other runtime state does not.

Env forwarded from host: `WANDB_API_KEY`, `ANTHROPIC_API_KEY` (if set).

## Over-the-wall flow

If Claude inside the container wants to change something on the host (new skill,
updated settings, etc.) it can't — the mounts are kernel-level read-only. Its
instructions (in `~/.claude/CLAUDE.md`) tell it to write proposed changes to
`/workspace/_yolo_outbox/<file>` and give you a `cp` command to apply them on
the host.

## What's blocked / open

Firewall is **blacklist**. Blocked: `10/8`, `172.16/12`, `192.168/16`, `169.254/16`
(LAN + cloud metadata), SMTP ports 25/465/587. Everything else open.

## Persistent state (named Docker volumes)

| Volume | Holds |
|---|---|
| `yolo-claude-config` | `/home/node/.claude` — Claude login, runtime state |
| `yolo-uv-cache` | uv's package cache, shared across projects |
| `yolo-bashhistory` | zsh/bash history across sessions |
| anonymous (per-run) | `/workspace/.venv` — container's Linux venv, isolated from host's macOS venv |

List: `docker volume ls | grep yolo`. Nuke one: `docker volume rm <name>`.

## Sandbox guarantees

- **Root FS is read-only on mounted host paths** — `sudo chmod` fails with `EROFS` regardless of UID.
- **No sudo password** — node user can only `sudo /usr/local/bin/init-firewall.sh` (NOPASSWD whitelist). Everything else prompts for a password that doesn't exist.
- **No host creds mounted** — no SSH keys (agent forwarded, signing only), no AWS/GCP creds, no host `.credentials.json`.
- **Firewall** — blocks LAN and cloud metadata. Can't pivot to your router, NAS, printer, or cloud provider metadata endpoints.
- **Resource caps** — 8GB RAM, 4 CPUs (set in `yolo` wrapper).

## Common tasks

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

## Troubleshooting

**`yolo: docker CLI not found`** — `brew install orbstack && open -a OrbStack`.

**`Cannot connect to the Docker daemon`** — OrbStack app isn't running.

**Prompt is powerlevel10k, not starship** — Dockerfile should strip `ZSH_THEME` after zsh-in-docker; rebuild (`docker rmi yolo-claude:latest && yolo`).

**`claude: command not found`** — Debian's `/etc/zsh/zshenv` can reset PATH; Dockerfile appends npm-global to PATH in `.zshrc`. Rebuild.

**`[sudo] password for node:`** — You hit a `sudo` for something not whitelisted. Only `init-firewall.sh` is NOPASSWD; everything else fails. The node user has no password. Check the script that ran sudo.

**wandb MCP missing from `claude mcp list`** — MCP sync needs host `~/.claude.json` to exist and `CLAUDE_CONFIG_DIR` to resolve correctly. Check `cat ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json | jq .mcpServers` inside container; should show wandb.

**`echo x >> ~/.claude/CLAUDE.md` → Read-only file system** — working as intended (sandbox guarantee).

**Statusline path error** — settings.json often references host paths like `/Users/<your-username>/.claude/statusline-command.sh`. The image bakes a symlink `/Users/$HOST_USERNAME/.claude -> /home/node/.claude` (build arg defaults to your current host user) so those paths resolve inside the container. If you rename your host user, rebuild.

**Network request that should work is blocked** — Target might be on a private range. `getent hosts <host>` shows resolved IP. If in a blocked CIDR, edit `init-firewall.sh` to allow it before the REJECT rules, rebuild.

**SSH agent: "Could not open a connection to your authentication agent"** — `$SSH_AUTH_SOCK` inside container should be `/ssh-agent`. On host, `ssh-add -l` must list keys. If you switched to 1Password's SSH agent, the OrbStack socket path won't work — needs a different bridge, not set up here.

## Tweaking

- **Loosen/tighten firewall:** edit `.devcontainer/init-firewall.sh`, rebuild image.
- **Bump resource caps:** edit `--memory` / `--cpus` in `bin/yolo`.
- **Add a system package to base:** edit `.devcontainer/Dockerfile`'s `apt-get install` block, rebuild.
- **Per-project system deps:** drop a `.devcontainer/Dockerfile` in the project:
  ```dockerfile
  FROM yolo-claude:latest
  USER root
  RUN apt-get update && apt-get install -y libpq-dev && rm -rf /var/lib/apt/lists/*
  USER node
  ```
  Then `Dev Containers: Reopen in Container` from that repo picks up the local Dockerfile.

## What this doesn't protect against

- Malicious code can still exfiltrate anything it can reach: project files, `ANTHROPIC_API_KEY`, `WANDB_API_KEY`, contents accessible via the forwarded SSH agent (can *sign* but not read keys), anything in `~/.claude.json`'s MCP section that's been synced (including tokens).
- The firewall is a blacklist — anything not explicitly dangerous is fine, so most of the public internet is reachable.
- Only use with trusted code/repos. Convenience sandbox, not a security boundary for untrusted workloads.
