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

## Orchestrator-on-CPU

`~/start_claude_cpu.sh` (lives in the user's home, not this repo) holds a CPU
node on the `cpu` partition so Claude can run as a long-lived orchestrator and
launch GPU experiments via `cluster` — without ever holding a GPU itself. The
GPU jobs are independent `sbatch` jobs that survive if the orchestrator dies.
