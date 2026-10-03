# syntax=docker/dockerfile:1
# check=error=true

# Development image for the devcontainer, and the only image this project
# builds: deployment runs on Render's native Ruby runtime, so there is no
# production image (see docs/infrastructure/deployment.md). This one carries the
# toolchain, not the app.

# Must match .ruby-version, which cannot be read from here — the base image is
# resolved before the build context is available.
# spec/config/version_consistency_spec.rb fails the build when this drifts, so a
# Ruby bump does not depend on anyone remembering this line.
ARG RUBY_VERSION=3.4.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim

# Runtime packages plus everything native gems need to build (pg,
# image_processing). Three of these serve the orchestration layer below, which
# slim ships without: procps for ps/pgrep (anything supervising processes reads
# a missing binary as "nothing running"), less as the pager gh and git shell
# out to, and ncurses-term for the extended terminfo entries the herdr TUI and
# nvim need inside its panes.
#
# dnsmasq-base, iproute2, ipset, iptables, sudo and ulogd2 are
# bin/dev-firewall's stack, and they sit in this runtime layer rather than in
# the floating tool layers below: the fence is infrastructure, so it must not
# move when TOOLS_EPOCH does. dnsmasq-base is the daemon without the packaged
# service — the fence starts and stops its own resolver — and iproute2 is how
# the rules learn which subnets are directly connected.
#
# openssh-client and jq are infrastructure by that same test. openssh-client is
# Git's SSH transport, and the primary checkout's remote is SSH, so fetch and
# push have to work on a clean rebuild and after a bare container restart. jq
# is the story workflow's JSON parser, which its preflight expects to find in a
# clean container. Neither has a currency the project tracks, so neither may
# move when TOOLS_EPOCH does.
#
# zsh and its two plugins are the account's interactive shell, which is
# infrastructure by the same test: it must not move or fail to build when
# TOOLS_EPOCH does, and all three track Debian stable.
#
# python-is-python3 supports agent-generated scripts that invoke `python`.
# Review sessions repeatedly try that name before falling back to `python3`.
#
# The lib*/fonts-* block is Chromium's shared-library and font closure, needed
# by the browser bin/setup downloads for system specs (ADR 0024). It belongs in
# this layer for two reasons: these packages track Debian stable like the rest
# of it, and the egress fence does not allowlist deb.debian.org — apt cannot
# run inside a started container, so an image rebuild is the only way to add an
# OS package and this layer must not churn when TOOLS_EPOCH does. The list is
# playwright-core's own `chromium` dependency set for debian13
# (`pnpm exec playwright install-deps --dry-run chromium`), stated in full even
# where another package already pulls one in transitively: Chromium's needs are
# not libvips's to satisfy. Deliberately dropped from that set: xvfb and
# xfonts-scalable, which serve a headed X server, and the CJK/Thai font
# packages, which no locale this app ships needs — fonts-unifont stays as the
# broad fallback so an unexpected glyph renders as something rather than tofu.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      curl \
      dnsmasq-base \
      fonts-freefont-ttf \
      fonts-liberation \
      fonts-noto-color-emoji \
      fonts-unifont \
      git \
      iproute2 \
      ipset \
      iptables \
      jq \
      less \
      libasound2t64 \
      libatk-bridge2.0-0t64 \
      libatk1.0-0t64 \
      libatspi2.0-0t64 \
      libcairo2 \
      libcups2t64 \
      libdbus-1-3 \
      libdrm2 \
      libfontconfig1 \
      libfreetype6 \
      libgbm1 \
      libglib2.0-0t64 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libpq-dev \
      libvips \
      libx11-6 \
      libxcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      libyaml-dev \
      ncurses-term \
      openssh-client \
      pkg-config \
      procps \
      python-is-python3 \
      sudo \
      ulogd2 \
      zsh \
      zsh-autosuggestions \
      zsh-syntax-highlighting && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# The PostgreSQL client tools, from the PGDG repository rather than Debian's
