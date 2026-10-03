#!/usr/bin/env bash
#
# smoke-devc.sh — the host entry point exercised against the real running
# container: the fence verbs with their identities, the allowlist push, exec,
# the doctor, and a stop/up cycle that proves the fence re-arms on every start.
# Where test-devc.sh proves devc issues the right commands, this proves the
# commands do what the verbs promise.
#
# Run it on the host, with the devcontainer for this checkout running:
#
#   bash .devcontainer/test/smoke-devc.sh
#
# It edits the tracked allowlist on the way and restores it before it ends, and
# it leaves the container running with the fence armed.

# The checks read as "assert, then report": a test or a command, then `check $?`
# with the sentence it proves. shellcheck would rather see the status checked
# directly (SC2181) and not read off a bracket test (SC2319); the idiom is the
# whole readability of this file, so both are quiet here.
# shellcheck disable=SC2181,SC2319

set -u
export LC_ALL=C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
DEVC=$ROOT/.devcontainer/host/devc
ALLOWLIST=$ROOT/.devcontainer/firewall/allowlist
BLOCKED_HOST=example.com

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

bad() {
	FAILURES=$((FAILURES + 1))
	printf '  FAIL [%s]  %s\n' "$CASE" "$1" >&2
}

check() {
	if [ "$1" = 0 ]; then ok "$2"; else bad "$2${3:+ — $3}"; fi
}

die() {
	printf 'smoke-devc: %s\n' "$1" >&2
	exit 1
}

[ -x "$DEVC" ] || die "not executable: $DEVC"
[ -n "$(docker ps -q --filter "label=devcontainer.local_folder=$ROOT")" ] ||
	die 'no devcontainer is running for this checkout — start it first (devc up)'

# The tracked allowlist is restored byte for byte, and the container's copy and
# the fence with it, however this ends.
saved=$(mktemp)
cp "$ALLOWLIST" "$saved"
restore() {
	cp "$saved" "$ALLOWLIST"
	rm -f "$saved"
	cid=$(docker ps -q --filter "label=devcontainer.local_folder=$ROOT" | head -n 1)
	if [ -n "$cid" ]; then
		docker exec -u root -i "$cid" sh -c 'cat >/etc/dev-firewall/allowlist' <"$ALLOWLIST"
		docker exec -u root "$cid" /usr/local/sbin/dev-firewall on >/dev/null 2>&1
	fi
}
trap restore EXIT INT TERM

status_says() {
	"$DEVC" firewall status | grep -E "$1" >/dev/null
}

# From inside, as dev: the fence as the agent sees it.
inside_reaches() {
	"$DEVC" exec curl -fsS -o /dev/null --max-time 20 "https://$1" 2>/dev/null
}

# ============================================================================

case_start 'exec runs as dev with the image PATH'
[ "$("$DEVC" exec id -un)" = dev ]
check $? 'devc exec runs as the dev user'
"$DEVC" exec sh -c 'case ":$PATH:" in *:/home/dev/.local/bin:*) exit 0;; *) exit 1;; esac'
check $? "the home's bin is on PATH — where the operator tools live"
"$DEVC" exec sh -c 'command -v dev-firewall >/dev/null && command -v dev-bootstrap >/dev/null'
check $? 'the engine programs resolve by name'

case_start 'the doctor sees the host and the container, tools installed through the fence'
doctor=$("$DEVC" doctor 2>&1)
printf '%s\n' "$doctor" | grep -q '^ok: container running$'
check $? 'devc doctor reaches the in-container doctor' "$doctor"
for tool in claude codex herdr; do
	printf '%s\n' "$doctor" | grep -qE "^ok: $tool( \(|$)"
	check $? "the bootstrap installed $tool into the home volume" "$doctor"
done
printf '%s\n' "$doctor" | grep -q '^ok: herdr ('
check $? 'herdr reports a version — the installer ran, not just a download'

case_start 'firewall status reports armed on a running container'
status_says '^enforcement: armed$'
check $? 'enforcement: armed'
inside_reaches "$BLOCKED_HOST"
[ $? != 0 ]
check $? "$BLOCKED_HOST is refused from inside"

