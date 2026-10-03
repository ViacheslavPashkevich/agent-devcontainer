#!/usr/bin/env bash
#
# smoke-dev-own-volumes.sh — the non-1000-UID container run. Where
# test-dev-own-volumes.sh proves dev-own-volumes issues the right commands
# against stubbed ownership, this proves a real remapped container ends up with
# a writable named volume inside the workspace, through the real sudoers grant.
#
# Run it on the *host*, not through `devc exec`: it needs a container of its
# own, with its own throwaway volume, so it can reproduce a state the running
# devcontainer must never be put into.
#
#   bash .devcontainer/test/smoke-dev-own-volumes.sh
#
# It reproduces from any host the failure only a Linux host whose user is not
# UID 1000 sees: there, the devcontainer CLI builds a derived image that
# rewrites the dev entry in /etc/passwd and chowns its home — and leaves every
# other mount point as the image left it. `groupmod`/`usermod` below reach the
# same end state and fail loudly on an ID collision rather than half-applying.
#
# The template ships an empty VOLUMES list, so the first step installs, as root
# and at the image path, a copy of the shipped script with one fixture volume —
# exactly what a project's edit produces. The grant names that path, so the
# escalation under test is the real one.
#
# The image comes from the running devcontainer, so this checks what the
# operator actually has. SMOKE_OWN_VOLUMES_IMAGE overrides that — how a freshly
# built candidate image is checked before it is recreated into.

# The checks read as "assert, then report": a test or a command, then `check $?`
# with the sentence it proves. shellcheck would rather see the status checked
# directly (SC2181) and not read off a bracket test (SC2319); the idiom is the
# whole readability of this file, so both are quiet here.
# shellcheck disable=SC2181,SC2319

set -u
export LC_ALL=C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
CONFIG=$ROOT/.devcontainer/devcontainer.json
WORKSPACE=/workspace
PROGRAM=/usr/local/sbin/dev-own-volumes
# The UID the CLI's remap would land on for a host user that is not 1000.
REMAP_ID=1001
GRANT=/etc/sudoers.d/dev-own-volumes
GRANT_LINE="dev ALL=(root) NOPASSWD: $PROGRAM \"\""
POST_CREATE='/usr/local/sbin/dev-own-volumes && /usr/local/bin/dev-bootstrap'

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
	# The same label devc probes: the CLI records the literal workspace path it
	# was given.
	IMAGE=$(docker ps --filter "label=devcontainer.local_folder=$ROOT" \
		--format '{{.Image}}' | head -n 1) ||
		die 'docker ps failed — refusing to guess which image to check'
	[ -n "$IMAGE" ] ||
		die 'no devcontainer is running for this checkout — start it first (devc up), or name an image in SMOKE_OWN_VOLUMES_IMAGE'
fi

# The docker run below invokes the program directly, so without this the
# lifecycle wiring could be missing or reversed and the smoke would still be
# green. A full `devcontainer up` per run is the alternative, and a second
# create against the real volumes is both slow and side-effectful.
grep -qF -- "\"postCreateCommand\": \"$POST_CREATE\"" "$CONFIG" ||
	die "$CONFIG does not run \`$POST_CREATE\` on create — a project's volume would be repaired after its installer needs it, or not at all"

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

case_start 'the shipped program lists no volumes; the fixture gives it one'
root_run grep -q "^VOLUMES=''\$" "$PROGRAM"
check $? 'the image copy ships VOLUMES empty' 'the template mounts nothing inside the workspace'
root_run sh -c "sed \"s/^VOLUMES=''\\\$/VOLUMES='node_modules'/\" $PROGRAM > /tmp/own && install -m 0755 -o root -g root /tmp/own $PROGRAM && rm /tmp/own"
check $? "a copy with one fixture volume is installed at $PROGRAM, root-owned — a project's edit, exactly"
root_run grep -q "^VOLUMES='node_modules'\$" "$PROGRAM"
check $? 'the installed copy carries the fixture list'

