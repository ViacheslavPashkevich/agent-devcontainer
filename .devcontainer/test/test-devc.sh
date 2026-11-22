#!/usr/bin/env bash
#
# test-devc.sh — devc's stub matrix: the daily path cold and warm, each verb,
# the fence verbs and the identities they run as, the allowlist push, the port
# listing and its tunnels, every prerequisite failure, and the usage errors.
#
# Run it from anywhere, on the host: bash .devcontainer/test/test-devc.sh
#
# `devc` is POSIX sh on purpose, and macOS `/bin/sh` is bash in POSIX mode —
# permissive enough to let a bashism through. Re-run the suite against the
# strictest interpreter the shebang can land on to catch that:
#
#   DEVC_SHELL=dash bash .devcontainer/test/test-devc.sh
#
# The scratch world, the reporting protocol, the safe bin, planting and the
# generic assertions come from test-helper.sh; what stays here is devc's own:
# the docker and devcontainer stubs, the tracked allowlist fixture, and the
# cases.

SUBJECT=devc
SUBJECT_PATH=.devcontainer/host/devc
SUBJECT_SHELL_VAR=DEVC_SHELL
# shellcheck source=.devcontainer/test/test-helper.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-helper.sh"

# --- this suite's world extras ----------------------------------------------

ALLOWLIST="$REPO/.devcontainer/firewall/allowlist"
ALLOWLIST_FIXTURE='# fixture
github.com
npmjs.org   # trailing comment
'

# --- stubs ------------------------------------------------------------------

cat >"$STUBS/docker" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
# exec's stdin is the allowlist push, so it is drained before logging — a stub
# that logged first would race nothing here, but it would also leave the
# payload unread.
case "${1:-} ${2:-} ${3:-}" in
"exec -u root") case "$*" in *" -i "*) pushed=$(cat) ;; esac ;;
esac
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
	*" label=com.docker.compose.project=checkout_devcontainer "*)
		# The project-wide probe the stop path issues: one id per line, and
		# the two containers are independently up or down.
		[ -e "$S/running" ] && echo 'c0ffee123456'
		[ -e "$S/svc_running" ] && echo '90ffee654321'
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
	" ps -aq ")
		# The port scan's listing: every container on the host. The ids are
		# only handed back to inspect, which answers from the fixture.
		{ [ -e "$S/running" ] || [ -e "$S/scan" ]; } && echo 'c0ffee123456'
		;;
	esac
	;;
"inspect "*)
	[ -n "${DOCKER_STUB_INSPECT_FAIL:-}" ] && {
		echo 'docker stub: Error: No such object: c0ffee123456' >&2
		exit 1
	}
	case "$*" in
	*'C|'*)
		# The port scan: its format is the only one that emits C lines. A case
		# plants what the host holds in $S/scan; without one the host holds
		# this checkout's container alone, publishing the T3 port on loopback.
		[ -n "${DOCKER_STUB_SCAN_FAIL:-}" ] && {
			echo 'docker stub: Error: No such object' >&2
			exit 1
		}
		if [ -e "$S/scan" ]; then
			cat "$S/scan"
		else
			printf 'C|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|%s\n' "$STUB_EXPECT_ROOT"
			printf 'P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3774/tcp|127.0.0.1|3774\n'
		fi
		;;
	*) echo 'checkout_devcontainer' ;;
	esac
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
	rm -f "$S/running" "$S/svc_running"
	;;
"exec "*)
	case "$*" in
	*" -i "*)
		# The allowlist push: what arrived is kept for the case to compare.
		printf '%s\n' "$pushed" >"$S/pushed-allowlist"
		[ -n "${DOCKER_STUB_PUSH_FAIL:-}" ] && exit 1
		;;
	*)
		echo "docker stub: ran in the container: $*"
		exit "${DOCKER_STUB_EXEC_RC:-0}"
		;;
	esac
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
	;;
exec)
	echo 'devcontainer stub: exec output'
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

# --- the case harness -------------------------------------------------------

reset_world() {
	rm -rf "$STATE"
	mkdir -p "$STATE" "$(dirname "$ALLOWLIST")"
	printf '%s' "$ALLOWLIST_FIXTURE" >"$ALLOWLIST"
	grant docker devcontainer
	unset DOCKER_STUB_INFO_FAIL DOCKER_STUB_NO_COMPOSE DOCKER_STUB_PS_FAIL \
		DOCKER_STUB_COMPOSE_VERSION DOCKER_STUB_INSPECT_FAIL \
		DOCKER_STUB_STOP_FAIL DOCKER_STUB_EXEC_RC DOCKER_STUB_PUSH_FAIL \
		DOCKER_STUB_SCAN_FAIL STUB_SSH_CONNECTION \
		DEVCONTAINER_STUB_UP_FAIL DEVCONTAINER_STUB_EXEC_RC
	OUT=''
	ERR=''
	RC=0
}

