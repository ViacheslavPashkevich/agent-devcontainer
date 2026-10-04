# Agent devcontainer

A container in which coding agents — Claude Code and Codex, driven through
herdr — run unattended, with permissions bypassed, behind an egress fence. The
fence is the safety layer; the harness posture is not.

**Read this first.** The bootstrap writes `bypassPermissions` into claude's
settings and `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`
into codex's. It refuses to run outside a container, and that guard is the only
thing between this posture and your own home directory. Never copy
`bin/dev-bootstrap` somewhere it could run on a host, and never remove the
sentinel check.

This directory is a copy. The model is shadcn's: your project owns these files,
edits them, and takes later template changes as a diff. There is no runtime
dependency on the template repository. `TEMPLATE` records where the copy came
from and at which ref.

## What is in the box

Engine, present in every copy:

- Debian base by default, overridable to any Debian-family image.
- A non-root `dev` user; its home on a named volume, so logins, tools and
  history survive restarts, recreates and rebuilds; the project bind-mounted at
  the fixed `/workspace`.
- zsh with a prompt and shared history, nvim defaults, yazi — configured under
  `/etc`, so the home volume cannot shadow it and your own dotfiles run after
  and win.
- python3 with pip and venv (and `python` → `python3`), node LTS, git, gh,
  openssh-client, curl, jq, ripgrep, fd, tree, unzip, file. `LANG=C.UTF-8`.
- claude, codex and herdr, installed into the home volume by the bootstrap and
  updated from inside the container.
- The egress fence: default-deny outbound traffic, a domain allowlist fed by a
  container-local resolver, denial logging annotated with the domain each
  denial was aimed at, log rotation. Armed on every container start.
- sudo with exactly two argument-scoped grants, and nothing else.
- `devc`, the host-side entry point; `dev-bootstrap`, `dev-firewall` and
  `dev-own-volumes` inside; their stub suites and smoke checks.

Deliberately excluded:

- **The docker socket.** It would let an agent start containers outside the
  fence.
- **An ssh server in the container.** Remote access is ssh to the host, then
  `devc`.
- **A dotfiles manager.** The home volume persists whatever you put there.

## Host prerequisites

Docker (Desktop or docker-ce) with Compose ≥ 2.24, and the devcontainer CLI:

    npm install -g @devcontainers/cli

`devc doctor` checks all of this.

## Copying into a project

1. Copy this directory into the project as `.devcontainer/`. Set `ref:` in
   `TEMPLATE` to the template tag you copied. Commit.
2. Edit the marked places — see the next section.
3. Copy `env.example` to `.env` and fill in what you want seeded. `.env` is
   gitignored by the `.gitignore` in this directory.
4. Run `.devcontainer/host/devc`. The first start builds the image, creates the
   container, bootstraps the home (operator tools, herdr integrations, harness
   posture, git identity, ssh key), arms the fence and attaches.

A shorter path to `devc` is the project's business: a one-line shim in its own
`bin/` (`exec "$(dirname "$0")/../.devcontainer/host/devc" "$@"`). The
template does not reach outside this directory.

## What to edit after copying

Every project-specific place is marked `project section` in the file, and
there are no others. Everything outside those sections is the engine, which
you can of course still change — it is your copy — but which the upgrade
procedure below expects to find as the template left it.

| File | Section | What goes there |
| --- | --- | --- |
| `Dockerfile` | base image | `ARG BASE_IMAGE=…` — any Debian-family image, typically a language image. |
| `Dockerfile` | packages | OS packages: build dependencies, browser libraries, database clients, a vendor's apt repository. |
| `Dockerfile` | mount points and environment | A `mkdir`+`chown` per named volume mounted inside the workspace; project-wide `ENV`. |
| `compose.yaml` | mounts | Named volumes inside the workspace, inside the engine's `volumes:` list. |
| `compose.yaml` | the app service | Ports (loopback only), environment, `depends_on`. |
| `compose.yaml` | services | Databases, caches. Service names resolve from inside the container. |
| `compose.yaml` | volumes | The named volumes the two sections above refer to. |
| `firewall/allowlist` | whole file | The domains the project needs to reach. Roughly half of a real project's list is project-specific. |
| `sbin/dev-own-volumes` | `VOLUMES=` | One entry per named volume mounted inside the workspace. |
| `env.example` | project section | The variables the project's own tooling reads. |
| `devcontainer.json` | `name` | Cosmetic. |

Two constraints are not up for editing: the base must be Debian-family,
because every install step uses apt; and the workspace path is `/workspace`,
because the privileged scripts hardcode it instead of discovering it.

