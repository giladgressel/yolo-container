FROM node:20

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Rootless podman single-UID mode workaround, part 1: apt drops privileges to
# the `_apt` user (uid 42) which doesn't exist in the namespace when the host
# lacks subuid/subgid ranges. Tell apt to stay as root. Harmless when proper
# subuid ranges are configured.
RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/no-sandbox

# Rootless single-UID mode workaround, part 2: bootstrap fakeroot.
# Package postinst scripts chown/chgrp files to GIDs that don't exist in
# single-UID mode (adm, shadow, man, ...); the real chown then fails with
# EINVAL and aborts the install (man-db, openssh-client are the usual
# offenders). Running apt under `fakeroot` with FAKEROOTDONTTRYCHOWN=1 makes
# those calls fake success without ever touching the kernel. Note: plain
# `fakeroot` is not enough — by default it still issues the real chown and
# propagates its EINVAL; FAKEROOTDONTTRYCHOWN=1 is what skips it. Harmless
# when proper subuid ranges are configured (chowns just get faked instead of
# applied, which this image doesn't depend on).
RUN apt-get update && apt-get install -y --no-install-recommends fakeroot \
  && rm -rf /var/lib/apt/lists/*

# Install basic development tools (see fakeroot note above)
RUN apt-get update && FAKEROOTDONTTRYCHOWN=1 fakeroot apt-get install -y --no-install-recommends \
  less \
  git \
  git-lfs \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iproute2 \
  dnsutils \
  jq \
  nano \
  vim \
  tmux \
  curl \
  openssh-client \
  ca-certificates \
  build-essential \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Register the git-lfs filter system-wide so repos with `filter=lfs` in
# .gitattributes work without each user/repo running `git lfs install`.
# Without this, git status hashes the raw blob (slow on large files) and
# reports clean LFS-tracked files as "modified" because the working-copy
# content's SHA doesn't match the stored LFS pointer's SHA in the index.
RUN git lfs install --system --skip-repo

# Single-UID note: with no subuid/subgid ranges the container can only run as
# one UID (host uid -> container uid 0 = root), so this image runs as root
# throughout. Running as root inside a rootless container is unprivileged on the
# host. That removes the need for the `node`-ownership chowns the upstream image
# used (a `chown node:node` would also fail with EINVAL here) — root owns
# everything by default. HOME is pointed at /home/node so the config/volume
# layout below (and the yolo bind mounts) still line up.
RUN mkdir -p /usr/local/share/npm-global

ARG USERNAME=node

# Persist bash history.
RUN mkdir /commandhistory && touch /commandhistory/.bash_history

ENV DEVCONTAINER=true
ENV HOME=/home/node

# Create workspace and config directories. The exact named-volume mount paths
# (.cache/uv, .local/share/uv) are pre-created so the engine mounts onto an
# existing dir rather than auto-creating it. The .local/share/uv volume persists
# uv-managed Python interpreters so uv doesn't re-download CPython every run.
RUN mkdir -p /workspace /home/node/.claude /home/node/.cache/uv \
             /home/node/.local/share/uv /home/node/.config

# Pre-populate known_hosts so git push/pull over ssh works on first use.
# The forwarded ssh-agent authenticates the user; known_hosts authenticates the
# server. Without it ssh aborts before offering keys and it looks like an auth
# failure but isn't.
#
# Write to the SYSTEM-WIDE known_hosts (/etc/ssh/ssh_known_hosts), not
# ~/.ssh/known_hosts. ssh locates the per-user file via the passwd-DB home
# (getpwuid), not $HOME — and single-UID mode forces this container to run as
# root (home /root), so a file under /home/node/.ssh would never be consulted.
# The global file is checked for every user regardless of UID/home, so this
# works both in root mode here and as `node` if subuid ranges are ever added.
RUN mkdir -p /etc/ssh && \
  ssh-keyscan -t ed25519,rsa,ecdsa github.com >> /etc/ssh/ssh_known_hosts && \
  chmod 644 /etc/ssh/ssh_known_hosts

# Host-style path symlink: settings.json often references the host path
# (e.g. /home/$HOST_USERNAME/.claude/statusline-command.sh). Create the symlink
# at build time so runtime needs no sudo. Defaults to current host user.
ARG HOST_USERNAME=user
RUN if [ "${HOST_USERNAME}" != "node" ]; then \
      mkdir -p "/home/${HOST_USERNAME}" && \
      ln -sfn /home/node/.claude "/home/${HOST_USERNAME}/.claude"; \
    fi

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
# fakeroot here too (sudo would strip the LD_PRELOAD; we're already root in the
# build anyway). See the fakeroot note near the top of this file.
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  FAKEROOTDONTTRYCHOWN=1 fakeroot dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Install uv (Python package manager) system-wide
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Install starship prompt (matches host shell prompt)
RUN curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir /usr/local/bin

# NB: no `USER node` — single-UID mode can't run as uid 1000 (setresgid would
# fail with EINVAL), so everything below runs as root with HOME=/home/node.
# zsh-in-docker therefore writes /home/node/.zshrc, which the sed step expects.

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# fzf integration: we source the example scripts directly (with `2>/dev/null`)
# and deliberately do NOT enable the `fzf` oh-my-zsh plugin, which would source
# them a second time unredirected. As root (forced by single-UID mode) their
# option save/restore re-applies `privileged off`, which makes zsh attempt a
# setgroups privilege-drop that the rootless userns denies — harmless, but it
# spams a warning on every shell start. The redirect silences that startup
# restore; the key bindings (Ctrl-R / Ctrl-T / Alt-C, ** completion) still install.
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh 2>/dev/null" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh 2>/dev/null" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -a "export PATH=\"\$PATH:/usr/local/share/npm-global/bin\"" \
  -a "command -v starship >/dev/null && eval \"\$(starship init zsh)\"" \
  -a "alias cg='claude --dangerously-skip-permissions'" \
  -x

# Strip p10k theme so starship owns the prompt. zsh-in-docker 1.2.0 defaults
# to powerlevel10k and its precmd hook overrides starship if ZSH_THEME is set.
RUN sed -i 's|^ZSH_THEME=.*|ZSH_THEME=""|' /home/node/.zshrc

# Install Claude
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