# runp <args…> — run the planted script with a hermetic PATH. From a
# subdirectory of the checkout, deliberately: the root has to come from the
# script's own location, never from the caller's working directory. The ssh
# session is a knob of its own name: the suite may itself be running over ssh,
# and that session must not leak into the cases.
runp() {
	capture --cd "$REPO/.devcontainer" env -i \
		PATH="$CASEBIN:$SAFEBIN" \
		HOME="$TMP" \
		USER=operator \
		${STUB_SSH_CONNECTION+SSH_CONNECTION="$STUB_SSH_CONNECTION"} \
		${DOCKER_STUB_SCAN_FAIL+DOCKER_STUB_SCAN_FAIL="$DOCKER_STUB_SCAN_FAIL"} \
		STUB_STATE="$STATE" \
		STUB_EXPECT_ROOT="$REPO" \
		${DOCKER_STUB_INFO_FAIL+DOCKER_STUB_INFO_FAIL="$DOCKER_STUB_INFO_FAIL"} \
		${DOCKER_STUB_NO_COMPOSE+DOCKER_STUB_NO_COMPOSE="$DOCKER_STUB_NO_COMPOSE"} \
		${DOCKER_STUB_PS_FAIL+DOCKER_STUB_PS_FAIL="$DOCKER_STUB_PS_FAIL"} \
		${DOCKER_STUB_COMPOSE_VERSION+DOCKER_STUB_COMPOSE_VERSION="$DOCKER_STUB_COMPOSE_VERSION"} \
		${DOCKER_STUB_INSPECT_FAIL+DOCKER_STUB_INSPECT_FAIL="$DOCKER_STUB_INSPECT_FAIL"} \
		${DOCKER_STUB_STOP_FAIL+DOCKER_STUB_STOP_FAIL="$DOCKER_STUB_STOP_FAIL"} \
		${DOCKER_STUB_EXEC_RC+DOCKER_STUB_EXEC_RC="$DOCKER_STUB_EXEC_RC"} \
		${DOCKER_STUB_PUSH_FAIL+DOCKER_STUB_PUSH_FAIL="$DOCKER_STUB_PUSH_FAIL"} \
		${DEVCONTAINER_STUB_UP_FAIL+DEVCONTAINER_STUB_UP_FAIL="$DEVCONTAINER_STUB_UP_FAIL"} \
		${DEVCONTAINER_STUB_EXEC_RC+DEVCONTAINER_STUB_EXEC_RC="$DEVCONTAINER_STUB_EXEC_RC"} \
		"$REPO/$SUBJECT_PATH" "$@"
}

PREREQS_DOCKER='docker info'
PREREQS_CLI='docker compose version --short'
PROBE="docker ps -q --filter label=devcontainer.local_folder=$REPO"
UP="devcontainer up --workspace-folder $REPO"
ATTACH="devcontainer exec --workspace-folder $REPO herdr"
FW_STATUS='docker exec -u dev c0ffee123456 /usr/local/sbin/dev-firewall status'
FW_ON='docker exec -u dev c0ffee123456 /usr/local/sbin/dev-firewall on'
FW_OFF='docker exec -u root c0ffee123456 /usr/local/sbin/dev-firewall off'
FW_ON_ROOT='docker exec -u root c0ffee123456 /usr/local/sbin/dev-firewall on'
FW_PUSH='docker exec -u root -i c0ffee123456 sh -c cat >/etc/dev-firewall/allowlist'
SCAN_LIST='docker ps -aq'
SCAN_INSPECT='docker inspect -f {{$p := index .Config.Labels'
HOSTNAME_HERE=$(uname -n)

# scan <<'EOF' … — what the port scan finds on the host: C, E and P lines as
# docker inspect emits them, with @ROOT@ standing for this checkout.
scan() {
	sed "s|@ROOT@|$REPO|g" >"$STATE/scan"
}

# ============================================================================
# The daily path
# ============================================================================

case_start 'bare devc, cold: probe, then up, then attach — in that order'
reset_world
runp
rc_is 0
log_is "$PREREQS_DOCKER" "$PREREQS_CLI" "$PROBE" "$UP" "$ATTACH"
out_has 'streamed build output'
ok 'the cold start streams the build output rather than swallowing it'

