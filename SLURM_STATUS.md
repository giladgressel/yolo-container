# SLURM port — current status

Snapshot of where the `slurm-podman` branch port stands.
Last touched: 2026-04-18, on login node `slurm-login-02.auth.ad.bgu.ac.il`.

## What's done

- `bin/yolo` rewritten for rootless podman: `$SSH_AUTH_SOCK` direct, GPU
  auto-detect (CDI → /dev/nvidia* + driver libs → none), no NET_ADMIN,
  `--security-opt label=disable` for RHEL9 SELinux, `YOLO_ENGINE`
  override.
- Dockerfile: dropped iptables/ipset/firewall sudoers. Swapped
  `/Users/$HOST_USERNAME` → `/home/$HOST_USERNAME` symlink. Added
  `openssh-client` so Claude can ssh back to the login node for
  `squeue` / `sbatch`.
- `.devcontainer/init-firewall.sh` deleted.
- `devcontainer.json` updated to match.
- README rewritten around the ssh-into-compute-node workflow
  (`~/rtx6000pro_golden.sh` sleep-job trick).
- Committed as `fed84ba` on `slurm-podman`. Not pushed.
- `yolo` symlinked into `~/.local/bin/yolo`.
- Out-of-repo config (survives across this repo's history):
  `~/.config/containers/storage.conf` created to move graphroot/runroot
  to `/tmp/podman-gressel/` (NFS home can't do overlay xattrs). Includes
  `ignore_chown_errors = "true"` so image *pulls* succeed.

## What's blocked

**The image won't build.** We have no subuid/subgid ranges, so podman
uses single-UID mapping (host uid → container uid 0, everything else =
invalid). `apt-get install` during the build chowns postinst files to
non-zero GIDs (`adm`, `_apt`, `mail`, etc.) — those fail with `Invalid
argument`. `ignore_chown_errors` only covers layer unpack, not runtime
apt operations.

A workaround commit (`Dockerfile` line: `APT::Sandbox::User "root"`) got
us past apt's initial privilege drop, but the next chown (e.g. from
`man-db` postinst) still fails. Patching every postinst is not viable.

## What to do next

### Option 1 — file a ticket (the right fix)

Send cluster admins the note below. Standard one-line config. After this
the branch should "just work" (assuming GPU passthrough behaves on the
compute node — that's the next thing to test).

### Option 2 — build the image off-cluster and load it here

On a machine with working docker/podman (laptop, another cluster, CI):

```sh
git clone https://github.com/giladgressel/yolo-container.git
cd yolo-container && git checkout slurm-podman
podman build -t yolo-claude:latest .devcontainer/
podman save yolo-claude:latest | xz > yolo-claude.tar.xz
# scp to cluster, then on cluster:
xz -d < yolo-claude.tar.xz | podman load
```

Pre-built images unpack (with `ignore_chown_errors`) and run fine in
single-UID mode — only builds hit the chown wall.

## Stuff that's still speculative, to verify once unblocked

- `--security-opt label=disable` — fine on this login node, may need
  tweaking on compute nodes depending on per-node SELinux policy.
- GPU passthrough — untested. Auto-detect code paths are in
  `bin/yolo`, but `/dev/nvidiactl` only exists on compute nodes. Run
  `yolo` there and watch for `gpu=devices` in the `yolo:` banner.
- Driver userspace libs live at `/usr/lib64/libcuda.so*` on this
  cluster — verified on login node paths but not on the actual GPU
  nodes (which may use `/usr/lib64/nvidia/` or elsewhere). Check with
  `ls /usr/lib64/libcuda* /usr/lib64/libnvidia-ml*` on a GPU node.
- SLURM-from-inside-container deliberately not wired. If Claude needs
  `squeue`, it ssh's back to the login node via forwarded agent.

---

## Draft ticket to admins

Subject: **Rootless podman — need subuid/subgid ranges for my AD account**

Hi,

I'd like to use rootless `podman` on the cluster (tested from
`slurm-login-02`). Right now my AD account (`gressel`, uid
`343964018`) has no subuid/subgid ranges, so podman falls back to
single-UID mapping. That breaks image builds: `apt-get install`
postinst scripts chown to non-root GIDs (`_apt`=42, `adm`=4, etc.)
which aren't in the namespace, and the install errors out with
`Invalid argument`.

Confirming:

```
$ getsubids gressel
Error fetching ranges

$ getsubids -g gressel
Error fetching ranges

$ grep gressel /etc/subuid /etc/subgid
(no output)

$ podman unshare cat /proc/self/uid_map
         0  343964018          1
```

The standard fix is a one-line entry each in `/etc/subuid` and
`/etc/subgid` (or an AD/SSSD-integrated equivalent). For example:

```
gressel:200000:65536
```

or the usermod equivalent:

```
usermod --add-subuids 200000-265535 --add-subgids 200000-265535 gressel
```

After that, `newuidmap` / `newgidmap` can set up a proper user
namespace mapping (65k UIDs) and regular rootless podman image builds
should work. Happy to test whenever it's in place. If this needs to be
applied more broadly than just my account (e.g. via an SSSD override
template), let me know and I can coordinate.

Thanks!
