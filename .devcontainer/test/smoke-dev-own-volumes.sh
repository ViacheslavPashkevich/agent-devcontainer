#!/usr/bin/env bash
#
# smoke-dev-own-volumes.sh — the non-1000-UID container run. Where
# test-dev-own-volumes.sh proves bin/dev-own-volumes issues the right commands
# against stubbed ownership, this proves a real remapped container ends up with
# a writable node_modules volume, through the real sudoers grant.
#
# Run it on the *host*, not through `devcontainer exec` like the firewall smoke:
# it needs a container of its own, with its own throwaway volume, so it can
# reproduce a state the running devcontainer must never be put into.
#
#   bash .devcontainer/test/smoke-dev-own-volumes.sh
#
# It reproduces from macOS the failure only a Linux host whose user is not UID
# 1000 sees: there, the devcontainer CLI builds a derived image that rewrites the
# dev entry in /etc/passwd and chowns its home — and leaves every other mount
# point on the image's build-time 1000:1000. `groupmod`/`usermod` below reach the
# same end state (which is what matters: the volume mount point is untouched
# either way) and fail loudly on an ID collision rather than half-applying.
#
# The image comes from the running devcontainer, so this checks what the operator
# actually has. SMOKE_OWN_VOLUMES_IMAGE overrides that — how a freshly built
# candidate image is checked before it is recreated into. SMOKE_OWN_VOLUMES_PNPM=1
# additionally runs `pnpm install` as the remapped user: writability is what pnpm
# needs and is proven either way, so downloading the dependency tree stays opt-in.
#
# Divergence from the firewall smoke, which runs entirely inside its container:
# the container here is detached and driven step by step from the host, so every
# assertion reports under the one protocol below and a single failure leaves the
# rest of the run inspectable instead of aborting it.

set -u
export LC_ALL=C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
CONFIG=$ROOT/.devcontainer/devcontainer.json
# The bind-mount target is fixed: it is what the sudoers grant names.
WORKSPACE=/workspaces/brandeasy
# The UID the CLI's remap would land on for a host user that is not 1000.
REMAP_ID=1001
GRANT=/etc/sudoers.d/dev-own-volumes
GRANT_LINE="dev ALL=(root) NOPASSWD: $WORKSPACE/bin/dev-own-volumes"
POST_CREATE='bin/dev-own-volumes && bin/dev-bootstrap'

VOLUME=dev-own-volumes-smoke-$$
CONTAINER=dev-own-volumes-smoke-$$

CASE='(setup)'
CHECKS=0
FAILURES=0

case_start() {
	CASE=$1
	printf '%s\n' "$CASE"
}

ok() {
	CHECKS=$((CHECKS + 1))
	printf '  ok  %s\n' "$1"
}

# Failures accumulate rather than abort: one broken assertion should still let
# the rest of the repair be inspected in the same run.
bad() {
	FAILURES=$((FAILURES + 1))
	printf '  FAIL [%s]  %s\n' "$CASE" "$1" >&2
}

check() {
	if [ "$1" = 0 ]; then ok "$2"; else bad "$2${3:+ — $3}"; fi
}

die() {
	printf 'smoke-dev-own-volumes: %s\n' "$1" >&2
	exit 1
}

# --- preconditions ----------------------------------------------------------

command -v docker >/dev/null 2>&1 ||
	die 'Docker is not installed — this check drives a container of its own'

IMAGE=${SMOKE_OWN_VOLUMES_IMAGE:-}
if [ -z "$IMAGE" ]; then
	# The same label bin/dev-agent probes: the CLI records the literal workspace
	# path it was given, and the compose project name differs per worktree.
	IMAGE=$(docker ps --filter "label=devcontainer.local_folder=$ROOT" \
		--format '{{.Image}}' | head -n 1) ||
		die 'docker ps failed — refusing to guess which image to check'
	[ -n "$IMAGE" ] ||
		die 'no devcontainer is running for this checkout — start it first (bin/dev-agent), or name an image in SMOKE_OWN_VOLUMES_IMAGE'
fi

# The docker run below invokes bin/dev-own-volumes directly, so without this the
# lifecycle wiring could be missing or reversed and the smoke would still be
# green. A full `devcontainer up` per run is the alternative, and a second create
# against the real volumes is both slow and side-effectful.
grep -qF -- "\"postCreateCommand\": \"$POST_CREATE\"" "$CONFIG" ||
	die "$CONFIG does not run \`$POST_CREATE\` on create — the volume would be repaired after pnpm needs it, or not at all"

# --- the fixture ------------------------------------------------------------

