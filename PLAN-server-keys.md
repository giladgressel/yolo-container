# TEMP PLAN — server-resident SSH key for detached operation

**Status:** design agreed, not yet implemented. Finish on the cluster.
**Delete this file once the work is done and folded into README / SLURM_STATUS.md.**

## Problem

Usual pattern: `ssh compute-node` → `tmux` → `yolo` → `cg`. Works while connected.
But when the laptop detaches / lid closes:

1. **SSH agent forwarding dies.** `bin/yolo:216-223` mounts the *forwarded* agent
   socket into the container. That socket is borrowed from the laptop — when the
   laptop leaves, there's nothing to borrow. Result: the agent can no longer
   manage jobs (`cluster …`) or `git push`. Managing jobs is the painful one.
2. **Reconnect glitch (separate):** on reconnect the forwarded socket is stale and
   tmux has to be restarted. The `agent.sock` symlink (commit 67b364b) re-points
   at a live agent but can't invent one when the laptop is off.

No forwarding scheme can fix #1 — a forwarded agent is *defined* by the laptop
being present. The credential has to live on the server.

## Threat-model context (already decided)

- yolo on the cluster exists to contain an **accidental** haywire agent — the
  realistic failure is local thrash (wrong `rm`, filled disk), which the
  container + explicit mounts already confine.
- We deliberately **keep the blast radius open** for deliberate actions: the agent
  can ssh to the login node and submit jobs as the user. That capability is wanted
  (it debugs/loops far faster than by hand). See the `cluster` helper discussion.
- Consequence for this plan: a server-resident key is a **standing credential
  inside the blast radius**, usable even when nobody's watching. That's consistent
  with the open-radius choice. We keep it simple rather than over-scoping.

## The fix — ONE server-resident key, set-and-forget

Generate a single passphrase-less keypair **on the cluster** (born there, so the
private half never travels the network; revocable independently of laptop keys).
Register its public half in two places:

1. `~/.ssh/authorized_keys` on the cluster  → container → login-node ssh for slurm.
   (NFS home is shared between login + compute nodes, so one file covers both.)
2. GitHub account  → `git push` works for all repos, like the laptop does today.

Compute node has confirmed outbound to GitHub, so push-over-the-internet from the
container works directly — no routing through the login node needed.

Passphrase-less is required (unattended use) and matches the "never type a
password" preference. Protect with `chmod 600`; that's the only secret.

**Explicitly NOT doing:** per-repo deploy keys / one-key-per-repo. Considered as a
tightening, rejected as not worth the hassle and inconsistent with the already-open
blast radius. Account-wide key is fine. (Revisit only if the threat model changes.)

## Implementation (finish on the cluster)

### One-time setup on the cluster (commands to run there)

```sh
# 1. Generate the key on the cluster (no passphrase)
ssh-keygen -t ed25519 -f ~/.ssh/yolo_server -N "" -C "yolo-server-$(hostname)"

# 2. Authorize it for compute -> login ssh (same NFS home = both nodes)
cat ~/.ssh/yolo_server.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 3. Add ~/.ssh/yolo_server.pub to GitHub (Settings -> SSH keys), or via gh:
#    gh ssh-key add ~/.ssh/yolo_server.pub --title "yolo-server"
```

### Code changes (in this repo)

1. **`bin/cluster`** — add a *keyfile mode*. If `YOLO_SLURM_KEYFILE` is set, use
   `ssh -i "$YOLO_SLURM_KEYFILE" -o IdentitiesOnly=yes` and skip the agent-key
   pinning / `ssh-add -l` preflight entirely. Keep the current forwarded-agent path
   as fallback when the keyfile is absent, so nothing breaks for the connected case.

2. **`bin/yolo`** — mount the private key into the container read-only (via the
   `add_ro` block) and forward its in-container path. Keep the existing agent-socket
   mount too; server key is used when present, agent when not.
   - decide container path, e.g. `/home/node/.ssh/yolo_server`
   - forward `YOLO_SLURM_KEYFILE=<that path>`

3. **`git push` inside the container** — make git use the server key. Cleanest:
   an in-container `~/.ssh/config` Host block for github.com pointing at
   `IdentityFile /home/node/.ssh/yolo_server` + `IdentitiesOnly yes`, OR set
   `GIT_SSH_COMMAND`. (Remote must be the SSH form `git@github.com:...`, not HTTPS.)

4. **`cluster.env.example`** — document `YOLO_SLURM_KEYFILE` (path to the mounted
   key) as the preferred alternative to `YOLO_SLURM_KEY` (agent comment).

### Verify on the cluster

- With the laptop **disconnected** (detach tmux, close lid, reconnect later):
  `cluster squeue --me` still works, `git push` still works.
- Confirm the old forwarded-agent path still works when connected (fallback intact).

## Also reconcile while here (stale docs)

`SLURM_STATUS.md:112-113` still says "SLURM-from-inside-container is still
deliberately not wired" — but `bin/cluster` (commits cc2a082 / fc070a6) wired it.
Update that section, and fold the server-key outcome into README + SLURM_STATUS.md
once implemented. Then delete this PLAN file.
