# syntax=docker/dockerfile:1
# check=error=true

# The agent devcontainer image: a Debian-family base, the engine's toolchain
# and fence, and a non-root `dev` user whose home is a named volume. The project
# adds its own packages in the marked sections below and nowhere else. See
# README.md for what to edit after copying this directory.

# --- project section: base image --------------------------------------------
#
# Any Debian-family image works — every install step below uses apt. A
# language-specific base (ruby:3.4-slim, python:3.13-slim) is the usual edit.
ARG BASE_IMAGE=debian:trixie-slim
# --- end of project section -------------------------------------------------

FROM $BASE_IMAGE

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# The engine's packages. Three groups, in one layer because they all track
# Debian stable and none of them has a currency the template follows:
#
# The fence: bind9-dnsutils (dig, the resolver probe), dnsmasq-base (the daemon
# without the packaged service — the fence starts and stops its own resolver),
# iproute2 (how the rules learn which subnets are directly connected), ipset,
# iptables, sudo (the two argument-scoped grants) and ulogd2 (denial logging).
#
# The baseline agents reach for: git with openssh-client as its SSH transport,
# curl, jq, ripgrep, fd-find, tree, unzip and file; python3 with pip and venv
# and python-is-python3, because the first `pip install` on a slim image fails
# without them.
#
# The shell and editor: zsh with its two plugins, fzf for its zsh key bindings
# (fuzzy Ctrl-R history, Ctrl-T files, Alt-C directories), neovim, ncurses-term
# for the extended terminfo entries the herdr TUI and nvim need inside its
# panes, less as the pager gh and git shell out to, procps for ps/pgrep
# (anything supervising processes reads a missing binary as "nothing
# running").
#
# ca-certificates and gnupg serve the repository setup below.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      bind9-dnsutils \
      ca-certificates \
      curl \
      dnsmasq-base \
      fd-find \
      file \
      fzf \
      git \
      gnupg \
      iproute2 \
      ipset \
      iptables \
      jq \
      less \
      ncurses-term \
      neovim \
      openssh-client \
      procps \
      python-is-python3 \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      sudo \
      tree \
      ulogd2 \
      unzip \
      zsh \
      zsh-autosuggestions \
      zsh-syntax-highlighting && \
    ln -s /usr/bin/fdfind /usr/local/bin/fd && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# node, the current LTS line, from NodeSource's per-major repository: it is the
# one uniform install channel for both harness CLIs (the bootstrap installs
# them with npm into the home volume), and whatever the project wants it for.
# The keyring form rather than NodeSource's setup script piped into a shell.
# A project that must not ship node deletes this one block.
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
      gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    chmod go+r /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y nodejs && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives && \
    node --version && npm --version

# gh, from GitHub's own repository: Debian's package trails it by too much.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y gh && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives && \
    gh --version

# yazi, the file manager. No Debian package, so: the tag from the
# /releases/latest redirect rather than the per-IP rate-limited api.github.com,
# download, verify, install and run in one layer so a failure can never cache
# as a success.
#
# yazi publishes no checksums file, so the pin is the sha256 digest GitHub
# itself prints for each asset on the release page, scraped out of the
# expanded_assets fragment. That is a real cross-origin check — the digest
# comes from github.com, the asset from the release CDN — and an empty scrape
# fails the build on `[ -n "$digest" ]` rather than quietly skipping
# verification. If upstream ever ships a checksums file, switch to it.
#
# The case is needed because yazi's assets are named after Rust target triples,
# not Debian architectures; the base is glibc, hence the -gnu builds. The zip
# also carries the `ya` companion CLI.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) target=x86_64-unknown-linux-gnu ;; \
      arm64) target=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported architecture for yazi" >&2; exit 1 ;; \
    esac; \
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://github.com/sxyazi/yazi/releases/latest | \
      sed 's|.*/tag/||')"; \
    tmp="$(mktemp -d)"; cd "$tmp"; \
    curl -fsSL -O \
      "https://github.com/sxyazi/yazi/releases/download/$tag/yazi-$target.zip"; \
    curl -fsSL -o assets.html \
      "https://github.com/sxyazi/yazi/releases/expanded_assets/$tag"; \
    digest="$(grep -oE \
      "clipboard-button-sha256:[0-9a-f]{64}\" aria-label=\"Copy to clipboard digest for yazi-$target\.zip\"" \
      assets.html | grep -oE '[0-9a-f]{64}')"; \
    [ -n "$digest" ]; \
    echo "$digest  yazi-$target.zip" | sha256sum -c; \
    unzip -q "yazi-$target.zip"; \
    install -m 0755 "yazi-$target/yazi" /usr/local/bin/yazi; \
    install -m 0755 "yazi-$target/ya" /usr/local/bin/ya; \
    cd /; rm -rf "$tmp"; \
    yazi --version; ya --version

