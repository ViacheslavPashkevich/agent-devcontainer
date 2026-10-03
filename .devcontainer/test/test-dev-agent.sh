#!/usr/bin/env bash
#
# test-dev-agent.sh — bin/dev-agent's stub matrix: cold start, warm attach, the
# rebuild flags, --stop, root resolution from a worktree, and every prerequisite
# failure.
#
# Run it from anywhere, on the host: bash .devcontainer/test/test-dev-agent.sh
#
# `bin/dev-agent` is POSIX sh on purpose, and macOS `/bin/sh` is bash in POSIX
# mode — permissive enough to let a bashism through. Re-run the suite against the
# strictest interpreter the shebang can land on to catch that:
#
#   DEV_AGENT_SHELL=dash bash .devcontainer/test/test-dev-agent.sh
#
# The scratch world, the reporting protocol, the safe bin, planting and the
# generic assertions come from test-helper.sh; what stays here is bin/dev-agent's
# own: the docker and devcontainer stubs, the tarball checkout, and the cases.

SUBJECT=dev-agent
SUBJECT_SHELL_VAR=DEV_AGENT_SHELL
# shellcheck source=.devcontainer/test/test-helper.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-helper.sh"

# --- stubs ------------------------------------------------------------------

cat >"$STUBS/docker" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'docker %s\n' "$*" >>"$S/calls.log"
case "${1:-} ${2:-}" in
"info ")
	[ -n "${DOCKER_STUB_INFO_FAIL:-}" ] && {
		echo 'docker stub: Cannot connect to the Docker daemon at unix:///var/run/docker.sock' >&2
		exit 1
	}
	echo 'docker stub: Server Version: 99.0'
	;;
"compose version")
	[ -n "${DOCKER_STUB_NO_COMPOSE:-}" ] && {
		echo "docker stub: 'compose' is not a docker command" >&2
		exit 1
	}
	printf '%s\n' "${DOCKER_STUB_COMPOSE_VERSION:-2.27.0}"
	;;
"ps -q")
	[ -n "${DOCKER_STUB_PS_FAIL:-}" ] && {
		echo 'docker stub: error during connect: dial unix docker.raw.sock' >&2
		exit 1
	}
	# Answer "running" only for the expected label filter: the probe's own
	# argument is under test, not just the reply it gets.
	case " $* " in
	*" label=devcontainer.local_folder=${STUB_EXPECT_ROOT:?} "*)
		[ -e "$S/running" ] && echo 'c0ffee123456'
		;;
	*" label=com.docker.compose.project=brandeasy_devcontainer "*)
		# The project-wide probe the stop path issues: one id per line, and
		# the two containers are independently up or down.
		[ -e "$S/running" ] && echo 'c0ffee123456'
		[ -e "$S/pg_running" ] && echo '90ffee654321'
		;;
	esac
	;;
"ps -aq")
	# Any state: the app container answers whether it is running or merely
	# created, which is what lets the stop path read its labels.
	[ -n "${DOCKER_STUB_PS_FAIL:-}" ] && {
		echo 'docker stub: error during connect: dial unix docker.raw.sock' >&2
		exit 1
	}
	case " $* " in
	*" label=devcontainer.local_folder=${STUB_EXPECT_ROOT:?} "*)
		{ [ -e "$S/running" ] || [ -e "$S/created" ]; } && echo 'c0ffee123456'
		;;
	esac
	;;
"inspect "*)
	[ -n "${DOCKER_STUB_INSPECT_FAIL:-}" ] && {
		echo 'docker stub: Error: No such object: c0ffee123456' >&2
		exit 1
	}
	echo 'brandeasy_devcontainer'
	;;
"stop "*)
	# The knob's value *is* the status, so a case can assert exact
	# propagation rather than merely "non-zero".
	[ -n "${DOCKER_STUB_STOP_FAIL:-}" ] && {
		echo 'docker stub: cannot stop container: permission denied' >&2
		exit "$DOCKER_STUB_STOP_FAIL"
	}
	shift
	for id in "$@"; do
		echo "$id"
	done
	rm -f "$S/running" "$S/pg_running"
	;;
*)
	echo "docker stub: unsupported: $*" >&2
	exit 2
	;;
esac
exit 0
STUB

cat >"$STUBS/devcontainer" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'devcontainer %s\n' "$*" >>"$S/calls.log"
case "${1:-}" in
up)
	# A failing `up` leaves the container state untouched, so a test can prove
	# the script never attached to something it did not start.
	[ -n "${DEVCONTAINER_STUB_UP_FAIL:-}" ] && {
		echo 'devcontainer stub: up failed' >&2
		exit 1
	}
	echo 'devcontainer stub: streamed build output'
	: >"$S/running"
	printf '%s\n' "${TOOLS_EPOCH:-unset}" >"$S/tools_epoch"
	;;
