#!/usr/bin/env bash
#
# test-dev-own-volumes.sh — bin/dev-own-volumes' stub matrix: the converged
# no-op that must stay quiet and privilege-free, the repair ordered so its own
# gate doubles as a completion marker, the escalation, every way a probe or a
# repair can fail, and the host guard.
#
# Run it from anywhere, on the host: bash .devcontainer/test/test-dev-own-volumes.sh
#
# `bin/dev-own-volumes` is POSIX sh on purpose, and macOS /bin/sh is bash in
# POSIX mode — permissive enough to let a bashism through. Re-run the suite
# against the strictest interpreter the shebang can land on to catch that:
#
#   DEV_OWN_VOLUMES_SHELL=dash bash .devcontainer/test/test-dev-own-volumes.sh
#
# The scratch world, the reporting protocol, the safe bin, planting and the
# generic assertions come from test-helper.sh. Divergences the subject forces,
# all of them here:
#
#   - `stat`, `id`, `chown` and `find` are stubs rather than safe-bin copies:
#     here they are the subject's *subject matter* — the ownership it reads and
#     the ownership it writes — and the host's own BSD `stat` does not even
#     speak `-c`.
#   - The mount point itself is a real directory in the scratch checkout, so
#     "the missing mount point is created" is observed rather than asserted
#     against a stub. Its *ownership* is whatever the stat stub says, which is
#     what lets an unprivileged suite exercise the non-1000 UID it could never
#     produce for real.

SUBJECT=dev-own-volumes
SUBJECT_SHELL_VAR=DEV_OWN_VOLUMES_SHELL
# shellcheck source=.devcontainer/test/test-helper.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-helper.sh"

# --- this suite's world extras ----------------------------------------------

SENTINEL="$TMP/sentinel"
: >"$SENTINEL"

# The one entry in the subject's VOLUMES list, under the primary checkout — the
# path a worktree copy has to answer for too.
VOLDIR="$REPO/node_modules"

# --- stubs ------------------------------------------------------------------

# Three questions, three answers: the caller's own uid, and the uid/gid of the
# dev account as the passwd entry currently spells it. ID_STUB_DEV_* is how a
# case says "the CLI remapped dev to 1001" without needing a second user.
cat >"$STUBS/id" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'id %s\n' "$*" >>"$S/calls.log"
[ -n "${ID_STUB_FAIL:-}" ] && {
	echo 'id stub: no such user' >&2
	exit 1
}
case "$*" in
'-u dev') printf '%s\n' "${ID_STUB_DEV_UID:-1000}" ;;
'-g dev') printf '%s\n' "${ID_STUB_DEV_GID:-1000}" ;;
-u) printf '%s\n' "${ID_STUB_UID:-0}" ;;
*)
	echo "id stub: unsupported: $*" >&2
	exit 2
	;;
esac
STUB

cat >"$STUBS/stat" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'stat %s\n' "$*" >>"$S/calls.log"
[ -n "${STAT_STUB_FAIL:-}" ] && {
	echo 'stat stub: cannot statx: Permission denied' >&2
	exit 1
}
printf '%s\n' "${STAT_STUB_OWNER:-1000:1000}"
STUB

cat >"$STUBS/chown" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'chown %s\n' "$*" >>"$S/calls.log"
[ -n "${CHOWN_STUB_FAIL:-}" ] && {
	echo 'chown stub: changing ownership: Operation not permitted' >&2
	exit 1
}
exit 0
STUB

# The descendants pass. Recorded rather than executed, so the -exec payload is
# asserted as text and the stubbed chown above stays the mount point's alone.
cat >"$STUBS/find" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'find %s\n' "$*" >>"$S/calls.log"
[ -n "${FIND_STUB_FAIL:-}" ] && {
	echo 'find stub: chown: changing ownership: Operation not permitted' >&2
	exit 1
}
exit 0
STUB

# The firewall suite's stub: -l is the grant probe, the only thing that can be
# denied here; the re-exec is recorded but never actually run, so a case can
# assert the escalation without the whole script running twice.
cat >"$STUBS/sudo" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'sudo %s\n' "$*" >>"$S/calls.log"
case " $* " in
*" -l "*) exit "${SUDO_STUB_LIST_RC:-0}" ;;
esac
exit 0
STUB