case_start 'bare devc, warm: the container is running, so nothing touches its state'
reset_world
: >"$STATE/running"
runp
rc_is 0
not_called 'devcontainer up'
called_times 1 'devcontainer '
called "$ATTACH"

case_start 'the root is the checkout, resolved from the script, not from the cwd'
# runp runs from .devcontainer/, and the probe and the attach both carry the
# checkout: two levels up from .devcontainer/host/ is the folder the CLI
# labelled, whatever directory the operator typed `devc` in.
called "$PROBE"
called "$ATTACH"
not_called "$REPO/.devcontainer "
ok 'the working directory never leaks into the container identity'

case_start 'a second run is a no-op apart from the attach'
reset_world
runp
rc_is 0
called 'devcontainer up'
: >"$STATE/calls.log"
runp
rc_is 0
log_is "$PREREQS_DOCKER" "$PREREQS_CLI" "$PROBE" "$ATTACH"

case_start 'the attach exit status is the script exit status'
reset_world
: >"$STATE/running"
DEVCONTAINER_STUB_EXEC_RC=3 runp
rc_is 3
err_hasnt 'not available inside the container'
DEVCONTAINER_STUB_EXEC_RC=0 runp
rc_is 0
ok 'a detach (herdr exits 0) is a successful run'

case_start 'a missing attach command is explained, not silently replaced by a shell'
reset_world
: >"$STATE/running"
DEVCONTAINER_STUB_EXEC_RC=127 runp
rc_is 127
err_has '`herdr` is not available inside the container'
err_has 'bootstrap did not finish'
err_has 'devc exec zsh'
err_has 'devc doctor'
called_times 1 'devcontainer exec'
ok 'no second exec: the operator chooses the shell, devc does not fall back to one'
DEVCONTAINER_STUB_EXEC_RC=126 runp
rc_is 126
err_has 'not available inside the container'

# ============================================================================
# up and attach on their own
# ============================================================================

case_start 'up starts a cold container and does not attach'
reset_world
runp up
rc_is 0
log_is "$PREREQS_DOCKER" "$PREREQS_CLI" "$PROBE" "$UP"
not_called 'devcontainer exec'

case_start 'up on a running container says so and does nothing'
reset_world
: >"$STATE/running"
runp up
rc_is 0
out_has 'already running'
not_called 'devcontainer up'
not_called 'devcontainer exec'

case_start 'attach on a running container attaches and nothing else'
reset_world
: >"$STATE/running"
runp attach
rc_is 0
log_is "$PREREQS_DOCKER" "$PREREQS_CLI" "$PROBE" "$ATTACH"

case_start 'attach on a stopped container fails plainly instead of starting it'
reset_world
runp attach
rc_nonzero
err_has 'not running'
err_has 'devc up'
not_called 'devcontainer up'
not_called 'devcontainer exec'
ok 'attach never starts anything — that is what up is for'

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
called "$ATTACH"

case_start 'an unreadable compose version warns and continues'
reset_world
: >"$STATE/running"
DOCKER_STUB_COMPOSE_VERSION=weird-string runp
rc_is 0
err_has 'cannot read the Docker Compose version (weird-string); continuing'
called "$ATTACH"

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
# rebuild
# ============================================================================

case_start 'rebuild recreates from scratch and attaches'
reset_world
: >"$STATE/running"
runp rebuild
rc_is 0
log_is "$PREREQS_DOCKER" "$PREREQS_CLI" \
	"$UP --remove-existing-container --build-no-cache" \
	"$ATTACH"
ok 'no warm probe: the point of the verb is to recreate the running container'

case_start 'a failed rebuild never attaches'
reset_world
DEVCONTAINER_STUB_UP_FAIL=1 runp rebuild
rc_nonzero
called 'devcontainer up'
not_called 'devcontainer exec'

# ============================================================================
# stop
# ============================================================================

case_start 'stop stops every running container of the compose project'
reset_world
: >"$STATE/running"
: >"$STATE/svc_running"
runp stop
rc_is 0
log_is \
	'docker info' \
	"docker ps -aq --filter label=devcontainer.local_folder=$REPO" \
	'docker inspect -f {{index .Config.Labels "com.docker.compose.project"}} c0ffee123456' \
	'docker ps -q --filter label=com.docker.compose.project=checkout_devcontainer' \
	'docker stop c0ffee123456 90ffee654321'
ok "a project's own services go down with the app container, and no devcontainer CLI call happens"