exec)
	exit "${DEVCONTAINER_STUB_EXEC_RC:-0}"
	;;
*)
	echo "devcontainer stub: unsupported: $*" >&2
	exit 2
	;;
esac
exit 0
STUB

chmod +x "$STUBS/docker" "$STUBS/devcontainer"

# --- the scratch checkouts --------------------------------------------------
#
# The helper builds $REPO and its $WT worktree; this suite needs one more.

# A copy in no repository at all, for the fallback arm of root resolution.
TARBALL="$TMP/tarball"
plant "$TARBALL"

# --- the case harness -------------------------------------------------------

reset_world() {
	rm -rf "$STATE"
	mkdir -p "$STATE"
	grant docker devcontainer
	unset DOCKER_STUB_INFO_FAIL DOCKER_STUB_NO_COMPOSE DOCKER_STUB_PS_FAIL \
		DOCKER_STUB_COMPOSE_VERSION DOCKER_STUB_INSPECT_FAIL \
		DOCKER_STUB_STOP_FAIL DEVCONTAINER_STUB_UP_FAIL \
		DEVCONTAINER_STUB_EXEC_RC TOOLS_EPOCH
	OUT=''
	ERR=''
	RC=0
}

# runp [--from <checkout>] <args…> — run the planted script with a hermetic PATH.
runp() {
	local from="$REPO"
	if [ "${1:-}" = --from ]; then
		from="$2"
		shift 2
	fi
	capture --cd "$from" env -i \
		PATH="$CASEBIN:$SAFEBIN" \
		HOME="$TMP" \
		STUB_STATE="$STATE" \
		STUB_EXPECT_ROOT="${EXPECT:-$REPO}" \
		${DOCKER_STUB_INFO_FAIL+DOCKER_STUB_INFO_FAIL="$DOCKER_STUB_INFO_FAIL"} \
		${DOCKER_STUB_NO_COMPOSE+DOCKER_STUB_NO_COMPOSE="$DOCKER_STUB_NO_COMPOSE"} \
		${DOCKER_STUB_PS_FAIL+DOCKER_STUB_PS_FAIL="$DOCKER_STUB_PS_FAIL"} \
		${DOCKER_STUB_COMPOSE_VERSION+DOCKER_STUB_COMPOSE_VERSION="$DOCKER_STUB_COMPOSE_VERSION"} \
		${DOCKER_STUB_INSPECT_FAIL+DOCKER_STUB_INSPECT_FAIL="$DOCKER_STUB_INSPECT_FAIL"} \
		${DOCKER_STUB_STOP_FAIL+DOCKER_STUB_STOP_FAIL="$DOCKER_STUB_STOP_FAIL"} \
		${DEVCONTAINER_STUB_UP_FAIL+DEVCONTAINER_STUB_UP_FAIL="$DEVCONTAINER_STUB_UP_FAIL"} \
		${DEVCONTAINER_STUB_EXEC_RC+DEVCONTAINER_STUB_EXEC_RC="$DEVCONTAINER_STUB_EXEC_RC"} \
		"$from/bin/dev-agent" "$@"
}

# ============================================================================
# The happy paths
# ============================================================================

case_start 'cold start: probe, then up, then attach — in that order'
reset_world
runp
rc_is 0
log_is \
	'docker info' \
	'docker compose version --short' \
	"docker ps -q --filter label=devcontainer.local_folder=$REPO" \
	"devcontainer up --workspace-folder $REPO" \
	"devcontainer exec --workspace-folder $REPO herdr"
out_has 'streamed build output'
ok 'the cold start streams the build output rather than swallowing it'

case_start 'warm attach: the container is running, so nothing touches its state'
reset_world
: >"$STATE/running"
runp
rc_is 0
not_called 'devcontainer up'
called_times 1 'devcontainer '
called "devcontainer exec --workspace-folder $REPO herdr"

case_start 'a second run is a no-op apart from the attach'
reset_world
runp
rc_is 0
called 'devcontainer up'
: >"$STATE/calls.log"
runp
rc_is 0
log_is \
	'docker info' \
	'docker compose version --short' \
	"docker ps -q --filter label=devcontainer.local_folder=$REPO" \
	"devcontainer exec --workspace-folder $REPO herdr"

case_start 'the attach exit status is the script exit status'
reset_world
: >"$STATE/running"
DEVCONTAINER_STUB_EXEC_RC=3 runp
rc_is 3
DEVCONTAINER_STUB_EXEC_RC=0 runp
rc_is 0
ok 'a detach (herdr exits 0) is a successful run'

