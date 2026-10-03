# shellcheck shell=bash
#
# test-helper.sh — the harness the four .devcontainer/test stub suites share.
#
# Sourced, never executed. A suite declares its subject and pulls this file in:
#
#   SUBJECT=dev-firewall                         # the script's name
#   SUBJECT_PATH=.devcontainer/sbin/dev-firewall # where it lives in the checkout
#   SUBJECT_SHELL_VAR=DEV_FIREWALL_SHELL         # optional: env var that swaps the shebang
#   . "$(dirname "${BASH_SOURCE[0]}")/test-helper.sh"
#
# Every suite runs on the host: the subjects are sh and python, both of which
# the host baseline carries, and everything privileged or networked is a stub.
# So this file sticks to POSIX utilities plus bash.
#
# What the helper owns: resolving the subject, the reporting protocol
# (die/ok/case_start/finish), the scratch world under $TMP, the safe bin, the
# scratch checkout, planting the subject into it, command capture, and the
# generic assertion vocabulary.
#
# What a suite owns: its stubs, its own world extras ($HOMEDIR, $ROOT, …), its
# `reset_world`, its `runp` (the cd and the hermetic `env -i` with its own stub
# knobs, handed to `capture`), its fixtures, and its domain assertions.
#
# The shape: stub binaries appending every invocation to one chronological call
# log, a `runp` that captures stdout/stderr/status, and an assertion vocabulary
# the cases read like prose. The subject is copied into a scratch checkout and
# invoked directly, so its real shebang is what runs.
#
# PATH is *replaced* per case rather than prepended. "docker is not installed"
# has to be genuinely true, and a host's own /usr/bin/docker leaking through
# would turn that case into a false pass. Each case therefore gets a bin
# directory holding exactly the stubs it grants, plus a farm of the system
# utilities the subject itself needs.

set -u
export LC_ALL=C

: "${SUBJECT:?a suite must set SUBJECT before sourcing test-helper.sh}"
: "${SUBJECT_PATH:?a suite must set SUBJECT_PATH before sourcing test-helper.sh}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CHECKOUT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
SRC=$CHECKOUT/$SUBJECT_PATH
[ -x "$SRC" ] || {
	echo "not executable: $SRC" >&2
	exit 1
}

# --- reporting --------------------------------------------------------------

CASE='(setup)'
CHECKS=0
OUT=''
ERR=''
RC=0

die() {
	printf 'FAIL [%s]: %s\n' "$CASE" "$1" >&2
	[ -n "$OUT" ] && printf '  stdout:\n%s\n' "$(printf '%s\n' "$OUT" | sed 's/^/    /')" >&2
	[ -n "$ERR" ] && printf '  stderr:\n%s\n' "$(printf '%s\n' "$ERR" | sed 's/^/    /')" >&2
	printf '  calls:\n%s\n' "$(calls | sed 's/^/    /')" >&2
	exit 1
}

ok() {
	CHECKS=$((CHECKS + 1))
	printf '  ok  %s\n' "$1"
}

case_start() {
	CASE="$1"
	printf '%s\n' "$CASE"
}

finish() {
	printf '\n%s checks passed\n' "$CHECKS"
}

# --- scratch world ----------------------------------------------------------

TMP=$(mktemp -d) || exit 1
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT INT TERM

STATE="$TMP/state"
STUBS="$TMP/stubs"
SAFEBIN="$TMP/safebin"
CASEBIN="$TMP/casebin"
REPO="$TMP/checkout"
mkdir -p "$STATE" "$STUBS" "$SAFEBIN" "$CASEBIN"

# File facts, across both `stat` dialects. They disagree on the flag *and* the
# format, and BSD's -f means "format" where GNU's means "file system" — so the
# obvious `stat -f … || stat -c …` fallback is a trap: GNU reads the format string
# as another file argument, exits non-zero over it, and the fallback then answers
# something plausible but wrong (`-c %m` is the mount point, identical for every
# file, which turns every mtime comparison into a vacuous pass). Probe for GNU's
# flag once instead, and use one dialect throughout.
if stat -c %Y . >/dev/null 2>&1; then
	mtime() { stat -c %Y "$1"; }
	fmode() { stat -c %a "$1"; }
else
	mtime() { stat -f %m "$1"; }
	fmode() { stat -f %Lp "$1"; }
fi