case_start 'stop cleans up a half-stopped environment'
reset_world
# The app container exists but is down; a project service is still running.
: >"$STATE/created"
: >"$STATE/svc_running"
runp stop
rc_is 0
# An exact log, not a called/not_called pair: the point is that the stopped
# app id is *not* also handed to `docker stop`.
log_is \
	'docker info' \
	"docker ps -aq --filter label=devcontainer.local_folder=$REPO" \
	'docker inspect -f {{index .Config.Labels "com.docker.compose.project"}} c0ffee123456' \
	'docker ps -q --filter label=com.docker.compose.project=checkout_devcontainer' \
	'docker stop 90ffee654321'

case_start 'stop on an already-stopped environment is a no-op'
reset_world
: >"$STATE/created"
runp stop
rc_is 0
out_has 'already stopped'
not_called 'docker stop'

case_start 'stop with nothing ever created says so and stops nothing'
reset_world
runp stop
rc_is 0
out_has 'nothing to stop'
not_called 'docker inspect'
not_called 'docker stop'

case_start 'stop needs neither the devcontainer CLI nor a usable Compose'
reset_world
grant docker
: >"$STATE/running"
: >"$STATE/svc_running"
DOCKER_STUB_NO_COMPOSE=1 runp stop
rc_is 0
called 'docker stop c0ffee123456 90ffee654321'
cli_not_called devcontainer
not_called 'docker compose version'

case_start 'stop still refuses a missing docker'
reset_world
grant devcontainer
runp stop
rc_nonzero
err_has 'Docker is not installed'
log_empty

case_start 'stop still refuses an unreachable daemon'
reset_world
: >"$STATE/running"
DOCKER_STUB_INFO_FAIL=1 runp stop
rc_nonzero
err_has 'cannot connect to the Docker daemon'
log_is 'docker info'

case_start "a failed stop propagates docker's status and diagnostic"
reset_world
: >"$STATE/running"
DOCKER_STUB_STOP_FAIL=42 runp stop
rc_is 42
ok "the exit status is docker's own, not a flattened 1"
err_has 'cannot stop container: permission denied'

case_start 'a wedged probe never turns into a stop'
reset_world
: >"$STATE/running"
DOCKER_STUB_PS_FAIL=1 runp stop
rc_nonzero
err_has 'docker ps failed'
err_has 'error during connect'
not_called 'docker stop'

case_start 'an unreadable project label is an error, not a silent no-op'
reset_world
: >"$STATE/created"
: >"$STATE/svc_running"
DOCKER_STUB_INSPECT_FAIL=1 runp stop
rc_nonzero
err_has 'docker inspect failed'
err_has 'No such object'
not_called 'docker stop'

# ============================================================================
# The fence verbs
# ============================================================================

case_start 'firewall status runs the in-container report as dev'
reset_world
: >"$STATE/running"
runp firewall status
rc_is 0
log_is 'docker info' "$PROBE" "$FW_STATUS"
out_has 'ran in the container'
cli_not_called devcontainer
ok 'docker only: the fence verbs choose an identity, which the devcontainer CLI cannot'

case_start 'firewall on re-arms as dev — the grant covers it'
reset_world
: >"$STATE/running"
runp firewall on
rc_is 0
log_is 'docker info' "$PROBE" "$FW_ON"

case_start 'firewall off runs as root — the one identity the grant leaves it to'
reset_world
: >"$STATE/running"
runp firewall off
rc_is 0
log_is 'docker info' "$PROBE" "$FW_OFF"
not_called '-u dev'
ok 'the agent identity never lifts the fence, not even by way of this script'

case_start 'the fence verbs propagate the in-container status'
reset_world
: >"$STATE/running"
DOCKER_STUB_EXEC_RC=1 runp firewall status
rc_is 1

case_start 'the fence verbs refuse a stopped container plainly'
reset_world
runp firewall status
rc_nonzero
err_has 'not running'
err_has 'devc up'
not_called 'docker exec'
runp firewall off
rc_nonzero
err_has 'not running'
not_called 'docker exec'

case_start 'firewall allow appends to the tracked file, pushes it, and re-arms as root'
reset_world
: >"$STATE/running"
runp firewall allow example.com
rc_is 0
out_has 'appended example.com to .devcontainer/firewall/allowlist'
out_has 'commit it'
# Append-only: the fixture's comments survive, the new line is last.
file_has "$ALLOWLIST" '# fixture'
file_has "$ALLOWLIST" 'npmjs.org   # trailing comment'
[ "$(tail -n 1 "$ALLOWLIST")" = example.com ] || die "the new domain is not the last line:
$(cat "$ALLOWLIST")"
ok 'the domain is appended as its own last line'
log_is 'docker info' "$PROBE" "$FW_PUSH" "$FW_ON_ROOT"
# The push carries the *whole* tracked file, so the container's copy is exactly
# what a rebuild would install.
[ "$(cat "$STATE/pushed-allowlist")" = "$(cat "$ALLOWLIST")" ] || die "the pushed file differs from the tracked one:
$(cat "$STATE/pushed-allowlist")"
ok 'the file pushed into the container is byte-for-byte the tracked file'
cli_not_called devcontainer