# `postgresql-client`, and pinned to the major of the `postgres` image in
# compose.yaml. Debian stable's client is one major behind that server, and
# `pg_dump` refuses to read a newer server's catalog outright — which is the
# fallback bin/story prepare needs when it copies brandeasy_development into a
# story's database while a console holds the template open. Infrastructure by
# the test above: a story cannot be prepared without it, so it must not move
# when TOOLS_EPOCH does, and a server bump in compose.yaml is when this line
# changes. The keyring lands where PGDG's own instructions put it.
RUN install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    chmod go+r /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "$VERSION_CODENAME")-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y postgresql-client-18 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Project shell defaults, appended to Debian's packaged /etc/zsh/zshrc so its
# terminfo key bindings stay. System rc, not a home dotfile: the home volume
# shadows image content under /home/dev. zsh sources this before ~/.zshrc, so
# the operator's own config runs after and wins.
#
# The rm disables zsh's first-run wizard: with none of ~/.zshenv ~/.zprofile
# ~/.zshrc ~/.zlogin present — exactly a home volume that has only ever run
# bash — the zsh/newuser module auto-sources that script and the
# zsh-newuser-install menu hijacks the first pane. Removing the script disables
# only the automatic entry point; the function stays callable by hand.
RUN rm -f /usr/share/zsh/*/scripts/newuser && \
    cat >> /etc/zsh/zshrc <<'EOF'

# Project defaults baked into the image; ~/.zshrc runs after this and wins.
# See docs/development/setup.md ("Shell, editor and clipboard").
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
# SHARE_HISTORY writes each command as it runs and imports other panes'; zsh
# documents INC_APPEND_HISTORY as the one to leave off when it is on.
setopt SHARE_HISTORY

autoload -Uz compinit && compinit

# Unguarded on purpose: a Debian rename should fail loudly in every shell
# rather than silently drop the feature. Highlighting sources last, as it
# documents.
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Prompt: user@host:cwd[branch]. The branch comes from zsh's own vcs_info, not
# a prompt framework or a `git branch` call in the prompt string — vcs_info is
# shipped with zsh, and as a precmd hook it queries git once per prompt rather
# than on every redraw. PROMPT_SUBST is what makes the ${...} re-expand each
# time; without it the branch would freeze at whatever it was when the shell
# started. Outside a repository vcs_info leaves the variable empty, so the
# brackets disappear rather than showing up blank.
autoload -Uz vcs_info add-zsh-hook
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:git:*' formats '[%b]'
zstyle ':vcs_info:git:*' actionformats '[%b|%a]'
add-zsh-hook precmd vcs_info
setopt PROMPT_SUBST
PROMPT='%n@%m:%~${vcs_info_msg_0_}%# '

# yazi's documented cd-on-quit wrapper, verbatim from its quick-start docs: it
# passes yazi a --cwd-file to write the directory it exited in, then cds there.
# Copied rather than adapted so it stays diffable against upstream; here in the
# system rc for the same volume-shadowing reason as the rest of this block.
function y() {
	local tmp cwd; tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
	command yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd" || builtin true
	command rm -f -- "$tmp"
}
EOF

# BuildKit checks the Dockerfile heredoc, not the zsh inside it, so without
# this a typo above ships and breaks every pane. `zsh -n` parses the whole rc;
# the interactive run then executes it — compinit and both plugin sources —
# and proves `y` came out a function. Root's .zcompdump and history land in the
# image's /root, which nothing uses.
#
# The prompt needs the throwaway repository below because its two failure modes
# are both invisible to a syntax check: vcs_info has to actually resolve a
# branch (a missing autoload or a mistyped zstyle just yields nothing), and
# PROMPT has to still hold the reference *unexpanded* — lose PROMPT_SUBST or
# the quoting and it silently freezes at the shell's starting branch forever.
RUN zsh -n /etc/zsh/zshrc && \
    zsh -ic 'whence -w y' | grep -q 'function' && \
    zsh -ic 'print -r -- $PROMPT' | grep -qF '${vcs_info_msg_0_}' && \
    tmp="$(mktemp -d)" && \
    git -C "$tmp" init -q -b main && \
    git -C "$tmp" -c user.name=build -c user.email=build@invalid \
      commit -q --allow-empty -m probe && \
    (cd "$tmp" && zsh -ic 'vcs_info; print -r -- $vcs_info_msg_0_') \
      | grep -qx '\[main\]' && \
    rm -rf "$tmp"

# Project editor defaults, same "/etc-level system config" placement as the zshrc
# above. /etc/xdg/nvim is on nvim's system runtimepath (via the default
# XDG_CONFIG_DIRS) and lives outside /home/dev, so the home volume cannot shadow
# it; the operator's own ~/.config/nvim is sourced first and the file's guard
# backs off to it. A plugin/ file rather than init-level config so it loads
# however nvim is invoked, with `nvim -u NONE` as the escape hatch.
RUN mkdir -p /etc/xdg/nvim/plugin && \
    cat > /etc/xdg/nvim/plugin/osc52-copy.lua <<'EOF'
-- Project default baked into the image; see docs/development/setup.md
-- ("Shell, editor and clipboard"). Copy-only OSC 52: yanks to the + / *
-- registers reach the attached terminal's clipboard. Register paste is
-- deliberately unsupported -- an OSC 52 read would hang or prompt, and a
-- local replay cache misleads (one cache per session, not per register) --
-- so "+p / "*p fail fast with E353 and pasting is the terminal's own
-- keystroke (Cmd-V). Set g:clipboard yourself (in ~/.config/nvim) and this
-- file backs off entirely.
if vim.g.clipboard ~= nil then
  return
end

local osc52 = require('vim.ui.clipboard.osc52')

-- The paste table is not optional: nvim rejects a g:clipboard without one
-- and the copy side stops working too. These callbacks are the minimal
-- lawful implementation -- non-blocking, never querying the terminal --
-- and their empty result makes nvim raise E353 ("Nothing in register") on
-- any register paste, which is the intended surfacing of "unsupported".
-- Only explicit "+p / "*p reach them: plain p reads the unnamed register,
-- which holds the yanked text even straight after a "+y, so ordinary
-- in-nvim yank/paste is untouched.
local function unsupported_paste()
  return { {}, '' }
end

vim.g.clipboard = {
  name = 'OSC 52 (copy only)',
  copy = {
    ['+'] = osc52.copy('+'),
    ['*'] = osc52.copy('*'),
  },
  paste = {
    ['+'] = unsupported_paste,
    ['*'] = unsupported_paste,
  },
}
EOF

# The NodeSource channel is per-major, so this restates .node-version's major
# and spec/config/version_consistency_spec.rb holds it to that. corepack resolves
# pnpm from the "packageManager" pin in package.json, so that version lives in
# one place already.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    corepack enable && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# The orchestration tools below carry no version pins: every build of their
# layers installs whatever is current. TOOLS_EPOCH is the trigger that makes a
# build re-run them — compose passes it from the environment, and a new value
# invalidates this layer and every layer under it:
#
#   TOOLS_EPOCH=$(date +%s) devcontainer up --workspace-folder . \
#     --remove-existing-container
#
# The recorded value doubles as the image's tool-install stamp.
ARG TOOLS_EPOCH=0
RUN echo "$TOOLS_EPOCH" > /etc/dev-tools-epoch

# apt tools. gh floats through GitHub's own repository; neovim tracks Debian
# stable, which is what the editor is for — basic editing inside the herdr
# panes, not a current-release nvim.
#
# file is yazi's MIME-detection prerequisite, which the slim base lacks —
# without it yazi cannot tell what it is previewing. unzip is here only to
# extract yazi's release zips in the layer below; the slim base ships no zip
# extractor at all.
#
# Deliberately NOT apt's `git-flow`: that package is the AVH edition, and this
# project runs git-flow-next, whose .git/config schema it does not understand
# (see docs/development/git-workflow.md). Installed from upstream below.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      file \
      gh \
      neovim \
      unzip && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# git-flow-next, which has no packaged channel: a Go binary from its GitHub
# releases, checked against the release's own checksums file. The tag comes from
# following the /releases/latest redirect rather than api.github.com, which is
# rate-limited per IP and would make builds fail in bursts. Debian's
# architecture names match the asset names, so this resolves per-arch by itself.
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://github.com/gittower/git-flow-next/releases/latest | \
      sed 's|.*/tag/||')"; \
    base="https://github.com/gittower/git-flow-next/releases/download/$tag"; \
    tmp="$(mktemp -d)"; cd "$tmp"; \
    curl -fsSL -O "$base/git-flow-next-$tag-linux-$arch.tar.gz"; \
    curl -fsSL -O "$base/git-flow-next-$tag-checksums.txt"; \
    sha256sum --ignore-missing -c "git-flow-next-$tag-checksums.txt"; \
    tar -xzf "git-flow-next-$tag-linux-$arch.tar.gz"; \
    install -m 0755 git-flow /usr/local/bin/git-flow; \
    cd /; rm -rf "$tmp"; \
    git flow version