# --- project section: packages ----------------------------------------------
#
# OS packages the project needs: native-extension build dependencies, browser
# libraries, database clients, a vendor's apt repository. The fence does not
# allowlist deb.debian.org, so apt cannot run inside a started container; an
# image rebuild (`devc rebuild`) is the only way to add an OS package. Shape:
#
# RUN apt-get update -qq && \
#     apt-get install --no-install-recommends -y \
#       build-essential \
#       libpq-dev && \
#     rm -rf /var/lib/apt/lists /var/cache/apt/archives
#
# --- end of project section -------------------------------------------------

# System-level configuration, under /etc so the home volume cannot shadow it:
# the shell defaults, the editor defaults, and the two sudoers grants. One COPY
# of the tracked tree; the modes sudoers needs are set below.
COPY etc/ /etc/

# The shell defaults are a file of their own, sourced from Debian's packaged
# /etc/zsh/zshrc so its terminfo key bindings stay. zsh sources this before
# ~/.zshrc, so the operator's own config runs after and wins.
#
# The rm disables zsh's first-run wizard: with none of ~/.zshenv ~/.zprofile
# ~/.zshrc ~/.zlogin present — exactly a home volume that has only ever run
# bash — the zsh/newuser module auto-sources that script and the
# zsh-newuser-install menu hijacks the first pane. Removing the script disables
# only the automatic entry point; the function stays callable by hand.
#
# Then the checks. BuildKit checks the Dockerfile, not the zsh it installs, so
# without these a typo ships and breaks every pane. `zsh -n` parses the rc; the
# interactive run then executes it — compinit, fzf's bindings and both plugin
# sources — and proves `y` came out a function and `g` an alias. The key
# probes pin what each key actually does once everything has loaded: fzf has
# to have won Ctrl-R, and the prefix history walk has to hold Ctrl-K, Ctrl-J
# and both arrows — a Debian rename of the fzf package, or a later source
# rebinding a key, would otherwise ship silently. Each probe prints "can't
# change option: zle" twice on stderr: fzf's script restores the options it
# found through eval, and zle cannot be switched on without a tty. It is
# noise, not a failure — the bindings land and the probes read stdout. The
# prompt needs the throwaway repository because its two failure modes are
# both invisible to a syntax check: vcs_info
# has to actually resolve a branch, and PROMPT has to still hold the reference
# *unexpanded* — lose PROMPT_SUBST or the quoting and it silently freezes at
# the shell's starting branch forever.
RUN rm -f /usr/share/zsh/*/scripts/newuser && \
    printf '\n# The devcontainer defaults; ~/.zshrc runs after this and wins.\nsource /etc/zsh/devcontainer.zshrc\n' \
      >> /etc/zsh/zshrc && \
    zsh -n /etc/zsh/zshrc && \
    zsh -n /etc/zsh/devcontainer.zshrc && \
    zsh -ic 'whence -w y' | grep -q 'function' && \
    zsh -ic 'whence -w g' | grep -q 'alias' && \
    zsh -ic 'bindkey "^R"' | grep -q 'fzf-history-widget' && \
    zsh -ic 'bindkey "^T"' | grep -q 'fzf-file-widget' && \
    zsh -ic 'bindkey "^K"' | grep -q 'up-line-or-beginning-search' && \
    zsh -ic 'bindkey "^J"' | grep -q 'down-line-or-beginning-search' && \
    zsh -ic 'bindkey "^[[A"' | grep -q 'up-line-or-beginning-search' && \
    zsh -ic 'bindkey "^[OA"' | grep -q 'up-line-or-beginning-search' && \
    zsh -ic 'bindkey "^[[B"' | grep -q 'down-line-or-beginning-search' && \
    zsh -ic 'bindkey "^[OB"' | grep -q 'down-line-or-beginning-search' && \
    zsh -ic 'print -r -- $PROMPT' | grep -qF '${vcs_info_msg_0_}' && \
    zsh -ic 'print -r -- $PATH' | grep -qF '/usr/local/sbin' && \
    tmp="$(mktemp -d)" && \
    git -C "$tmp" init -q -b main && \
    git -C "$tmp" -c user.name=build -c user.email=build@invalid \
      commit -q --allow-empty -m probe && \
    (cd "$tmp" && zsh -ic 'vcs_info; print -r -- $vcs_info_msg_0_') \
      | grep -qx '\[main\]' && \
    rm -rf "$tmp"

# The two NOPASSWD grants, and nothing else: the fence programs the packet
# filter and the volume repair chowns a mount point, so the dev user may run
# exactly those two root-owned programs, with exactly the arguments the files
# list. sudoers matches the command path literally, and the paths are in the
# image, so nothing writable from inside the container is ever escalated.
# Validated here on purpose — a malformed sudoers file has to fail the build
# rather than the first arm on a fresh container.
RUN chmod 0440 /etc/sudoers.d/dev-firewall /etc/sudoers.d/dev-own-volumes && \
    visudo -cf /etc/sudoers.d/dev-firewall && \
    visudo -cf /etc/sudoers.d/dev-own-volumes

# The engine's programs, root-owned in the image, and the allowlist the fence
# enforces. Syntax-checked at build: a broken fence script would otherwise be
# discovered by the compose command on first start, with egress open.
COPY sbin/dev-firewall sbin/dev-own-volumes /usr/local/sbin/
COPY bin/dev-bootstrap /usr/local/bin/
COPY firewall/allowlist /etc/dev-firewall/allowlist
RUN chmod 0755 /usr/local/sbin/dev-firewall /usr/local/sbin/dev-own-volumes /usr/local/bin/dev-bootstrap && \
    chmod 0644 /etc/dev-firewall/allowlist && \
    sh -n /usr/local/sbin/dev-firewall && \
    sh -n /usr/local/sbin/dev-own-volumes && \
    python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' /usr/local/bin/dev-bootstrap

# Non-root development user. Its home is a named volume in compose.yaml, so
# environment that must survive the volume shadowing image content goes in ENV
# below rather than in home dotfiles. /workspace is the bind-mount target and
# exists as dev's so a fresh container never sees it created as root's.
RUN groupadd --gid 1000 dev && \
    useradd dev --uid 1000 --gid 1000 --create-home --shell /usr/bin/zsh && \
    mkdir -p /workspace && \
    chown dev:dev /workspace

# SHELL is the load-bearing half of "the shell is zsh": herdr spawns its panes
# from SHELL and falls back to bare /bin/sh without it, and the exec path into
# the container passes no SHELL of its own. This is the environment variable,
# not the SHELL instruction: it does not change how RUN layers run.
#
# PATH leads with the home's bin, where the bootstrap installs the operator
# tools, and keeps /usr/local/sbin, where the fence and the volume repair live;
# the login shell's /etc/profile resets PATH for non-root users and would drop
# both, which /etc/zsh/devcontainer.zshrc then puts back for interactive shells.
#
# NPM_CONFIG_PREFIX makes a global npm install land under the home, so claude
# and codex update from inside the container without a rebuild. Their
# auto-update is held off through the harness's own switches, so versions move
# only when `dev-bootstrap --update-tools` is run.
ENV SHELL=/usr/bin/zsh \
    PATH=/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NPM_CONFIG_PREFIX=/home/dev/.local \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_UPDATES=1

# --- project section: mount points and environment --------------------------
#
# A named volume mounted inside the workspace needs its mount point to exist
# and belong to dev beforehand — otherwise Docker initialises the volume as
# root's — and a line in dev-own-volumes' VOLUMES list. Project-wide
# environment goes here too. Shape:
#
# RUN mkdir -p /workspace/node_modules && chown dev:dev /workspace/node_modules
# ENV BUNDLE_PATH=/home/dev/.bundle
#
# --- end of project section -------------------------------------------------

USER dev