case_start 'a domain already listed is not appended twice, but the push still happens'
reset_world
: >"$STATE/running"
runp firewall allow npmjs.org
rc_is 0
out_has 'npmjs.org is already in .devcontainer/firewall/allowlist'
file_counts 1 "$ALLOWLIST" '^npmjs.org'
ok 'the trailing comment on the existing line does not hide the entry'
called "$FW_PUSH"
called "$FW_ON_ROOT"
ok 'the operator asked for the fence to allow it, so the running container is made to agree'

case_start 'firewall allow on a stopped container appends and says the next start arms with it'
reset_world
runp firewall allow example.org
rc_is 0
out_has 'appended example.org'
out_has 'not running'
out_has 'next start'
[ "$(tail -n 1 "$ALLOWLIST")" = example.org ] || die 'the domain was not appended'
ok 'the durable half — the tracked file — is done regardless'
not_called 'docker exec'

case_start 'firewall allow validates the domain before touching anything'
reset_world
: >"$STATE/running"
for bad in 'https://example.com' 'example.com/path' '*.example.com' 'Example.com' \
	'example' '.example.com' 'example.com.' 'exa..mple.com' 'exa mple.com'; do
	runp firewall allow "$bad"
	rc_nonzero
	err_has "not a bare domain: $bad"
done
err_has 'like example.com'
file_is "$ALLOWLIST_FIXTURE" "$ALLOWLIST"
ok 'nine malformed shapes, and the tracked file is untouched'
log_empty
ok 'no docker call either — validation comes first'

case_start 'firewall allow accepts hyphens, digits and deep suffixes'
reset_world
runp firewall allow playwright.download.prss.microsoft.com
rc_is 0
runp firewall allow my-cdn-2.example.io
rc_is 0
file_has "$ALLOWLIST" 'playwright.download.prss.microsoft.com'
file_has "$ALLOWLIST" 'my-cdn-2.example.io'

case_start 'a failed push stops before re-arming'
reset_world
: >"$STATE/running"
DOCKER_STUB_PUSH_FAIL=1 runp firewall allow example.com
rc_nonzero
err_has 'could not write the allowlist into the container'
called "$FW_PUSH"
not_called "$FW_ON_ROOT"
ok 'the tracked file has the line; the container is left as it was, to be re-armed by hand'

case_start 'the fence verbs need docker, not the devcontainer CLI'
reset_world
grant docker
: >"$STATE/running"
DOCKER_STUB_NO_COMPOSE=1 runp firewall off
rc_is 0
called "$FW_OFF"
ok 'lifting a wedged fence never waits on the CLI'

# ============================================================================
# exec and doctor
# ============================================================================

case_start 'exec runs the command inside through the devcontainer CLI, as dev'
reset_world
: >"$STATE/running"
runp exec dev-bootstrap --update-tools
rc_is 0
log_is "$PREREQS_DOCKER" "$PREREQS_CLI" "$PROBE" \
	"devcontainer exec --workspace-folder $REPO dev-bootstrap --update-tools"
ok 'the arguments arrive untouched'

case_start 'exec propagates the status and refuses a stopped container'
reset_world
: >"$STATE/running"
DEVCONTAINER_STUB_EXEC_RC=7 runp exec false
rc_is 7
reset_world
runp exec zsh
rc_nonzero
err_has 'not running'
not_called 'devcontainer exec'

case_start 'doctor reports the host, then hands over to the in-container doctor'
reset_world
: >"$STATE/running"
runp doctor
rc_is 0
out_has 'ok: docker'
out_has 'ok: docker daemon'
out_has 'ok: devcontainer CLI'
out_has 'ok: docker compose (2.27.0)'
out_has 'ok: container running'
out_has 'ok: host ports'
out_hasnt 'missing: '
called "devcontainer exec --workspace-folder $REPO /usr/local/bin/dev-bootstrap --doctor"
ok 'the same ok:/missing: protocol as inside, so the two halves read as one report'