# One whitelist for all the suites, deliberately: per-suite lists drift, and a
# copy that loses `uname` produces a suite that passes while the subject is
# failing to start. Link-if-present — a utility the host lacks is simply absent
# from the safe bin and surfaces as "command not found" inside whichever case
# actually uses it. `require_tools` is how a suite states a hard requirement.
#
# Widening the list cannot leak a subject's tool: stubs live in $CASEBIN, which
# precedes $SAFEBIN on the hermetic PATH, and non-utilities (docker,
# devcontainer, herdr, …) are never whitelisted, so "not installed" stays true.
for util in git python3 grep sed awk tr cut tail head ls cat mkdir chmod rm ln sleep \
	dirname printf wc date uname timeout env sh; do
	real=$(command -v "$util") && ln -sf "$real" "$SAFEBIN/$util"
done

# require_tools <name…> — the suite's own prerequisites, checked up front so a
# missing one reads as a prerequisite rather than as a failing case.
require_tools() {
	local t
	for t in "$@"; do
		[ -x "$SAFEBIN/$t" ] || {
			echo "$t is required to run these tests" >&2
			exit 1
		}
	done
}

# --- planting ---------------------------------------------------------------

# plant <checkout> — the script under test, at the location it has to answer
# for. When the suite names a shell variable in SUBJECT_SHELL_VAR and that
# variable is set, the shebang is swapped so the same cases can run under a
# stricter interpreter than the host's /bin/sh. A suite that defines
# `plant_filter` (a filter from stdin to stdout) gets the copy passed through
# it: that is how a list the real script leaves empty is given fixture entries.
plant() {
	local dest="$1/$SUBJECT_PATH"
	mkdir -p "$(dirname "$dest")"
	local shell_name=''
	[ -n "${SUBJECT_SHELL_VAR:-}" ] && shell_name=${!SUBJECT_SHELL_VAR:-}
	if [ -n "$shell_name" ]; then
		local shell_path
		shell_path=$(command -v "$shell_name") || {
			echo "no such shell: $shell_name" >&2
			exit 1
		}
		sed "1s|.*|#!$shell_path|" "$SRC" >"$dest.unfiltered"
	else
		cp "$SRC" "$dest.unfiltered"
	fi
	if declare -F plant_filter >/dev/null; then
		plant_filter <"$dest.unfiltered" >"$dest"
	else
		cp "$dest.unfiltered" "$dest"
	fi
	rm -f "$dest.unfiltered"
	chmod +x "$dest"
}

# --- the scratch checkout ---------------------------------------------------

# A plain directory, not a git repository: nothing under test resolves anything
# through git any more. The subject sits where it does in a real copy of the
# template, so a script that derives a path from its own location is exercised.
mkdir -p "$REPO"
plant "$REPO"
printf 'baseline\n' >"$REPO/README.md"

# --- case plumbing ----------------------------------------------------------

# grant <stub>… — the case's PATH holds these stubs and nothing else executable.
grant() {
	rm -rf "$CASEBIN"
	mkdir -p "$CASEBIN"
	local s
	for s in "$@"; do
		ln -sf "$STUBS/$s" "$CASEBIN/$s"
	done
}

calls() { cat "$STATE/calls.log" 2>/dev/null; }

# capture [--cd <dir>] <cmd…> — run argv with stdout into OUT, stderr into ERR
# and status into RC. Each suite's `runp` assembles its own hermetic command
# line and ends here.
capture() {
	local dir=$PWD
	if [ "${1:-}" = --cd ]; then
		dir="$2"
		shift 2
	fi
	RC=0
	OUT=$(cd "$dir" && "$@" 2>"$TMP/stderr.txt") || RC=$?
	ERR=$(cat "$TMP/stderr.txt")
}

# --- assertions -------------------------------------------------------------

rc_is() {
	[ "$RC" = "$1" ] || die "exit status $RC, expected $1"
	ok "exit status $1"
}

rc_nonzero() {
	[ "$RC" != 0 ] || die 'exit status 0, expected a failure'
	ok "exit status $RC (non-zero)"
}

err_has() {
	printf '%s\n' "$ERR" | grep -qF -- "$1" || die "expected on stderr: $1"
	ok "stderr: $1"
}

err_hasnt() {
	printf '%s\n' "$ERR" | grep -qF -- "$1" && die "unexpected on stderr: $1"
	ok "stderr lacks: $1"
}

err_empty() {
	[ -z "$ERR" ] || die "expected nothing on stderr, got:
$ERR"
	ok 'nothing on stderr'
}

out_has() {
	printf '%s\n' "$OUT" | grep -qF -- "$1" || die "expected on stdout: $1"
	ok "stdout: $1"
}

out_hasnt() {
	printf '%s\n' "$OUT" | grep -qF -- "$1" && die "unexpected on stdout: $1"
	ok "stdout lacks: $1"
}

out_empty() {
	[ -z "$OUT" ] || die "expected no stdout, got:
$OUT"
	ok 'stdout is empty'
}

