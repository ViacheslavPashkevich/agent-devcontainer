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
- A [T3 Code](#t3-code) server, started with the container.
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

No rebuild needed. Auto-update is off. This updates herdr and t3 too; a
running t3 server switches to the new version at the next container start.

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

## T3 Code

A T3 Code server starts with the container, on port 3774, reachable from the
host only.

To connect the T3 app:

1. Get a pairing link:

   ```bash
   devc exec t3 pair
   ```

2. In the link, replace the container's address (such as `172.19.0.2:3774`)
   with `localhost:3774`, then open it or paste it into the app.

Good to know:

- **Several projects on one host:** give each its own port with `T3_PORT` in
  `.env`.
- **From another machine:** set `T3_BIND` in `.env` to an address of the host,
  such as its Tailnet IP, and use that address in the link.
- **After changing `.env`,** run `devc rebuild`.
- **Not running?** `devc doctor` says so and shows where the log is.

## Customizing

Everything you're expected to edit is marked `project section`. The rest is
yours to change too.

| File | Section | What goes there |
| --- | --- | --- |
| `firewall/allowlist` | whole file | Allowed domains, one per line. Subdomains are included. |
| `Dockerfile` | base image | `ARG BASE_IMAGE=…`: any Debian-family image. |
| `Dockerfile` | packages | OS packages. |
| `Dockerfile` | mount points and environment | `mkdir`+`chown` per volume inside the workspace, plus `ENV`. |
| `compose.yaml` | ports | Published ports (loopback only). |
| `compose.yaml` | the app service | Environment, `depends_on`. |
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

## Layout

```text
devcontainer.json      devcontainer entry point
compose.yaml           the app service, volumes, your extra services
Dockerfile             the image
env.example            what can go in .env
firewall/allowlist     allowed domains
sbin/dev-firewall      the firewall (runs as root)
sbin/dev-own-volumes   fixes volume ownership (runs as root)
bin/dev-bootstrap      installs the tools, sets up yolo mode, git and ssh,
                       starts the t3 server
host/devc              the host command
etc/                   zsh, nvim and sudo config
test/                  tests and smoke checks; see test/README.md
UPGRADING.md           optional: taking the template's later changes
```