case_start 'doctor finds a port number another project also publishes'
reset_world
: >"$STATE/running"
scan <<'EOF'
C|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|@ROOT@
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3774/tcp|127.0.0.1|3774
C|other_devcontainer|app|/other_devcontainer-app-1|true|/srv/other
P|other_devcontainer|app|/other_devcontainer-app-1|true|3774/tcp|100.64.0.9|3774
P|other_devcontainer|app|/other_devcontainer-app-1|true|3775/tcp|100.64.0.9|3775
EOF
runp doctor
rc_is 1
out_has 'missing: host ports of its own'
out_has '    port 3774 is also published by other (on 100.64.0.9)'
out_has 'next free: 3776'
out_has 'devc ports show-all'
out_hasnt 'ok: host ports'
called "devcontainer exec --workspace-folder $REPO /usr/local/bin/dev-bootstrap --doctor"
ok 'a finding on the host does not hide what the inside has to say'
DEVCONTAINER_STUB_EXEC_RC=0 runp doctor
rc_is 1
ok 'a clean inside does not clear the finding'

case_start 'doctor says so when docker cannot list the ports'
reset_world
: >"$STATE/running"
DOCKER_STUB_SCAN_FAIL=1 runp doctor
rc_is 1
out_has 'missing: host ports'
out_has 'docker could not list the containers'
called "devcontainer exec --workspace-folder $REPO /usr/local/bin/dev-bootstrap --doctor"

case_start 'doctor on a stopped container is a finding, and the inside is not consulted'
reset_world
runp doctor
rc_is 1
out_has 'missing: container'
out_has 'devc up'
not_called 'devcontainer exec'

case_start 'doctor reports a missing CLI instead of dying over it'
reset_world
grant docker
runp doctor
rc_is 1
out_has 'ok: docker'
out_has 'missing: devcontainer CLI'
out_has 'npm install -g @devcontainers/cli'
err_empty
not_called 'docker ps'
ok 'a report, not a refusal — and nothing beyond the host is probed'

case_start 'doctor reports a missing docker and an old compose'
reset_world
grant devcontainer
runp doctor
rc_is 1
out_has 'missing: docker'
out_has 'ok: devcontainer CLI'
reset_world
DOCKER_STUB_COMPOSE_VERSION=2.20.0 runp doctor
rc_is 1
out_has 'missing: docker compose'
out_has 'Docker Compose >= 2.24 required (found 2.20.0)'

# ============================================================================
# ports
# ============================================================================

case_start 'ports show lists what this project publishes, read from docker'
reset_world
: >"$STATE/running"
scan <<'EOF'
C|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|@ROOT@
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3774/tcp|100.64.0.5|3774
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3036/tcp|127.0.0.1|3036
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3000/tcp|127.0.0.1|3001
C|checkout_devcontainer|postgres|/checkout_devcontainer-postgres-1|true|<no value>
P|checkout_devcontainer|postgres|/checkout_devcontainer-postgres-1|true|5432/tcp|127.0.0.1|5433
C|checkout_devcontainer|redis|/checkout_devcontainer-redis-1|true|
EOF
runp ports show
rc_is 0
err_empty
out_has_line "checkout — $REPO"
out_has_line '  SERVICE   INSIDE  PUBLISHED        URL'
out_has_line '  app       3000    127.0.0.1:3001   http://localhost:3001   (tunnel)'
out_has_line '  app       3036    127.0.0.1:3036   http://localhost:3036   (tunnel)'
out_has_line '  app       3774    100.64.0.5:3774  http://100.64.0.5:3774  T3 Code'
out_has_line '  postgres  5432    127.0.0.1:5433   localhost:5433          (tunnel)'
ok 'a loopback port is reached through the tunnel, a published address directly'
ok 'a database gets an address, not a URL a browser would choke on'
out_has_line "  tunnel: ssh -N -L 3001:127.0.0.1:3001 -L 3036:127.0.0.1:3036 -L 5433:127.0.0.1:5433 operator@$HOSTNAME_HERE"
ok 'the tunnel forwards each loopback port to the same number, in port order'
out_hasnt '3774:'
ok 'a port already on a reachable address is not forwarded'
out_hasnt 'note:'
[ "$(calls | wc -l)" -eq 3 ] || die "expected 3 calls, got: $(calls)"
called "$PREREQS_DOCKER"
called "$SCAN_LIST"
called "$SCAN_INSPECT"
cli_not_called devcontainer
ok 'one listing and one inspect, and the devcontainer CLI is never needed'

