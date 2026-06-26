# SLURM port — current status

Snapshot of where the `slurm-podman` branch port stands.
Last touched: 2026-06-26, on GPU node `ise-6000p-06.auth.ad.bgu.ac.il`
(8× RTX PRO 6000 Blackwell).

## TL;DR — it works now

`yolo` builds and runs on the cluster with no admin help and no subuid/subgid
ranges. Verified end to end on the GPU node: image builds, container starts,
`claude` runs, MCP servers sync from the host, and the GPU is visible inside
(`nvidia-smi -L` lists the Blackwell cards). The container runs **as root
inside** — which under rootless podman is just your unprivileged host uid
(`343964018`), not real root.

## The core constraint

This AD account has no subuid/subgid ranges, so podman uses single-UID mapping:

```
$ podman unshare cat /proc/self/uid_map
         0  343964018          1
```

Only one UID exists in the namespace (host uid → container uid 0). Everything
downstream follows from that. The "right fix" is still one line in `/etc/subuid`
+ `/etc/subgid` from the admins, but we don't need it — see the draft note at the
bottom if you ever want to file it.

## How the single-UID walls were cleared

There were two independent walls, both caused by the missing subuid ranges.

### 1. Build-time: apt postinst chowns (`.devcontainer/Dockerfile`)

`apt-get install` postinst scripts chown/chgrp files to GIDs that don't exist in
single-UID mode (`adm`, `shadow`, `man`, `_apt`, …). The real chown returns
`EINVAL` and aborts the install (`man-db` and `openssh-client` are the usual
first casualties).

Fix: run apt under **`fakeroot` with `FAKEROOTDONTTRYCHOWN=1`**. fakeroot
intercepts the chowns; the env var is the crucial part — without it fakeroot
*still issues the real chown first* and propagates its `EINVAL`, so plain
fakeroot is not enough. The Dockerfile bootstraps fakeroot, then wraps the heavy
apt install and the git-delta `dpkg -i` in it. `APT::Sandbox::User "root"` is
still needed too (keeps apt from dropping to uid 42 before fakeroot is in play).

### 2. Runtime: can't run as `node` (uid 1000)

The upstream image ran as `USER node`. In single-UID mode that's impossible —
`setresgid to 1000` fails with `Invalid argument`, so the container won't even
start. Only uid 0 is mappable.

Fix: the image runs **as root** (`USER node` dropped) with `HOME=/home/node` so
the existing config/volume layout and the `yolo` bind mounts still line up. The
old `chown node:node` build steps were removed (they'd fail the same way, and
root owns everything anyway). This means a prebuilt `USER node` image can't just
be `podman load`ed and run here either — note for anyone who revisits the
"build off-cluster" idea below.

### 3. Cosmetic: zsh privilege-drop warnings

Running zsh as root in a userns where `/proc/self/setgroups` is `deny` made the
fzf shell-integration scripts spam `can't drop privileges; failed to set
supplementary group list` on every prompt (their option save/restore re-applies
`privileged off`). Fixed by sourcing the fzf example scripts with `2>/dev/null`
and dropping the duplicate `fzf` oh-my-zsh plugin. Key bindings still work.

### 4. Unrelated `set -e` bug in `bin/yolo`

The `add_ro` helper returned non-zero when a host config file was missing (the
common case), which tripped `set -e` and aborted `yolo` before it ever launched
— with no error message. Fixed with a trailing `return 0`.

## Out-of-repo config (must exist on each node)

`~/.config/containers/storage.conf` points podman's graphroot/runroot at
node-local `/tmp/podman-gressel/` (NFS home can't do overlay xattrs) and sets
`ignore_chown_errors = "true"` so image *pulls* unpack in single-UID mode. This
file lives outside the repo and survives across branches. Because `/tmp` is
node-local, the first `yolo` run on each new node rebuilds the image (a few
minutes).

## Verified on this node

- Image builds clean end to end (`podman build .devcontainer/`).
- `yolo` runs: `gpu=devices` auto-detected, container starts as uid 0 with
  `HOME=/home/node`, `claude` (2.1.x) on PATH, MCP sync works.
- GPU passthrough via raw-device mode: device nodes + `/usr/lib64/libcuda.so*`
  / `libnvidia-ml.so*` bind-mounted, `nvidia-smi -L` works inside.
- `--security-opt label=disable` fine on this node.

## Still worth checking

- Other GPU node types / driver lib locations (here they're `/usr/lib64/`).
- CDI path (`--device nvidia.com/gpu=all`) is untested — this node has no
  `nvidia-ctk`, so `yolo` falls back to raw-device mode. Fine as is.
- SLURM-from-inside-container is still deliberately not wired; ssh back to the
  login node via the forwarded agent if Claude needs `squeue`/`sbatch`.

---

## If you ever want the "proper" fix (optional)

A one-line subuid/subgid range from admins would let the container run as a real
`node` user again and drop the fakeroot/root workarounds. Not required — the
current setup works — but here's the note:

> My AD account (`gressel`, uid `343964018`) has no subuid/subgid ranges, so
> rootless podman falls back to single-UID mapping. Standard fix is one entry
> each in `/etc/subuid` and `/etc/subgid` (or the SSSD-integrated equivalent),
> e.g. `usermod --add-subuids 200000-265535 --add-subgids 200000-265535 gressel`.

### Or build off-cluster and load

On a machine with working docker/podman:

```sh
podman build -t yolo-claude:latest .devcontainer/
podman save yolo-claude:latest | xz > yolo-claude.tar.xz
# scp to cluster, then: xz -d < yolo-claude.tar.xz | podman load
```

Note: build this branch's Dockerfile (root-mode). An upstream `USER node` image
won't start here (see wall #2).