case_start 'a worktree copy attaches to the primary checkout container'
reset_world
: >"$STATE/running"
runp --from "$WT"
rc_is 0
# STUB_EXPECT_ROOT is the primary checkout, so a probe answered "running" at all
# proves the filter carried the primary path and not the worktree's.
called "docker ps -q --filter label=devcontainer.local_folder=$REPO"
called "devcontainer exec --workspace-folder $REPO herdr"
not_called "$WT"

case_start 'outside a git checkout the root is the bin/ directory parent'
reset_world
if git -C "$TARBALL" rev-parse --git-common-dir >/dev/null 2>&1; then
	printf '  -- skipped: TMPDIR sits inside a git checkout\n'
else
	EXPECT="$TARBALL" runp --from "$TARBALL"
	rc_is 0
	called "devcontainer up --workspace-folder $TARBALL"
	called "devcontainer exec --workspace-folder $TARBALL herdr"
fi

# ============================================================================
# Prerequisites
# ============================================================================

case_start 'docker missing: names Docker, and nothing else runs'
reset_world
grant devcontainer
runp
rc_nonzero
err_has 'Docker is not installed'
err_has 'Docker Desktop'
log_empty

case_start "daemon unreachable: docker's own diagnostic survives"
reset_world
DOCKER_STUB_INFO_FAIL=1 runp
rc_nonzero
err_has 'cannot connect to the Docker daemon'
err_has 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock'
cli_not_called devcontainer
log_is 'docker info'

case_start 'devcontainer CLI missing: names the install command'
reset_world
grant docker
runp
rc_nonzero
err_has 'devcontainer CLI missing'
err_has 'npm install -g @devcontainers/cli'
log_is 'docker info'

case_start 'compose plugin missing: names Compose, not the daemon'
reset_world
DOCKER_STUB_NO_COMPOSE=1 runp
rc_nonzero
err_has 'the Docker Compose plugin is missing'
err_has '2.24'
cli_not_called devcontainer

case_start 'compose too old: names the required version and what was found'
reset_world
DOCKER_STUB_COMPOSE_VERSION=2.23.0 runp
rc_nonzero
err_has 'Docker Compose >= 2.24 required (found 2.23.0)'
cli_not_called devcontainer

case_start 'compose 1.x is too old too'
reset_world
DOCKER_STUB_COMPOSE_VERSION=1.29.2 runp
rc_nonzero
err_has 'Docker Compose >= 2.24 required (found 1.29.2)'
cli_not_called devcontainer

case_start 'compose decorations and a later major are accepted'
reset_world
: >"$STATE/running"
DOCKER_STUB_COMPOSE_VERSION=v2.24.1-desktop.1 runp
rc_is 0
DOCKER_STUB_COMPOSE_VERSION=5.1.1 runp
rc_is 0
err_hasnt 'Docker Compose'
called "devcontainer exec --workspace-folder $REPO herdr"

case_start 'an unreadable compose version warns and continues'
reset_world
: >"$STATE/running"
DOCKER_STUB_COMPOSE_VERSION=weird-string runp
rc_is 0
err_has 'cannot read the Docker Compose version (weird-string); continuing'
called "devcontainer exec --workspace-folder $REPO herdr"

# ============================================================================
# Refusing to half-start
# ============================================================================

case_start 'a failed up never attaches'
reset_world
DEVCONTAINER_STUB_UP_FAIL=1 runp
rc_nonzero
called 'devcontainer up'
not_called 'devcontainer exec'

case_start 'a wedged probe is not read as "cold"'
reset_world
DOCKER_STUB_PS_FAIL=1 runp
rc_nonzero
err_has 'docker ps failed'
err_has 'error during connect'
cli_not_called devcontainer

# ============================================================================
# --update / --rebuild
# ============================================================================

case_start '--update recreates the container against a fresh TOOLS_EPOCH'
reset_world
: >"$STATE/running"
runp --update
rc_is 0
log_is \
	'docker info' \
	'docker compose version --short' \
	"devcontainer up --workspace-folder $REPO --remove-existing-container" \
	"devcontainer exec --workspace-folder $REPO herdr"
ok 'the warm probe is skipped: an up happens even with the container running'
epoch=$(cat "$STATE/tools_epoch")
case "$epoch" in
'' | 0 | *[!0-9]*) die "TOOLS_EPOCH reached the build as '$epoch'" ;;
esac
ok "TOOLS_EPOCH reached the build as a fresh timestamp ($epoch)"

case_start '--rebuild is --update plus --build-no-cache'
reset_world
runp --rebuild
rc_is 0
called "devcontainer up --workspace-folder $REPO --remove-existing-container --build-no-cache"
called "devcontainer exec --workspace-folder $REPO herdr"

case_start 'a failed up under --update never attaches either'
reset_world
DEVCONTAINER_STUB_UP_FAIL=1 runp --update
rc_nonzero
called 'devcontainer up'
not_called 'devcontainer exec'