case_start 'over ssh, the tunnel names the address the client dialled'
STUB_SSH_CONNECTION='203.0.113.7 51234 100.64.0.1 22' runp ports show
rc_is 0
out_has ' operator@100.64.0.1'
out_hasnt ' -p '
STUB_SSH_CONNECTION='203.0.113.7 51234 100.64.0.1 2222' runp ports show
out_has ' -p 2222 operator@100.64.0.1'
ok 'a non-default ssh port is carried into the command'

case_start 'ports show reads the T3 port, wildcard publishes and udp as they are'
reset_world
scan <<'EOF'
C|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|@ROOT@
E|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|T3_PORT=3770
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3770/tcp|127.0.0.1|3770
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3774/tcp|127.0.0.1|3774
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|8080/tcp|0.0.0.0|8080
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|8080/tcp|::|8080
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|9999/udp|127.0.0.1|9999
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|4000/tcp||
EOF
STUB_SSH_CONNECTION='203.0.113.7 51234 100.64.0.1 22' runp ports show
rc_is 0
out_has_line '  app      3770    127.0.0.1:3770  http://localhost:3770   (tunnel)  T3 Code'
out_has_line '  app      3774    127.0.0.1:3774  http://localhost:3774   (tunnel)'
ok 'T3 Code is the port the container was told, not the default'
out_has_line '  app      8080    0.0.0.0:8080    http://100.64.0.1:8080'
out_counts 1 '8080'
ok 'a port on every address is reached at the host itself, and its IPv6 twin is not a second row'
out_has_line '  app      9999    127.0.0.1:9999  udp only'
out_hasnt '9999:'
ok 'udp is listed and left out of the tunnel, which cannot carry it'
out_hasnt '4000'
ok 'a port docker has not assigned is not invented'

case_start 'ports show notes a number another project also publishes'
reset_world
scan <<'EOF'
C|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|@ROOT@
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3774/tcp|127.0.0.1|3774
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3000/tcp|127.0.0.1|3000
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|8000/tcp|127.0.0.1|8000
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|9000/tcp|127.0.0.1|9000
C|alpha_devcontainer|app|/alpha_devcontainer-app-1|true|/srv/alpha
P|alpha_devcontainer|app|/alpha_devcontainer-app-1|true|3774/tcp|100.64.0.9|3774
P|alpha_devcontainer|app|/alpha_devcontainer-app-1|true|3775/tcp|100.64.0.9|3775
C|beta_devcontainer|app|/beta_devcontainer-app-1|false|/srv/beta
P|beta_devcontainer|app|/beta_devcontainer-app-1|false|3000/tcp||3000
C|<no value>|<no value>|/leftover|false|<no value>
P|<no value>|<no value>|/leftover|false|8000/tcp|127.0.0.1|8000
C||<no value>|/standalone|true|
P||<no value>|/standalone|true|9000/tcp|127.0.0.1|9000
EOF
runp ports show
rc_is 0
out_has_line '  note: port 3774 is also published by alpha (on 100.64.0.9) — both start, but 3774 no longer names one project; next free: 3776'
ok 'the same number on another address still starts, and is still worth changing'
out_has_line '  note: port 3000 is also published by beta — the two cannot run at once; next free: 3001'
ok 'a devcontainer that is stopped still owns its ports'
out_has_line '  note: port 9000 is also published by standalone — the two cannot run at once; next free: 9001'
ok 'a running container outside compose counts, under its own name'
out_hasnt 'port 8000 is also'
ok 'an exited one-off container owns nothing'
out_counts 3 'note:'

case_start 'ports show-all lists every devcontainer on the host, by name'
runp ports show-all
rc_is 0
out_has_line "checkout — $REPO"
out_has_line 'alpha — /srv/alpha'
out_has_line 'beta — /srv/beta (stopped)'
printf '%s\n' "$OUT" | grep -qE '^(standalone|leftover) ' && die 'a container that is not a devcontainer got a listing'
ok 'containers that are not devcontainers are not listed'
[ "$(printf '%s\n' "$OUT" | grep -E '^[a-z]+ — ' | cut -d' ' -f1 | tr '\n' ' ')" = 'alpha beta checkout ' ] ||
	die 'the projects are not in name order'
ok 'in name order, so the listing reads the same on every run'
out_has_line '  app      3000    0.0.0.0:3000  http://'"$HOSTNAME_HERE"':3000'
ok 'a stopped project shows the ports it is configured to publish'
out_has_line '  note: port 3774 is also published by checkout (on 127.0.0.1) — both start, but 3774 no longer names one project; next free: 3776'
out_has_line "every tunnel at once: ssh -N -L 3000:127.0.0.1:3000 -L 3774:127.0.0.1:3774 -L 8000:127.0.0.1:8000 -L 9000:127.0.0.1:9000 operator@$HOSTNAME_HERE"