# yazi, the file manager. No Debian package, so the same shape as
# git-flow-next above: tag from the /releases/latest redirect rather than the
# per-IP rate-limited api.github.com, download, verify, install and run in one
# layer so a failure can never cache as a success.
#
# Integrity differs though, because yazi publishes no checksums file and no
# per-asset .sha256: the pin is the sha256 digest GitHub itself prints for each
# asset on the release page, scraped out of the expanded_assets fragment. That
# is a real cross-origin check rather than hashing the bytes we just fetched —
# the digest comes from github.com, the asset from the release CDN
# (objects.githubusercontent.com). An empty scrape (GitHub renaming the
# fragment or relabelling the button) fails the build on `[ -n "$digest" ]`
# rather than quietly skipping verification. If upstream ever ships a checksums
# file, switch to it.
#
# The case is needed because yazi's assets are named after Rust target triples,
# not Debian architectures; the base is glibc, hence the -gnu builds. The zip
# also carries the `ya` companion CLI, which upstream ships as part of the
# distribution — both go in. Its shell completions are skipped: compinit's
# command completion covers the common case.
#
# No image previews, and so no chafa either. herdr's panes advertise the Kitty
# graphics protocol — the embedded libghostty answers yazi's probe with
# `kgp: true`, so yazi picks that adapter over any text-cell fallback — but the
# pixels do not survive herdr's pane compositing and previews come out blank.
# Forcing the fallback means naming a chafa previewer in a yazi config file,
# and yazi resolves config from one directory with no /etc/xdg layer (it reads
# only YAZI_CONFIG_HOME / XDG_CONFIG_HOME), so an image-owned config would take
# ~/.config/yazi away from the operator entirely rather than layering under it,
# the way the nvim default below layers. Judged not worth that for previews.
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