chmod +x "$STUBS"/*

# --- the case harness -------------------------------------------------------

ALL_STUBS='id stat chown find sudo'

reset_world() {
	rm -rf "$STATE" "$VOLDIR"
	mkdir -p "$STATE" "$VOLDIR"
	# shellcheck disable=SC2086
	grant $ALL_STUBS
	SENTINEL="$TMP/sentinel"
	unset ID_STUB_UID ID_STUB_DEV_UID ID_STUB_DEV_GID ID_STUB_FAIL \
		STAT_STUB_OWNER STAT_STUB_FAIL CHOWN_STUB_FAIL FIND_STUB_FAIL \
		SUDO_STUB_LIST_RC
	OUT=''
	ERR=''
	RC=0
}

# runp [--from <checkout>] <args…> — the planted script with a hermetic PATH.
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
		DEV_OWN_VOLUMES_SENTINEL="$SENTINEL" \
		${ID_STUB_UID+ID_STUB_UID="$ID_STUB_UID"} \
		${ID_STUB_DEV_UID+ID_STUB_DEV_UID="$ID_STUB_DEV_UID"} \
		${ID_STUB_DEV_GID+ID_STUB_DEV_GID="$ID_STUB_DEV_GID"} \
		${ID_STUB_FAIL+ID_STUB_FAIL="$ID_STUB_FAIL"} \
		${STAT_STUB_OWNER+STAT_STUB_OWNER="$STAT_STUB_OWNER"} \
		${STAT_STUB_FAIL+STAT_STUB_FAIL="$STAT_STUB_FAIL"} \
		${CHOWN_STUB_FAIL+CHOWN_STUB_FAIL="$CHOWN_STUB_FAIL"} \
		${FIND_STUB_FAIL+FIND_STUB_FAIL="$FIND_STUB_FAIL"} \
		${SUDO_STUB_LIST_RC+SUDO_STUB_LIST_RC="$SUDO_STUB_LIST_RC"} \
		"$from/bin/dev-own-volumes" "$@"
}

# remapped [<uid>] — the state the whole ticket is about: the passwd entry says
# 1001 while the mount point still carries the image's 1000:1000.
remapped() {
	ID_STUB_DEV_UID=1001
	ID_STUB_DEV_GID=1001
	STAT_STUB_OWNER=1000:1000
	ID_STUB_UID=${1:-0}
}

# converged [<uid>] — every host that was never broken, and every re-create
# after the first repair.
converged() {
	ID_STUB_DEV_UID=1001
	ID_STUB_DEV_GID=1001
	STAT_STUB_OWNER=1001:1001
	ID_STUB_UID=${1:-0}
}

out_empty() {
	[ -z "$OUT" ] || die "expected no stdout, got:
$OUT"
	ok 'stdout is empty'
}

dir_exists() {
	[ -d "$1" ] || die "no such directory: $1"
	ok "directory exists: $1"
}

PROBE="stat -c %u:%g $VOLDIR"
DESCENDANTS="find $VOLDIR -mindepth 1 -exec chown -h dev:dev {} +"
MOUNTPOINT="chown dev:dev $VOLDIR"

# ============================================================================
# The converged case, which is every macOS and UID-1000 Linux create
# ============================================================================

case_start 'an already-owned mount point is a silent, privilege-free no-op'
reset_world
converged 1001
runp
rc_is 0
out_empty
ok 'a routine create says nothing — only a repair is worth a line'
# Reading ownership needs no root, and this is the property that keeps a
# pre-grant image working wherever the remap never happened: the missing sudoers
# file is only fatal on the path that actually needs it.
log_is 'id -u dev' 'id -g dev' "$PROBE"
cli_not_called sudo
cli_not_called chown
cli_not_called find
ok 'nothing is escalated and nothing is written'

case_start 'the gate reads dev from the passwd entry, not from a built-in 1000'
reset_world
# The image's 1000:1000 mount point against an unremapped container: the same
# numbers, and still a no-op — but for the right reason.
ID_STUB_DEV_UID=1000 ID_STUB_DEV_GID=1000 STAT_STUB_OWNER=1000:1000 \
	ID_STUB_UID=1000 runp
rc_is 0
out_empty
called 'id -u dev'
called 'id -g dev'
cli_not_called chown

# ============================================================================
# The repair
# ============================================================================

case_start 'a remapped container repairs descendants first and the mount point last'
reset_world
remapped 0
runp
rc_is 0
out_has 'owned: node_modules (dev, 1001:1001)'
log_is 'id -u dev' 'id -g dev' "$PROBE" 'id -u' "$DESCENDANTS" "$MOUNTPOINT"
ok 'the caller uid is read only once a repair is actually needed'

case_start 'the mount point is chowned last, so the gate is also the completion marker'
# A run killed mid-chown has to leave the top level unchanged: the next create
# then sees a mismatch and repairs the rest, instead of reading a converged top
# level as "done" over half-owned contents.
called_before "$DESCENDANTS" "$MOUNTPOINT"
called_times 1 "$DESCENDANTS"
called_times 1 "$MOUNTPOINT"
cli_not_called sudo
ok 'a root run never escalates a second time'

case_start 'a missing mount point is created, owned, and then left alone'
reset_world
rm -rf "$VOLDIR"
remapped 0
runp
rc_is 0
dir_exists "$VOLDIR"
ok 'the parent is the writable bind mount, so seeding it needs no root'
out_has 'owned: node_modules'
: >"$STATE/calls.log"
converged 0
runp
rc_is 0
out_empty
cli_not_called chown
cli_not_called find
ok 'the second create is idempotent — the repair does not repeat'

# ============================================================================
# Escalation
# ============================================================================

case_start 'an unprivileged repair escalates through the one sudoers grant'
reset_world
remapped 1001
runp
rc_is 0
log_is 'id -u dev' 'id -g dev' "$PROBE" 'id -u' \
	"sudo -n -l $REPO/bin/dev-own-volumes" \
	"sudo -n $REPO/bin/dev-own-volumes"
ok 'nothing is attempted unprivileged first'
cli_not_called chown
cli_not_called find
ok 'the unprivileged run writes nothing itself'

case_start 'a worktree copy escalates the primary checkout, which is what sudoers names'
reset_world
remapped 1001
runp --from "$WT"
rc_is 0
log_is 'id -u dev' 'id -g dev' "$PROBE" 'id -u' \
	"sudo -n -l $REPO/bin/dev-own-volumes" \
	"sudo -n $REPO/bin/dev-own-volumes"
not_called "$WT"
ok 'the worktree path never appears — neither sudoers nor the volume is there'

case_start 'a missing sudoers grant names the fix instead of the symptom'
reset_world
remapped 1001
SUDO_STUB_LIST_RC=1 runp
rc_nonzero
err_has 'could not escalate'
err_has '/etc/sudoers.d/dev-own-volumes'
err_has 'bin/dev-agent --rebuild'
log_is 'id -u dev' 'id -g dev' "$PROBE" 'id -u' \
	"sudo -n -l $REPO/bin/dev-own-volumes"
ok 'the grant is probed before the run, so a failed chown is not misreported'

# ============================================================================
# Every failure is loud: postCreate must fail rather than half-succeed
# ============================================================================

case_start 'an unreadable mount point fails instead of guessing'
reset_world
remapped 0
STAT_STUB_FAIL=1 runp
rc_nonzero
err_has 'cannot read the ownership of'
err_has "$VOLDIR"
cli_not_called chown
cli_not_called find
cli_not_called sudo
ok 'an unknown owner is never rounded to "probably fine"'

case_start 'an unresolvable dev account fails before anything is inspected'
reset_world
remapped 0
ID_STUB_FAIL=1 runp
rc_nonzero
err_has "cannot read the dev user's uid"
log_is 'id -u dev'
ok 'the target ownership is unknowable, so nothing is chowned to a guess'
cli_not_called stat
cli_not_called chown

case_start 'a failed descendants pass never touches the mount point'
reset_world
remapped 0
FIND_STUB_FAIL=1 runp
rc_nonzero
err_has 'cannot chown the contents of'
out_hasnt 'owned:'
ok 'a failed repair never reads as success on stdout'
cli_not_called chown
ok 'the mount point keeps its old owner, so the next create retries the repair'

case_start 'a failed mount-point chown fails the create'
reset_world
remapped 0
CHOWN_STUB_FAIL=1 runp
rc_nonzero
err_has "cannot chown $VOLDIR"
out_hasnt 'owned:'
called "$DESCENDANTS"
ok 'the descendants pass ran; only the last step failed'

# ============================================================================
# The host guard
# ============================================================================

case_start 'without the container sentinel it refuses to run'
reset_world
# An absent path rather than an unset variable: on a Linux host that is itself
# inside a container, /.dockerenv exists and the default would pass.
SENTINEL="$TMP/no-such-sentinel"
remapped 0
runp
rc_nonzero
err_has 'not inside a container'
err_has 'must never run on the host'
log_empty
ok 'nothing on the host was inspected, let alone chowned'

case_start 'the guard holds even where there would be nothing to do'
reset_world
SENTINEL="$TMP/no-such-sentinel"
converged 0
runp
rc_nonzero
err_has 'not inside a container'
log_empty

# ============================================================================
# Usage
# ============================================================================

case_start 'an unknown argument prints usage on stderr'
reset_world
remapped 0
runp --wat
rc_is 2
err_has 'unknown argument: --wat'
err_has 'Usage: bin/dev-own-volumes'
log_empty
ok 'a mistyped invocation never chowns anything'

case_start 'a borrowed subcommand is refused rather than ignored'
reset_world
remapped 0
# bin/dev-firewall takes `on`; muscle memory will try it here, and silently
# doing the one thing this script does would teach the wrong lesson.
runp on
rc_is 2
err_has 'unknown argument: on'
log_empty

case_start '--help prints usage on stdout and runs nothing'
reset_world
SENTINEL="$TMP/no-such-sentinel"
runp --help
rc_is 0
out_has 'Usage: bin/dev-own-volumes'
out_has 'Idempotent'
log_empty
ok 'help works outside the container too — it is the one thing that must'

finish