cleanup() {
	docker rm -f "$CONTAINER" >/dev/null 2>&1
	docker volume rm "$VOLUME" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

docker volume create "$VOLUME" >/dev/null ||
	die "cannot create the throwaway volume $VOLUME"

# --user root because the remap itself needs it; the repair below is invoked as
# dev, which is the identity that has to work. Detached with a no-op main
# process, so each step is its own `docker exec`.
docker run -d --name "$CONTAINER" --user root \
	-v "$ROOT:$WORKSPACE" \
	-v "$VOLUME:$WORKSPACE/node_modules" \
	"$IMAGE" sleep 600 >/dev/null ||
	die "cannot start a container from $IMAGE"

# dev_run <argv…> — as the dev user, which after the remap is $REMAP_ID.
dev_run() { docker exec -u dev "$CONTAINER" "$@"; }
root_run() { docker exec "$CONTAINER" "$@"; }
owner_of() { root_run stat -c '%u:%g' "$1" 2>/dev/null; }

printf 'image: %s\nvolume: %s\n\n' "$IMAGE" "$VOLUME"

# ============================================================================

case_start 'the container is remapped the way the devcontainer CLI remaps it'
root_run sh -c "groupmod -g $REMAP_ID dev && usermod -u $REMAP_ID dev && chown -R dev:dev /home/dev"
check $? "dev is moved to $REMAP_ID:$REMAP_ID and its home follows" 'a non-pristine image fails here, at setup'
# Asserted rather than assumed: a derived image whose dev is already remapped
# would make every verdict below meaningless.
[ "$(root_run id -u dev)" = "$REMAP_ID" ] && [ "$(root_run id -g dev)" = "$REMAP_ID" ]
check $? "the passwd entry now reads $REMAP_ID:$REMAP_ID"

case_start 'a fresh node_modules volume is not writable by the remapped dev'
# The regression itself. Proving it exists is what makes the repair below
# evidence rather than a tautology.
before=$(owner_of "$WORKSPACE/node_modules")
[ -n "$before" ] && [ "$before" != "$REMAP_ID:$REMAP_ID" ]
check $? "the mount point still carries the image's owner ($before)" 'the volume takes its ownership from the image, which can only be 1000:1000'
dev_run touch "$WORKSPACE/node_modules/.probe" 2>/dev/null
[ $? != 0 ]
check $? 'dev cannot write it — this is the pnpm install failure'
# A volume populated under a previous UID: the repair has to reach the contents,
# not just the mount point.
root_run mkdir -p "$WORKSPACE/node_modules/.stale"
check $? 'a directory left over from a previous UID is planted'

case_start 'the sudoers grant covers exactly the one script'
[ "$(root_run stat -c '%a' "$GRANT" 2>/dev/null)" = 440 ]
check $? "$GRANT is mode 0440" 'a stale image without the grant fails here — rebuild it with bin/dev-agent --update'
[ "$(root_run cat "$GRANT" 2>/dev/null)" = "$GRANT_LINE" ]
check $? 'its sole content is the one fixed-path NOPASSWD line'
dev_run sudo -n true 2>/dev/null
[ $? != 0 ]
check $? 'casual sudo stays unavailable to dev'

case_start 'the repair runs as dev and aligns the volume with the remapped UID'
output=$(dev_run "$WORKSPACE/bin/dev-own-volumes" 2>&1)
check $? 'bin/dev-own-volumes exits clean, escalating through its own grant' "$output"
printf '%s\n' "$output" | grep -qF "owned: node_modules (dev, $REMAP_ID:$REMAP_ID)"
check $? 'it reports the one mount point it repaired'
[ "$(owner_of "$WORKSPACE/node_modules")" = "$REMAP_ID:$REMAP_ID" ]
check $? "the mount point is now $REMAP_ID:$REMAP_ID"
[ "$(owner_of "$WORKSPACE/node_modules/.stale")" = "$REMAP_ID:$REMAP_ID" ]
check $? 'the contents left by the previous UID were repaired too'
dev_run touch "$WORKSPACE/node_modules/.probe"
check $? 'dev can write it — which is all pnpm install needs'

case_start 'a second create is a no-op'
again=$(dev_run "$WORKSPACE/bin/dev-own-volumes" 2>&1)
check $? 'the converged run exits clean'
[ -z "$again" ]
check $? 'it says nothing at all' "printed: $again"

if [ "${SMOKE_OWN_VOLUMES_PNPM:-}" = 1 ]; then
	case_start 'pnpm install succeeds into the repaired volume'
	# Egress is open in a bare `docker run` — no fence is armed in here.
	docker exec -u dev -w "$WORKSPACE" "$CONTAINER" pnpm install --frozen-lockfile
	check $? 'pnpm install --frozen-lockfile completes as the remapped dev'
fi

# ============================================================================

printf '\n'
if [ "$FAILURES" = 0 ]; then
	printf '%s checks passed — a non-1000 UID gets a writable node_modules\n' "$CHECKS"
	exit 0
fi
printf '%s checks passed, %s failed\n' "$CHECKS" "$FAILURES" >&2
exit 1
