# Agent devcontainer

A minimal devcontainer for running coding agents: claude and codex preinstalled, yolo mode enabled.
Configurable firewall included (egress allowlist).

> **Warning.** Yolo mode means claude runs with `bypassPermissions` and codex
> with `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`.
> Agents run any command without asking; the container and the firewall are
> the only limits.

## What's included

- Debian base, or any Debian-family image you pick.
- A non-root `dev` user. Its home is a named volume, so logins, tools and
  history survive rebuilds. Your project is mounted at `/workspace`.
- claude, codex and herdr (a terminal multiplexer for agents).
- python3 (pip, venv), node LTS, git, gh, ssh, curl, jq, ripgrep, fd, tree,
  unzip, file.
- zsh, nvim and yazi; see
  [Shell, editor and clipboard](#shell-editor-and-clipboard).
- The firewall, on at every container start.

## What's not included

- **The docker socket.** An agent could use it to start containers outside
  the firewall.
- **An ssh server.** For remote access, ssh to the host and run `devc` there.
- **apt at runtime.** The Debian mirrors aren't allowlisted. To add an OS
  package, edit the Dockerfile and rebuild.

## Quick start

Needs Docker with Compose ≥ 2.24 and the devcontainer CLI:

```bash
npm install -g @devcontainers/cli
```

1. Copy this directory into your project as `.devcontainer/`.
   - *Optional:* set `ref:` in `TEMPLATE` to the tag you copied (needed later
     for [Upgrading](#upgrading)), then commit.
   - *Optional:* copy `env.example` to `.env` and fill it in. `.env` is
     gitignored.
2. Run `.devcontainer/host/devc`. The first run builds the image, sets up the
   home volume, turns the firewall on and attaches.
3. Log in, once per machine:
   - **claude:** run `claude`, then `/login`.
   - **codex:** `codex login --device-auth`. The browser login doesn't work
     from inside the container.
   - **GitHub ssh:** add `~/.ssh/id_devcontainer.pub` to GitHub, then connect
     once by hand to check the fingerprint.
4. *Optional:* adjust the container to your needs by editing the project
   sections (see [Customizing](#customizing)), then rebuild:

   ```bash
   .devcontainer/host/devc rebuild
   ```

`.devcontainer/host/devc doctor` shows what's still missing and how to fix it.

## Commands

`devc` below is short for `.devcontainer/host/devc`. For a shorter command,
add a `bin/devc` shim to your project:

```bash
#!/bin/sh
exec "$(dirname "$0")/../.devcontainer/host/devc" "$@"
```

```text
devc                           start if needed, then attach
devc up                        start, don't attach
devc attach                    attach only
devc stop                      stop, keep volumes
devc rebuild                   rebuild from scratch, then attach

devc firewall status           rules, allowlist, recent blocks
devc firewall allow <domain>   allow a domain
devc firewall on               turn the firewall on
devc firewall off              turn it off

devc exec <command...>         run a command inside
devc doctor                    check the host and the container
```

`devc attach` opens herdr. For a plain shell, change `ATTACH=` at the top of
`host/devc`.

### Updating claude and codex

```bash
devc exec dev-bootstrap --update-tools     # from the host
dev-bootstrap --update-tools               # from inside
```

No rebuild needed. Auto-update is off.

## Firewall

All outbound traffic is blocked, except to the domains in
`firewall/allowlist`. The firewall turns on at every container start.

When something the project needs is blocked:

1. See what was blocked:

   ```bash
   devc firewall status
   ```

2. Allow the domain:

   ```bash
   devc firewall allow <domain>
   ```

   This adds it to `firewall/allowlist` and applies it to the running
   container. Open connections survive.
3. Commit the allowlist change.

Good to know:

- **Fast failures.** Blocked connections fail right away instead of hanging.
- **Still reachable:** your other compose services, such as a database.
- **Always blocked:** the host and all IPv6.
- **Fails closed.** If the firewall can't start, traffic stays blocked.
- **Agents can't change it.** Inside the container, sudo works only for
  `dev-firewall on | status | rotate` and `dev-own-volumes`. Turning the
  firewall off works only from the host, with `devc firewall off`.
- **Limits.** It catches mistakes and stray traffic, but won't stop a
  determined attacker. Your shell inside is the same `dev` user the agents
  use, so whatever you can do from inside, they can too.

## Customizing

Everything you're expected to edit is marked `project section`. You can change
the rest too, but upgrades are easier if you don't.

| File | Section | What goes there |
| --- | --- | --- |
| `firewall/allowlist` | whole file | Allowed domains, one per line. Subdomains are included. |
| `Dockerfile` | base image | `ARG BASE_IMAGE=…`: any Debian-family image. |
| `Dockerfile` | packages | OS packages. |
| `Dockerfile` | mount points and environment | `mkdir`+`chown` per volume inside the workspace, plus `ENV`. |
| `compose.yaml` | the app service | Ports (loopback only), environment, `depends_on`. |
| `compose.yaml` | services | Databases, caches. Reachable from the container by service name. |
| `compose.yaml` | mounts / volumes | Named volumes inside the workspace. |
| `sbin/dev-own-volumes` | `VOLUMES=` | One entry per volume inside the workspace. |
| `env.example` | project section | Variables your project's tooling reads. |
| `devcontainer.json` | `name` | Display name. |

Two things can't change: the base image must be Debian-family (everything
installs with apt), and the workspace path must stay `/workspace`.

**Adding a volume inside the workspace** (such as `node_modules`) takes three
edits: the Dockerfile mount point, the compose mount, and the `VOLUMES=`
entry. The last one fixes the volume's ownership on Linux hosts where your
UID isn't 1000.

## Shell, editor and clipboard

zsh is set up in `/etc/zsh/devcontainer.zshrc`. Your own `~/.zshrc` runs after
it and wins.

- Shared history, autosuggestions, syntax highlighting.
- `g` is git. `y` opens yazi and leaves you in the directory you exit in.
- fzf: Ctrl-R history, Ctrl-T files, Alt-C directories, `**<Tab>` completion.
- Ctrl-K, Ctrl-J and the arrows search history by what you've typed so far.

In nvim, yanking to `+` or `*` copies to your terminal's clipboard. To paste,
use your terminal's paste shortcut. Setting `g:clipboard` in your own config
overrides this.

## Upgrading

`TEMPLATE` records the template repo and the ref you copied.

1. Fetch the template repo and pick a new ref.
2. Diff its `.devcontainer/` between your recorded ref and the new one.
3. Apply the diff to your `.devcontainer/`. Conflicts appear only where you
   edited outside the project sections.
4. Set `ref:` in `TEMPLATE` to the new ref.
5. Run the tests, then `devc rebuild`, then the smoke checks; see
   [test/README.md](test/README.md).

## Layout

```text
devcontainer.json      devcontainer entry point
compose.yaml           the app service, volumes, your extra services
Dockerfile             the image
TEMPLATE               template repo and ref
env.example            what can go in .env
firewall/allowlist     allowed domains
sbin/dev-firewall      the firewall (runs as root)
sbin/dev-own-volumes   fixes volume ownership (runs as root)
bin/dev-bootstrap      installs the agents, sets up yolo mode, git and ssh
host/devc              the host command
etc/                   zsh, nvim and sudo config
test/                  tests and smoke checks; see test/README.md
```
