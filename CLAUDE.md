# yolo-container — notes for Claude

Humans read README.md's "For the human" section. Everything else (and this
file) is for you, the coding agent maintaining this setup.

## SLURM from inside the container (added 2026-06-29)

The image has **no slurm client** by design. To submit/check jobs from inside a
yolo container, use the **`cluster`** wrapper (`bin/cluster`): it ssh'es to the
login node over the forwarded ssh-agent and runs slurm there.

```sh
cluster squeue --me
cluster sacct -j <id>
cluster bash batch_submit.sh --gpu pro runs/exp.sh   # run from the project dir
cluster scancel <id>
```

- **Per-user config, uncommitted:** `~/.config/yolo/cluster.env` holds
  `YOLO_SLURM_LOGIN`, `YOLO_SLURM_USER`, `YOLO_SLURM_KEY` (the agent-key comment;
  quote it — it has spaces). See `cluster.env.example` and README → "SLURM from
  inside the container". `bin/yolo` sources it and forwards it in. The SSH key
  itself never leaves the agent.
- **Path translation:** `bin/yolo` forwards `YOLO_WS_HOST=$PWD`, so `cluster`
  rewrites `/workspace/...` (container) → the real NFS path. Jobs run on compute
  nodes where `/workspace` doesn't exist, so always submit via `cluster`, which
  cds to the NFS path first.
- **If `cluster` (or `git push`) fails** with `error in libcrypto` /
  `Permission denied`, the **forwarded ssh-agent is dead** (stale tmux socket or
  a reconnect from another client). Fix: reconnect with agent forwarding,
  confirm `ssh-add -l` lists your key, then re-run `yolo`. `cluster` now
  preflights this and prints a clear message.

## State that must survive node hops lives on NFS (added 2026-07-04)

Podman's graphroot is on node-local `/tmp` (overlay can't run on NFS), and
**named volumes live inside the graphroot** — so a named volume is silently
node-local on this cluster. Anything that must survive moving to another node
is therefore an NFS bind mount under `~/.local/state/yolo/` (override:
`YOLO_STATE_DIR`): `claude/` (login + `.claude.json` + sessions → mounted at
`/home/node/.claude`) and `bashhistory/`. The image is cached as a
`podman save` tarball at `~/.local/state/yolo/yolo-claude-image.tar` — new
nodes `podman load` it (~1 min) instead of rebuilding; `yolo --update` and
first builds refresh it (`YOLO_IMAGE_CACHE=0` disables). uv caches stay in
named volumes on purpose (pure caches; uv hardlinks don't play well with NFS).
After editing the Dockerfile, `rm` the tarball too or the next node loads the
stale image (README → "Common tasks").

## Rootless podman on compute nodes (added 2026-07-01)

`yolo`'s build/run fails on a fresh compute node until the user has per-user
`~/.config/containers/{storage.conf,containers.conf}` — SSH-adopted
compute-node sessions have no systemd-logind session, so podman's default
`/run/user/$UID` state dir, `journald` events logger, and `systemd` cgroup
manager all fail. The tell-tale: `sd-bus call: Interactive authentication
required` at a `RUN`/create step (missing `cgroup_manager = "cgroupfs"`), or
`mkdir /run/user/$UID: permission denied` (missing `tmp_dir`). Full explanation
+ the exact file contents are in README → **Rootless podman on compute nodes**.
`~/.config` is NFS-shared, so writing them once covers every node.

## Orchestrator-on-CPU

`~/start_claude_cpu.sh` (lives in the user's home, not this repo) holds a CPU
node on the `cpu` partition so Claude can run as a long-lived orchestrator and
launch GPU experiments via `cluster` — without ever holding a GPU itself. The
GPU jobs are independent `sbatch` jobs that survive if the orchestrator dies.
