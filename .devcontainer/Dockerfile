FROM node:20

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Rootless podman single-UID mode workaround: apt drops privileges to the
# `_apt` user (uid 42) which doesn't exist in the namespace when the host
# lacks subuid/subgid ranges. Tell apt to stay as root. Harmless when
# proper subuid ranges are configured.
RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/no-sandbox

# Install basic development tools
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
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
  curl \
  openssh-client \
  ca-certificates \
  build-essential \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
# (.cache must exist node-owned *before* Docker mounts yolo-uv-cache onto .cache/uv,
#  otherwise Docker auto-creates /home/node/.cache as root and breaks writes.)
RUN mkdir -p /workspace /home/node/.claude /home/node/.cache /home/node/.config && \
  chown -R node:node /workspace /home/node/.claude /home/node/.cache /home/node/.config

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
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Install uv (Python package manager) system-wide before dropping to node user
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Install starship prompt (matches host shell prompt)
RUN curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir /usr/local/bin

USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
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