# out_has_line / out_hasnt_line — a whole line, exactly. For the lines where a
# substring would also match a longer neighbour: `provisioned: claude` is a
# prefix of `provisioned: claude permission posture`.
out_has_line() {
	printf '%s\n' "$OUT" | grep -qxF -- "$1" || die "expected stdout line: $1"
	ok "stdout line: $1"
}

out_hasnt_line() {
	printf '%s\n' "$OUT" | grep -qxF -- "$1" && die "unexpected stdout line: $1"
	ok "stdout lacks the line: $1"
}

out_counts() {
	local n
	n=$(printf '%s\n' "$OUT" | grep -cF -- "$2")
	[ "$n" -eq "$1" ] || die "expected $1 stdout line(s) matching '$2', got $n"
	ok "exactly $1 stdout line(s): $2"
}

out_matches() {
	printf '%s\n' "$OUT" | grep -qE -- "$1" || die "expected on stdout (regex): $1"
	ok "stdout matches: $1"
}

# log_is <line…> — the whole call log, in order. The strongest assertion here:
# it pins what ran *and* that nothing else did.
log_is() {
	local want
	want=$(printf '%s\n' "$@")
	[ "$(calls)" = "$want" ] || die "call log is:
$(calls)
expected:
$want"
	ok "call log is exactly $# call(s)"
}

log_empty() {
	[ -z "$(calls)" ] || die "expected no calls, got:
$(calls)"
	ok 'no external calls'
}

called() {
	calls | grep -qF -- "$1" || die "never called: $1"
	ok "called: $1"
}

not_called() {
	calls | grep -qF -- "$1" && die "should not have been called: $1"
	ok "not called: $1"
}

called_times() {
	local n
	n=$(calls | grep -cF -- "$2")
	[ "$n" -eq "$1" ] || die "expected $1 call(s) matching '$2', got $n"
	ok "exactly $1 call(s): $2"
}

# called_before <earlier> <later> — a deny floor's whole claim is that it runs
# before the fallible work, which is an ordering in the call log rather than in
# any one payload.
called_before() {
	local a b
	a=$(calls | grep -nF -- "$1" | head -1 | cut -d: -f1)
	b=$(calls | grep -nF -- "$2" | head -1 | cut -d: -f1)
	[ -n "$a" ] || die "never called: $1"
	[ -n "$b" ] || die "never called: $2"
	[ "$a" -lt "$b" ] || die "'$1' (call $a) is not before '$2' (call $b)"
	ok "call log: '$1' comes before '$2'"
}

# cli_not_called <command> — nothing in the log *is* that command. Asked of the
# log's first field, because a CLI's name can also appear inside another call's
# arguments and a substring match would happily answer "yes, it ran".
cli_not_called() {
	calls | awk -v c="$1" '$1 == c { hit = 1 } END { exit !hit }' &&
		die "the $1 CLI should not have run"
	ok "the $1 CLI never ran"
}

file_has() {
	[ -f "$1" ] || die "no such file: $1"
	grep -qF -- "$2" "$1" || die "$1 lacks: $2"
	ok "$(basename "$1"): $2"
}

file_hasnt() {
	[ -f "$1" ] || die "no such file: $1"
	grep -qF -- "$2" "$1" && die "$1 should not contain: $2"
	ok "$(basename "$1") lacks: $2"
}

# file_counts <n> <file> <regex> — regex, not fixed strings: generated files
# carry explanatory comments that mention the very directives being counted, so
# the anchors matter.
file_counts() {
	local n
	n=$(grep -cE -- "$3" "$2" 2>/dev/null || true)
	[ "$n" -eq "$1" ] || die "expected $1 line(s) matching '$3' in $2, got $n"
	ok "$(basename "$2"): exactly $1 line(s) matching $3"
}

# file_is <content> <file> — whole-file equality. Both sides go through command
# substitution so a trailing newline, which `cat` would strip from one side
# only, cannot make identical files read as different.
file_is() {
	[ -f "$2" ] || die "no such file: $2"
	[ "$(cat "$2")" = "$(printf '%s' "$1")" ] || die "$2 holds:
$(cat "$2")
expected:
$1"
	ok "$(basename "$2") holds exactly the expected content"
}

no_file() {
	[ -e "$1" ] && die "should not exist: $1"
	ok "not created: $1"
}

dir_exists() {
	[ -d "$1" ] || die "no such directory: $1"
	ok "directory exists: $1"
}

# mode_is <octal> <path> — a restrictive mode is a promise about the file on disk,
# so it is asserted as one rather than as "the chmod call was made".
mode_is() {
	local got
	got=$(fmode "$2") || die "no such path: $2"
	[ "$got" = "$1" ] || die "$2 has mode $got, expected $1"
	ok "$(basename "$2") is mode $1"
}