case_start 'the container is remapped the way the devcontainer CLI remaps it'
root_run sh -c "groupmod -g $REMAP_ID dev && usermod -u $REMAP_ID dev && chown -R dev:dev /home/dev"
check $? "dev is moved to $REMAP_ID:$REMAP_ID and its home follows" 'a non-pristine image fails here, at setup'
# Asserted rather than assumed: a derived image whose dev is already remapped
# would make every verdict below meaningless.
[ "$(root_run id -u dev)" = "$REMAP_ID" ] && [ "$(root_run id -g dev)" = "$REMAP_ID" ]
check $? "the passwd entry now reads $REMAP_ID:$REMAP_ID"

case_start 'a fresh volume inside the workspace is not writable by the remapped dev'
# The regression itself. Proving it exists is what makes the repair below
# evidence rather than a tautology. The image pre-creates no node_modules mount
# point (that is the project's line), so Docker made this one as root — the
# other way a fresh volume ends up not dev's.
before=$(owner_of "$WORKSPACE/node_modules")
[ -n "$before" ] && [ "$before" != "$REMAP_ID:$REMAP_ID" ]
check $? "the mount point carries an owner that is not dev ($before)" 'the volume takes its ownership from the image, never from the remapped account'
dev_run touch "$WORKSPACE/node_modules/.probe" 2>/dev/null
[ $? != 0 ]
check $? 'dev cannot write it — this is the install failure a project would hit'
# A volume populated under a previous UID: the repair has to reach the contents,
# not just the mount point.
root_run mkdir -p "$WORKSPACE/node_modules/.stale"
check $? 'a directory left over from a previous UID is planted'

case_start 'the sudoers grant covers exactly the one program with no arguments'
[ "$(root_run stat -c '%a' "$GRANT" 2>/dev/null)" = 440 ]
check $? "$GRANT is mode 0440" 'a stale image without the grant fails here — rebuild it with devc rebuild'
root_run grep -qxF -- "$GRANT_LINE" "$GRANT"
check $? 'it holds the one fixed-path, no-argument NOPASSWD line'
[ "$(root_run grep -cv '^#' "$GRANT")" = 1 ]
check $? 'and no other grant line'
dev_run sudo -n true 2>/dev/null
[ $? != 0 ]
check $? 'casual sudo stays unavailable to dev'
dev_run sudo -n "$PROGRAM" --help >/dev/null 2>&1
[ $? != 0 ]
check $? 'sudo refuses the program with an argument — "" in sudoers means none'

case_start 'the repair runs as dev and aligns the volume with the remapped UID'
output=$(dev_run "$PROGRAM" 2>&1)
check $? 'dev-own-volumes exits clean, escalating through its own grant' "$output"
printf '%s\n' "$output" | grep -qF "owned: node_modules (dev, $REMAP_ID:$REMAP_ID)"
check $? 'it reports the one mount point it repaired'
[ "$(owner_of "$WORKSPACE/node_modules")" = "$REMAP_ID:$REMAP_ID" ]
check $? "the mount point is now $REMAP_ID:$REMAP_ID"
[ "$(owner_of "$WORKSPACE/node_modules/.stale")" = "$REMAP_ID:$REMAP_ID" ]
check $? 'the contents left by the previous UID were repaired too'
dev_run touch "$WORKSPACE/node_modules/.probe"
check $? 'dev can write it — which is all an installer needs'

case_start 'a second create is a no-op'
again=$(dev_run "$PROGRAM" 2>&1)
check $? 'the converged run exits clean'
[ -z "$again" ]
check $? 'it says nothing at all' "printed: $again"

# ============================================================================

printf '\n'
if [ "$FAILURES" = 0 ]; then
	printf '%s checks passed — a non-1000 UID gets a writable volume\n' "$CHECKS"
	exit 0
fi
printf '%s checks passed, %s failed\n' "$CHECKS" "$FAILURES" >&2
exit 1