# The two harness CLIs, from the npm registry so both track one channel.
# NodeSource sets npm's global prefix to /usr, so these land root-owned in
# /usr/lib/node_modules with links in /usr/bin — which is what stops them
# updating themselves: the dev user cannot write the install, so the tools move
# only when this layer re-runs. Anthropic's apt repository is the documented
# fallback if the npm channel is ever dropped.
RUN npm install -g @anthropic-ai/claude-code @openai/codex && \
    npm cache clean --force

# herdr has no packaged channel on Linux, so the upstream installer it is. Not
# piped into a shell: a curl that fails mid-pipe leaves the layer green and
# cacheable without herdr. Downloading, installing and running the binary in
# one layer means a failure can never be cached as a success. Running as root
# also keeps the installer's PATH advice pointed at /root — the dev user's home
# volume never sees a dotfile from it.
RUN curl -fsSL https://herdr.dev/install.sh -o /tmp/herdr-install.sh && \
    HERDR_INSTALL_DIR=/usr/local/bin sh /tmp/herdr-install.sh && \
    rm /tmp/herdr-install.sh && \
    herdr --version

# Non-root development user. Its home is a named volume in compose.yaml, so
# environment that must survive the volume shadowing image content goes in ENV
# below rather than in home dotfiles.
RUN groupadd --gid 1000 dev && \
    useradd dev --uid 1000 --gid 1000 --create-home --shell /usr/bin/zsh