case_start 'firewall off lifts enforcement as root, and on restores it'
"$DEVC" firewall off >/dev/null
check $? 'devc firewall off exits clean'
status_says '^enforcement: off$'
check $? 'status reports off'
inside_reaches "$BLOCKED_HOST"
check $? "$BLOCKED_HOST is reachable with enforcement off"
# The resolver survives `off` — that is the whole point of toggling only the
# jump, so a debugging session keeps its names and its denial annotations.
status_says '^resolver: up'
check $? 'the resolver stayed up across the toggle'
"$DEVC" firewall on >/dev/null
check $? 'devc firewall on exits clean'
status_says '^enforcement: armed$'
check $? 'status reports armed again'
inside_reaches "$BLOCKED_HOST"
[ $? != 0 ]
check $? "$BLOCKED_HOST is refused again"

case_start 'firewall allow appends, pushes and re-arms — the domain opens without a restart'
grep -qxF "$BLOCKED_HOST" "$ALLOWLIST" && die "$BLOCKED_HOST is already in the tracked allowlist; this smoke needs it absent"
output=$("$DEVC" firewall allow "$BLOCKED_HOST" 2>&1)
check $? 'devc firewall allow exits clean' "$output"
printf '%s\n' "$output" | grep -qF "appended $BLOCKED_HOST"
check $? 'it reports the append'
printf '%s\n' "$output" | grep -qF 'enforcement: armed'
check $? 'it re-armed'
[ "$(tail -n 1 "$ALLOWLIST")" = "$BLOCKED_HOST" ]
check $? 'the tracked file has the domain as its last line'
cid=$(docker ps -q --filter "label=devcontainer.local_folder=$ROOT" | head -n 1)
docker exec "$cid" cat /etc/dev-firewall/allowlist | cmp -s - "$ALLOWLIST"
check $? "the container's copy is byte for byte the tracked file"
status_says "^allowlist: .*$BLOCKED_HOST"
check $? 'status lists it'
inside_reaches "$BLOCKED_HOST"
check $? "$BLOCKED_HOST is reachable from inside now" 'the resolver fed the set from the new list'
# And the reverse: the restore pushes the saved file and re-arms, so a removal
# takes effect the same way.
cp "$saved" "$ALLOWLIST"
docker exec -u root -i "$cid" sh -c 'cat >/etc/dev-firewall/allowlist' <"$ALLOWLIST"
"$DEVC" firewall on >/dev/null
check $? 're-arming with the restored list exits clean'
inside_reaches "$BLOCKED_HOST"
[ $? != 0 ]
check $? "$BLOCKED_HOST is refused again — the ipset flush on arm makes a removal stick"

case_start 'up on a running container is a no-op'
output=$("$DEVC" up 2>&1)
check $? 'devc up exits clean' "$output"
printf '%s\n' "$output" | grep -qF 'already running'
check $? 'it says so'

case_start 'the fence re-arms on every start, not only on create'
"$DEVC" stop >/dev/null
check $? 'devc stop exits clean'
[ -z "$(docker ps -q --filter "label=devcontainer.local_folder=$ROOT")" ]
check $? 'the container is down'
"$DEVC" up >/dev/null 2>&1
check $? 'devc up brings it back'
# The compose command arms before sleeping, but `docker ps` says running as
# soon as the process exists; give the arm a moment.
armed=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
	status_says '^enforcement: armed$' 2>/dev/null && armed=0 && break
	sleep 1
done
check $armed 'enforcement: armed after a plain restart — the compose command, not a lifecycle hook, arms it'
inside_reaches "$BLOCKED_HOST"
[ $? != 0 ]
check $? "$BLOCKED_HOST is refused after the restart"

# ============================================================================

printf '\n'
if [ "$FAILURES" = 0 ]; then
	printf '%s checks passed — devc does what its verbs say\n' "$CHECKS"
	exit 0
fi
printf '%s checks passed, %s failed\n' "$CHECKS" "$FAILURES" >&2
exit 1