# ============================================================================
# --stop
# ============================================================================

case_start '--stop stops every running container of the project'
reset_world
: >"$STATE/running"
: >"$STATE/pg_running"
runp --stop
rc_is 0
log_is \
	'docker info' \
	"docker ps -aq --filter label=devcontainer.local_folder=$REPO" \
	'docker inspect -f {{index .Config.Labels "com.docker.compose.project"}} c0ffee123456' \
	'docker ps -q --filter label=com.docker.compose.project=brandeasy_devcontainer' \
	'docker stop c0ffee123456 90ffee654321'
ok 'both containers are stopped, and no devcontainer CLI call happens at all'

case_start '--stop cleans up a half-stopped environment'
reset_world
# The app container exists but is down; postgres is still burning memory.
: >"$STATE/created"
: >"$STATE/pg_running"
runp --stop
rc_is 0
# An exact log, not a called/not_called pair: the point is that the stopped
# app id is *not* also handed to `docker stop`.
log_is \
	'docker info' \
	"docker ps -aq --filter label=devcontainer.local_folder=$REPO" \
	'docker inspect -f {{index .Config.Labels "com.docker.compose.project"}} c0ffee123456' \
	'docker ps -q --filter label=com.docker.compose.project=brandeasy_devcontainer' \
	'docker stop 90ffee654321'

case_start '--stop on an already-stopped environment is a no-op'
reset_world
: >"$STATE/created"
runp --stop
rc_is 0
out_has 'already stopped'
not_called 'docker stop'

case_start '--stop with nothing ever created says so and stops nothing'
reset_world
runp --stop
rc_is 0
out_has 'nothing to stop'
not_called 'docker inspect'
not_called 'docker stop'

case_start '--stop needs neither the devcontainer CLI nor a usable Compose'
reset_world
grant docker
: >"$STATE/running"
: >"$STATE/pg_running"
DOCKER_STUB_NO_COMPOSE=1 runp --stop
rc_is 0
called 'docker stop c0ffee123456 90ffee654321'
cli_not_called devcontainer
not_called 'docker compose version'

case_start '--stop still refuses a missing docker'
reset_world
grant devcontainer
runp --stop
rc_nonzero
err_has 'Docker is not installed'
log_empty

case_start '--stop still refuses an unreachable daemon'
reset_world
: >"$STATE/running"
DOCKER_STUB_INFO_FAIL=1 runp --stop
rc_nonzero
err_has 'cannot connect to the Docker daemon'
log_is 'docker info'

case_start '--stop from a worktree stops the primary checkout environment'
reset_world
: >"$STATE/running"
: >"$STATE/pg_running"
runp --from "$WT" --stop
rc_is 0
# STUB_EXPECT_ROOT is the primary checkout, so an answered probe proves the
# any-state filter carried the primary path and not the worktree's.
called "docker ps -aq --filter label=devcontainer.local_folder=$REPO"
called 'docker stop c0ffee123456 90ffee654321'
not_called "$WT"

case_start "a failed stop propagates docker's status and diagnostic"
reset_world
: >"$STATE/running"
DOCKER_STUB_STOP_FAIL=42 runp --stop
rc_is 42
ok "the exit status is docker's own, not a flattened 1"
err_has 'cannot stop container: permission denied'

case_start 'a wedged probe never turns into a stop'
reset_world
: >"$STATE/running"
DOCKER_STUB_PS_FAIL=1 runp --stop
rc_nonzero
err_has 'docker ps failed'
err_has 'error during connect'
not_called 'docker stop'

case_start 'an unreadable project label is an error, not a silent no-op'
reset_world
: >"$STATE/created"
: >"$STATE/pg_running"
DOCKER_STUB_INSPECT_FAIL=1 runp --stop
rc_nonzero
err_has 'docker inspect failed'
err_has 'No such object'
not_called 'docker stop'

# ============================================================================
# Usage
# ============================================================================

case_start '--update and --rebuild together are refused'
reset_world
runp --update --rebuild
rc_is 2
err_has 'mutually exclusive'
err_has 'Usage: bin/dev-agent'
log_empty

case_start '--stop joins the one-mode-per-run exclusion'
reset_world
runp --stop --update
rc_is 2
err_has 'mutually exclusive'
err_has 'Usage: bin/dev-agent'
log_empty
runp --rebuild --stop
rc_is 2
err_has 'mutually exclusive'
log_empty

case_start 'an unknown argument prints usage on stderr'
reset_world
runp --wat
rc_is 2
err_has 'unknown argument: --wat'
err_has 'Usage: bin/dev-agent'
log_empty

case_start '--help prints usage on stdout and runs nothing'
reset_world
runp --help
rc_is 0
out_has 'Usage: bin/dev-agent'
out_has '--rebuild'
out_has '--stop'
log_empty

finish