# The load-bearing half of "the shell is zsh": herdr spawns its panes from
# SHELL and falls back to bare /bin/sh without it, and the exec path into the
# container (`devcontainer exec`, how bin/dev-agent attaches) passes no SHELL of
# its own — so the image's ENV is the only place it can come from, and unlike a
# home dotfile it survives the volume shadowing. This is the environment
# variable, not the SHELL instruction: it does not change how RUN layers run.
ENV SHELL=/usr/bin/zsh

# The fence programs the packet filter and bin/dev-own-volumes chowns a volume
# mount point, so the dev user gets exactly two NOPASSWD grants — those two
# scripts and nothing else, which keeps casual sudo unavailable. sudoers matches
# the command path literally, and the path is the compose bind-mount target, so
# it is fixed: a worktree copy of either script escalates the primary one.
# One file per script rather than one file with two lines: the grants are
# independent, and a build that reaches only the first still says which.
# Validated in this layer on purpose — a malformed sudoers file has to fail the
# build rather than the first arm on a fresh container.
RUN printf '%s\n' \
      'dev ALL=(root) NOPASSWD: /workspaces/brandeasy/bin/dev-firewall' \
      > /etc/sudoers.d/dev-firewall && \
    chmod 0440 /etc/sudoers.d/dev-firewall && \
    visudo -cf /etc/sudoers.d/dev-firewall && \
    printf '%s\n' \
      'dev ALL=(root) NOPASSWD: /workspaces/brandeasy/bin/dev-own-volumes' \
      > /etc/sudoers.d/dev-own-volumes && \
    chmod 0440 /etc/sudoers.d/dev-own-volumes && \
    visudo -cf /etc/sudoers.d/dev-own-volumes

# Gems land on the home volume: off the bind mount, and kept across rebuilds.
# Deliberately no BUNDLE_BIN and no binstub directory on PATH: generated
# binstubs hardcode the Gemfile path of whichever checkout ran bundle install
# last, and this container hosts several checkouts sharing one home — a shared
# binstub directory lets any of them pin the others (ADR 0019,
# docs/decisions/0019-no-shared-bundler-binstubs.md). Bare `bundle` falls
# through to the system Bundler, which resolves the Gemfile from the current
# directory; other gem commands enter through the repo's bin/ wrappers or
# `bundle exec`.
ENV BUNDLE_PATH=/home/dev/.bundle

# No tool updates itself in place. Root ownership of the install trees is what
# enforces that; this only silences claude's attempts to try. It blocks every
# update path, `claude update` included — DISABLE_AUTOUPDATER would stop the
# background check alone.
ENV DISABLE_UPDATES=1

# node_modules is a named volume in compose.yaml (host and container need
# different platform binaries). A fresh named volume takes its ownership from
# the image, so the mount point has to exist and belong to dev beforehand —
# otherwise it initialises as root and pnpm cannot write to it.
#
# Build-time ownership can only ever be 1000:1000, which stops being dev's on a
# Linux host whose user is not UID 1000: the CLI's UID remap rewrites the dev
# account and chowns its home, and leaves every other mount point behind.
# bin/dev-own-volumes reconciles that at create time, through the grant above.
RUN mkdir -p /workspaces/brandeasy/node_modules && \
    chown -R dev:dev /workspaces

USER dev