## Daily use

    devc                        up, then attach          (the daily path)
    devc up                     start if not running, do not attach
    devc attach                 attach only; fails plainly if not running
    devc stop                   stop the compose project, keep volumes

    devc rebuild                rebuild from scratch, recreate, attach

    devc firewall status        what is enforced, the allowlist, recent denials
    devc firewall on            re-arm
    devc firewall off           lift enforcement, as root inside the container
    devc firewall allow <domain>
                                append to firewall/allowlist, push into the
                                container, re-arm

    devc exec <command...>      run a command inside, as dev
    devc doctor                 host prerequisites, then dev-bootstrap --doctor inside

One verb per invocation; flags only modify a verb; nothing privileged happens
implicitly. `firewall off` and `firewall allow` are the only verbs that run as
root inside the container. Over ssh to a remote host, everything is the same.

`devc attach` runs herdr. If herdr is missing it fails plainly and points at
`devc exec zsh` and `devc doctor`, because a missing herdr means the bootstrap
did not finish; there is no silent fallback to a shell. A project that wants a
plain shell as its attach command changes the `ATTACH=` line at the top of
`host/devc`.

### First-time logins

The bootstrap cannot log in for you. After the first `devc`:

- claude: start `claude`, run `/login`.
- codex: `codex login --device-auth` — the device flow, because the default
  browser callback targets a container port nothing publishes.
- ssh: the bootstrap generated `~/.ssh/id_devcontainer` (RSA-4096, no
  passphrase) and configured github.com to use it. Register the public key with
  GitHub, then connect once by hand so you can check the fingerprint.

All of this lives in the home volume, so it is once per machine, not once per
container. `devc doctor` lists what is still missing, each with its fix.

## The fence

Outbound traffic is default-deny. The container's own dnsmasq is the only
resolver an unprivileged process can reach, and as it answers queries for
allowlisted domains it feeds their addresses into an ipset the packet filter
accepts; everything else is rejected — rejected, not dropped, so a denial fails
in milliseconds instead of hanging an agent for the TCP timeout. Each denial is
logged, and `status` annotates it with the domain it was aimed at.

The allowlist is `firewall/allowlist`: one domain suffix per line, matching
every subdomain, with `#` comments. The Dockerfile copies it into the image at
`/etc/dev-firewall/allowlist`, root-owned and world-readable. The flow is
strictly one way, repo → image → running container; nothing flows back.

**A blocked domain:** `devc firewall status` shows the denial with its domain.
If it should be allowed, `devc firewall allow <domain>` appends it to the
tracked file, pushes the file into the running container and re-arms — live
connections survive the re-arm — then commit the allowlist change. If it is
telemetry, leave it. An entry added only inside the container would not
survive a rebuild, which is why the host verb is the only path.

The fence arms on every container start through the compose command, not a
lifecycle hook, so `docker restart` and daemon restarts arm it too. The arm
installs a minimal deny before anything fallible runs; any failure after that
leaves egress closed, never open. `devc firewall status` is the authority on
what is actually enforced. A wedged fence is lifted with `devc firewall off`.

The compose network is directly connected and therefore accepted, so a
project's database resolves and connects with the fence armed. The default
gateway — the host itself, on Linux — is rejected explicitly. IPv6 is a blanket
deny.

Not allowlisted on purpose: `deb.debian.org`. apt cannot run inside a started
container; an image rebuild is the only way to add an OS package.

## Privilege

The `dev` user has two sudo grants and no others. Both name root-owned
programs in the image, with their argument vectors spelled out:

    /usr/local/sbin/dev-firewall on | status | rotate | rotate --force
    /usr/local/sbin/dev-own-volumes            (no arguments)