case_start 'ports show with nothing on loopback offers no tunnel'
reset_world
scan <<'EOF'
C|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|@ROOT@
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|3774/tcp|100.64.0.5|3774
EOF
runp ports show
rc_is 0
out_has '100.64.0.5:3774'
out_hasnt 'tunnel'

case_start 'ports show on a stopped or unpublished project still answers'
reset_world
scan <<'EOF'
C|checkout_devcontainer|app|/checkout_devcontainer-app-1|false|@ROOT@
P|checkout_devcontainer|app|/checkout_devcontainer-app-1|false|3774/tcp|127.0.0.1|3774
EOF
runp ports show
rc_is 0
out_has_line "checkout — $REPO (stopped)"
out_has '127.0.0.1:3774'
scan <<'EOF'
C|checkout_devcontainer|app|/checkout_devcontainer-app-1|true|@ROOT@
EOF
runp ports show
rc_is 0
out_has_line '  no published ports'

case_start 'ports show without a container for this checkout fails plainly'
reset_world
runp ports show
rc_nonzero
err_has 'no devcontainer exists for this checkout'
err_has 'devc up'
out_empty
scan <<'EOF'
C|alpha_devcontainer|app|/alpha_devcontainer-app-1|true|/srv/alpha
P|alpha_devcontainer|app|/alpha_devcontainer-app-1|true|3000/tcp|127.0.0.1|3002
EOF
runp ports show
rc_nonzero
err_has 'no devcontainer exists for this checkout'
ok "another project's container is not mistaken for this one"
runp ports show-all
rc_is 0
out_has_line 'alpha — /srv/alpha'
ok 'show-all answers from any checkout, with or without a container of its own'

case_start 'ports refuses to guess when docker cannot answer'
reset_world
: >"$STATE/running"
DOCKER_STUB_PS_FAIL=1 runp ports show
rc_nonzero
err_has 'docker could not list the containers'
out_empty
DOCKER_STUB_SCAN_FAIL=1 runp ports show
rc_nonzero
err_has 'docker could not list the containers'
out_empty

case_start 'ports needs docker, not the devcontainer CLI'
reset_world
grant docker
: >"$STATE/running"
DOCKER_STUB_NO_COMPOSE=1 runp ports show
rc_is 0
out_has '127.0.0.1:3774'
not_called 'compose version'

# ============================================================================
# Usage
# ============================================================================

case_start 'an unknown verb prints usage on stderr'
reset_world
runp wat
rc_is 2
err_has 'unknown verb: wat'
err_has 'Usage: devc'
log_empty

case_start 'the old flags are not verbs'
reset_world
runp --stop
rc_is 2
err_has 'unknown verb: --stop'
log_empty

case_start 'a verb with stray arguments is refused'
reset_world
runp up now
rc_is 2
err_has 'up takes no arguments'
log_empty
runp firewall status please
rc_is 2
err_has 'firewall status takes no arguments'
log_empty

case_start 'firewall without a subcommand, or with an unknown one, is a usage error'
reset_world
runp firewall
rc_is 2
err_has 'firewall needs a subcommand'
runp firewall disarm
rc_is 2
err_has 'unknown firewall subcommand: disarm'
runp firewall allow
rc_is 2
err_has 'firewall allow takes exactly one domain'
runp firewall allow a.com b.com
rc_is 2
err_has 'firewall allow takes exactly one domain'
log_empty

case_start 'ports without a subcommand, or with an unknown one, is a usage error'
reset_world
runp ports
rc_is 2
err_has 'ports needs a subcommand: show or show-all'
runp ports all
rc_is 2
err_has 'unknown ports subcommand: all'
runp ports --all
rc_is 2
err_has 'unknown ports subcommand: --all'
runp ports show all
rc_is 2
err_has 'ports show takes no arguments'
runp ports show-all now
rc_is 2
err_has 'ports show-all takes no arguments'
log_empty

case_start 'exec without a command is a usage error'
reset_world
runp exec
rc_is 2
err_has 'exec needs a command'
log_empty

case_start '--help prints usage on stdout and runs nothing'
reset_world
runp --help
rc_is 0
out_has 'Usage: devc'
out_has 'devc rebuild'
out_has 'devc firewall allow <domain>'
out_has 'devc ports show '
out_has 'devc ports show-all'
out_has 'devc exec dev-bootstrap --update-tools'
out_hasnt 'update '
log_empty
runp -h
rc_is 0
out_has 'Usage: devc'

finish