Nothing writable from inside the container is ever escalated. `dev-firewall
off` is not granted: lifting the fence is the host operator's, through `devc
firewall off`. Your own in-container shell is the same `dev` identity the
agents use, so anything kept convenient from inside is available to the agent
too. That is the trade, taken knowingly.

What this buys: an agent cannot lift the fence or widen the allowlist by
editing a file. It raises the bar from "edit a file" to "have root on the
host", which is the bar worth having. The fence bounds mistakes and confused
egress, not intent; nothing more is claimed.

## Operator tools and the harness posture

claude and codex are installed with npm, herdr with its own installer, all
under `~/.local` on the home volume. Updating any of them is

    devc exec dev-bootstrap --update-tools        from the host
    dev-bootstrap --update-tools                  from inside

and needs no rebuild. The harnesses' own auto-update is disabled through their
environment switches, so versions move only when you run that. Two machines
can differ until each updates; `devc doctor` prints the versions.

The bootstrap writes the permission posture — bypass for claude, never-approve
and full access for codex — reconciling only those keys and leaving your other
settings alone. There is no knob. The container exists so agents run
unattended; a project that wanted prompts back would run the harness on the
host. The per-project knob is the allowlist: the posture says "do not ask", the
allowlist says "but only reach these places".

## Shell, editor and clipboard

The shell is zsh, configured in `/etc/zsh/devcontainer.zshrc`: shared history,
autosuggestions, syntax highlighting, a `user@host:cwd[branch]` prompt, and `y`
to run yazi and land in the directory it exited in. Your `~/.zshrc` runs after
it and wins.

nvim gets a copy-only OSC 52 clipboard from `/etc/xdg/nvim/plugin/`: yanks to
`+` and `*` reach the attached terminal's clipboard; register paste is
deliberately unsupported (an OSC 52 read would hang or prompt), so pasting is
the terminal's own keystroke. Set `g:clipboard` in your own config and the
default backs off.

## The home volume and the UID remap

On a Linux host whose user is not UID 1000, the devcontainer CLI remaps `dev`
to the host UID and chowns its home — and nothing else. A named volume mounted
inside the workspace takes its ownership from the image and ends up belonging
to a UID that no longer exists. `dev-own-volumes` repairs that once per
container create, through its grant, for every volume in its `VOLUMES` list.
The template ships the list empty; a project that mounts a `node_modules` or a
vendored bundle inside the workspace adds the line, the compose mount, and the
Dockerfile mount point.

## Tests

Four stub suites run on the host with no Docker and no network. Each runs its
subject in a scratch world with every external program stubbed and asserts the
exact calls made:

    bash .devcontainer/test/test-devc.sh
    bash .devcontainer/test/test-dev-firewall.sh
    bash .devcontainer/test/test-dev-own-volumes.sh
    bash .devcontainer/test/test-dev-bootstrap.sh

The three sh subjects can be re-run under dash (`DEVC_SHELL=dash`,
`DEV_FIREWALL_SHELL=dash`, `DEV_OWN_VOLUMES_SHELL=dash`) to catch bashisms the
host's `/bin/sh` lets through.

Three smoke checks exercise the real container against the real internet:

    devc exec bash .devcontainer/test/smoke-dev-firewall.sh    the fence fences, and dev cannot lift it
    bash .devcontainer/test/smoke-devc.sh                      the host verbs, allow, and the re-arm on restart
    bash .devcontainer/test/smoke-dev-own-volumes.sh           a remapped UID gets a writable volume

The template repository runs all of this in CI, on amd64 and arm64, so every
tagged commit of the template is a working one.

## Upgrading

`TEMPLATE` holds the template repository and the ref this copy was taken from.

1. Read the marker. Fetch the template repository and pick the new ref — a tag
   is a named good commit; any commit is a valid ref.
2. Diff the template's `.devcontainer/` between the recorded ref and the new
   one.
3. Apply that diff to the project's `.devcontainer/`. Conflicts arise only
   where the project edited the engine; the project sections are the
   template's blanks, so changes there are yours and never conflict.
4. Set `ref:` in `TEMPLATE` to the new ref.
5. Run the stub suites, then `devc rebuild`, then the smoke checks.

Five steps an agent can follow from this prose; there is no helper script and
no skill, on purpose, until the manual path proves tedious.

## Layout

    devcontainer.json      entry: name, compose file, /workspace, postCreate hook
    compose.yaml           app service, home volume, bind mount, capabilities,
                           arm-on-start; project adds services here
    Dockerfile             ARG BASE_IMAGE, engine layers; project packages in
                           marked sections
    TEMPLATE               template repository and the ref this copy was taken from
    env.example            keys expected in .env
    .env                   gitignored: identity, tokens
    firewall/allowlist     domains, one per line; copied into the image
    sbin/                  copied into the image at /usr/local/sbin, root-owned
      dev-firewall         on, off, status, rotate
      dev-own-volumes      the volumes list is inline; a change needs a rebuild
    bin/                   copied into the image at /usr/local/bin, runs as dev
      dev-bootstrap        python: tools, integrations, posture, identity, ssh;
                           --doctor, --update-tools
    host/devc              never copied into the image; runs on the host
    etc/                   copied under /etc in the image
      zsh/devcontainer.zshrc
      xdg/nvim/plugin/osc52-copy.lua
      sudoers.d/           the two grants, validated at build
    test/                  the stub suites and the smoke checks
