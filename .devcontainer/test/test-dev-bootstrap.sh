#!/usr/bin/env bash
#
# test-dev-bootstrap.sh — dev-bootstrap's stub matrix: a fresh home volume
# provisioned end to end (operator tools included), a second run that writes
# nothing, --update-tools, reconciliation over files somebody else owns, the
# doctor's report for every missing-credential combination, the failures that
# must never be swallowed, and the host guard.
#
# Run it from anywhere, on the host: bash .devcontainer/test/test-dev-bootstrap.sh
#
# The subject is Python with the standard library only, so the host's python3 is
# its interpreter here and nothing else is needed. The scratch world, the
# reporting protocol, the safe bin, planting and the generic assertions come
# from test-helper.sh. Divergences the subject forces:
#
#   - HOME is a scratch directory recreated per case — that is the fresh home
#     volume, the state this script exists to provision — and its .local/bin
#     leads the hermetic PATH, as the image's PATH does.
#   - The safe bin's `python3` is the subject's own interpreter, not a stub.
#     Its subprocesses — npm, curl, the herdr installer, herdr, codex, claude,
#     git, ssh-keygen and ssh — are the stubs, except git, which is real: the
#     identity steps are about what lands in .gitconfig.
#   - The npm and curl stubs *install*: they plant the tool stubs into the
#     scratch home's .local/bin, so "the binaries appear on PATH after the
#     install" is observed, and an installer that lies can be simulated.
#   - Every stub prints chatter on every call, so "the doctor's output is exactly
#     its ok/missing protocol" is asserted against output that would leak if the
#     script ever streamed a probe.

SUBJECT=dev-bootstrap
SUBJECT_PATH=.devcontainer/bin/dev-bootstrap
# shellcheck source=.devcontainer/test/test-helper.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-helper.sh"

require_tools python3 git

# --- this suite's world extras ----------------------------------------------

HOMEDIR="$TMP/home"
LOCAL_BIN="$HOMEDIR/.local/bin"
SENTINEL="$TMP/sentinel"
: >"$SENTINEL"

# The generation call, pinned once and shared by the cases that assert it. `$*`
# in the stub joins argv with single spaces, so ssh-keygen's empty `-N` value —
# the whole "no passphrase" contract — shows up as a doubled space. It is spelled
# with an empty variable so no reformatting can quietly collapse it.
EMPTY=''
KEYGEN_CALL="ssh-keygen -t rsa -b 4096 -N $EMPTY -C devcontainer -q -f $HOMEDIR/.ssh/id_devcontainer.provision"

# The doctor's probe, likewise pinned once: BatchMode (cannot prompt, cannot
# accept a host key) and ConnectTimeout (cannot hang) appear in every call log
# that carries it, which is where "the probe is non-interactive" is asserted.
PROBE_GITHUB='ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github.com'

# The installs. The npm one is exact; the curl one ends in a temporary path, so
# it is matched as a prefix, and the installer logs its own line once it runs.
NPM_INSTALL="npm install -g --prefix $HOMEDIR/.local @anthropic-ai/claude-code @openai/codex"
CURL_INSTALLER='curl -fsSL https://herdr.dev/install.sh -o '
HERDR_INSTALLER_RAN="herdr-installer HERDR_INSTALL_DIR=$LOCAL_BIN"

# --- stubs ------------------------------------------------------------------

cat >"$STUBS/herdr" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'herdr %s\n' "$*" >>"$S/calls.log"
case "${1:-} ${2:-}" in
"--version ")
	echo 'herdr 0.9.0'
	;;
"integration status")
	# Chatter on stdout, deliberately: a script that streamed this probe would
	# fail the output assertions instead of passing them quietly.
	echo 'herdr stub: reading integration state'
	for t in claude codex; do
		if [ -e "$S/herdr-$t" ]; then
			printf '%s: current (v7) (/home/dev/.%s/herdr-agent-state.sh)\n' "$t" "$t"
		else
			printf '%s: not installed (/home/dev/.%s/herdr-agent-state.sh)\n' "$t" "$t"
		fi
	done
	# The real CLI reports every target it knows, not just these two.
	echo 'cursor: not installed (/home/dev/.cursor/herdr-agent-state.sh)'
	;;
"integration install")
	t=${3:?}
	[ -n "${HERDR_STUB_INSTALL_FAIL:-}" ] && {
		echo "herdr stub: install failed for $t" >&2
		exit 1
	}
	# The real CLI installs its hook into the harness's own home directory and
	# refuses when that directory is absent — which is every fresh home volume.
	# Observed against herdr 0.8.0 in the container; without it the suite would
	# pass a script that fails container creation on a fresh machine.
	[ -d "$HOME/.$t" ] || {
		echo "$t directory not found at $HOME/.$t. install $t code first" >&2
		exit 1
	}
	echo "herdr stub: installed the $t hook"
	: >"$S/herdr-$t"
	;;
*)
	echo "herdr stub: unsupported: $*" >&2
	exit 2
	;;
esac
exit 0
STUB

cat >"$STUBS/codex" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'codex %s\n' "$*" >>"$S/calls.log"
case "${1:-} ${2:-}" in
"--version ")
	echo 'codex-cli 0.50.0'
	exit 0
	;;
"login status")
	echo 'codex stub: Logged in using ChatGPT'
	exit "${CODEX_STUB_LOGIN_RC:-1}"
	;;
*)
	echo "codex stub: unsupported: $*" >&2
	exit 2
	;;
esac
STUB

cat >"$STUBS/claude" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'claude %s\n' "$*" >>"$S/calls.log"
case "${1:-}" in
--version)
	[ -n "${CLAUDE_STUB_VERSION_FAIL:-}" ] && exit 1
	echo '2.1.0 (Claude Code)'
	exit 0
	;;
*)
	echo "claude stub: unsupported: $*" >&2
	exit 2
	;;
esac
STUB

# The npm registry, as far as this suite is concerned: a global install with a
# prefix plants the two harness stubs into <prefix>/bin, the way the real thing
# links its binaries there. NPM_STUB_FAIL fails it; NPM_STUB_ELSEWHERE installs
# into the wrong directory and still exits 0, which is the lie the subject has
# to catch.
cat >"$STUBS/npm" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'npm %s\n' "$*" >>"$S/calls.log"
echo 'npm stub: fetching packages'
[ -n "${NPM_STUB_FAIL:-}" ] && {
	echo 'npm stub: ERR! network request failed' >&2
	exit 1
}
prefix=''
prev=''
for a in "$@"; do
	[ "$prev" = --prefix ] && prefix=$a
	prev=$a
done
[ -n "$prefix" ] || {
	echo 'npm stub: no --prefix' >&2
	exit 2
}
[ -n "${NPM_STUB_ELSEWHERE:-}" ] && prefix="$prefix/elsewhere"
mkdir -p "$prefix/bin"
ln -sf "${STUB_DIR:?}/claude" "$prefix/bin/claude"
ln -sf "${STUB_DIR:?}/codex" "$prefix/bin/codex"
exit 0
STUB

# herdr.dev, as far as this suite is concerned: `curl -o <file>` writes an
# installer script there, and that script — run by the subject through /bin/sh,
# with HERDR_INSTALL_DIR in its environment — plants the herdr stub and logs
# that it ran. CURL_STUB_FAIL fails the download; HERDR_INSTALLER_STUB_FAIL
# makes the installer fail; HERDR_INSTALLER_STUB_ELSEWHERE makes it ignore the
# directory it was given and still exit 0.
cat >"$STUBS/curl" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'curl %s\n' "$*" >>"$S/calls.log"
echo 'curl stub: downloading'
[ -n "${CURL_STUB_FAIL:-}" ] && {
	echo 'curl stub: (6) Could not resolve host: herdr.dev' >&2
	exit 6
}
out=''
prev=''
for a in "$@"; do
	[ "$prev" = -o ] && out=$a
	prev=$a
done
[ -n "$out" ] || {
	echo 'curl stub: no -o' >&2
	exit 2
}
cat >"$out" <<'INSTALLER'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'herdr-installer HERDR_INSTALL_DIR=%s\n' "${HERDR_INSTALL_DIR:-unset}" >>"$S/calls.log"
echo 'herdr installer stub: installing'
[ -n "${HERDR_INSTALLER_STUB_FAIL:-}" ] && {
	echo 'herdr installer stub: no release for this platform' >&2
	exit 1
}
dir=${HERDR_INSTALL_DIR:?}
[ -n "${HERDR_INSTALLER_STUB_ELSEWHERE:-}" ] && dir="$dir/../elsewhere"
mkdir -p "$dir"
ln -sf "${STUB_DIR:?}/herdr" "$dir/herdr"
exit 0
INSTALLER
exit 0
STUB

cat >"$STUBS/ssh-keygen" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'ssh-keygen %s\n' "$*" >>"$S/calls.log"
echo 'ssh-keygen stub: generating a key'
# -f <path> is where the real tool writes the pair.
path=''
while [ $# -gt 0 ]; do
	[ "$1" = -f ] && path=${2:?}
	shift
done
[ -n "$path" ] || {
	echo 'ssh-keygen stub: no -f argument' >&2
	exit 2
}
# The private half first, and before the failure check: an interrupted real run
# leaves exactly this behind, so the caller's cleanup has something to clean and
# "no leftovers" is a real assertion.
printf 'PARTIAL\n' >"$path"
[ -n "${SSH_KEYGEN_STUB_FAIL:-}" ] && {
	echo 'ssh-keygen stub: generation failed' >&2
	exit 1
}
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n' >"$path"
printf 'ssh-rsa AAAAfixture devcontainer\n' >"$path.pub"
# Deliberately whatever the umask gives: the suite proves the *script* converges
# the 0600, not the tool that happens to create the file that way.
exit 0
STUB

cat >"$STUBS/ssh" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'ssh %s\n' "$*" >>"$S/calls.log"
# Chatter on stdout, as everywhere here: a doctor that streamed its probe would
# fail the protocol-is-the-whole-output assertions.
echo 'ssh stub: connecting'
target=''
for a in "$@"; do target=$a; done
case "$target" in
*github.com) verdict=${SSH_STUB_GITHUB:-unregistered} ;;
*)
	echo "ssh stub: unsupported target: $target" >&2
	exit 2
	;;
esac
# Real wording and real exit statuses, because the verdicts are derived from
# both. Note that success is non-zero at GitHub.
case "$verdict" in
authenticated)
	echo "Hi fixture! You've successfully authenticated, but GitHub does not provide shell access." >&2
	exit 1
	;;
shell-refused)
	# A provider that refuses the shell without a message of its own, so ssh
	# reports the refusal itself. Authentication already succeeded by then.
	echo 'shell request failed on channel 0' >&2
	exit 255
	;;
unregistered)
	echo "$target: Permission denied (publickey)." >&2
	exit 255
	;;
unknown-host)
	echo 'Host key verification failed.' >&2
	exit 255
	;;
expired)
	echo 'remote: Authentication failed: your SSH key has expired.' >&2
	exit 255
	;;
*)
	echo "ssh stub: unknown verdict: $verdict" >&2
	exit 2
	;;
esac
STUB

chmod +x "$STUBS"/*

# --- the case harness -------------------------------------------------------

# The tools as a previous bootstrap left them: on the home's own bin, which is
# where the real installs land. A case about a *fresh* volume leaves them out
# and lets the npm and curl stubs put them there.
install_tools() {
	mkdir -p "$LOCAL_BIN"
	ln -sf "$STUBS/claude" "$LOCAL_BIN/claude"
	ln -sf "$STUBS/codex" "$LOCAL_BIN/codex"
	ln -sf "$STUBS/herdr" "$LOCAL_BIN/herdr"
}

reset_world() {
	rm -rf "$STATE" "$HOMEDIR"
	mkdir -p "$STATE" "$HOMEDIR"
	install_tools
	grant npm curl ssh-keygen ssh
	SENTINEL="$TMP/sentinel"
	unset HERDR_STUB_INSTALL_FAIL CODEX_STUB_LOGIN_RC CLAUDE_STUB_VERSION_FAIL \
		NPM_STUB_FAIL NPM_STUB_ELSEWHERE CURL_STUB_FAIL \
		HERDR_INSTALLER_STUB_FAIL HERDR_INSTALLER_STUB_ELSEWHERE \
		SSH_KEYGEN_STUB_FAIL SSH_STUB_GITHUB \
		GIT_USER_NAME GIT_USER_EMAIL
	OUT=''
	ERR=''
	RC=0
}

# The things the script cannot provision itself, as fixtures.
give_claude_auth() {
	mkdir -p "$HOMEDIR/.claude"
	printf '{"claudeAiOauth":{"accessToken":"fixture"}}\n' >"$HOMEDIR/.claude/.credentials.json"
}

give_codex_auth() { CODEX_STUB_LOGIN_RC=0; }

give_identity_env() {
	GIT_USER_NAME='Fixture Operator'
	GIT_USER_EMAIL='operator@example.com'
}

# The identity as already-provisioned state, for the cases that check without
# provisioning: --doctor seeds nothing, so the env variables alone leave it
# missing.
give_identity_config() {
	env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
		git config --global user.name 'The Operator'
	env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
		git config --global user.email 'operator@example.com'
}

# The registration the bootstrap cannot do itself, as a fixture.
give_ssh_ok() { SSH_STUB_GITHUB=authenticated; }

give_everything() {
	give_claude_auth
	give_codex_auth
	give_identity_env
	give_ssh_ok
}

# runp <args…> — run the planted script with a hermetic PATH and a hermetic
# HOME. The home's .local/bin leads, as in the image; the subject's
# `#!/usr/bin/env python3` resolves through the safe bin. GIT_CONFIG_NOSYSTEM
# keeps /etc/gitconfig from answering the identity checks.
runp() {
	capture --cd "$REPO" env -i \
		PATH="$LOCAL_BIN:$CASEBIN:$SAFEBIN" \
		HOME="$HOMEDIR" \
		GIT_CONFIG_NOSYSTEM=1 \
		STUB_STATE="$STATE" \
		STUB_DIR="$STUBS" \
		DEV_BOOTSTRAP_SENTINEL="$SENTINEL" \
		${HERDR_STUB_INSTALL_FAIL+HERDR_STUB_INSTALL_FAIL="$HERDR_STUB_INSTALL_FAIL"} \
		${CODEX_STUB_LOGIN_RC+CODEX_STUB_LOGIN_RC="$CODEX_STUB_LOGIN_RC"} \
		${CLAUDE_STUB_VERSION_FAIL+CLAUDE_STUB_VERSION_FAIL="$CLAUDE_STUB_VERSION_FAIL"} \
		${NPM_STUB_FAIL+NPM_STUB_FAIL="$NPM_STUB_FAIL"} \
		${NPM_STUB_ELSEWHERE+NPM_STUB_ELSEWHERE="$NPM_STUB_ELSEWHERE"} \
		${CURL_STUB_FAIL+CURL_STUB_FAIL="$CURL_STUB_FAIL"} \
		${HERDR_INSTALLER_STUB_FAIL+HERDR_INSTALLER_STUB_FAIL="$HERDR_INSTALLER_STUB_FAIL"} \
		${HERDR_INSTALLER_STUB_ELSEWHERE+HERDR_INSTALLER_STUB_ELSEWHERE="$HERDR_INSTALLER_STUB_ELSEWHERE"} \
		${SSH_KEYGEN_STUB_FAIL+SSH_KEYGEN_STUB_FAIL="$SSH_KEYGEN_STUB_FAIL"} \
		${SSH_STUB_GITHUB+SSH_STUB_GITHUB="$SSH_STUB_GITHUB"} \
		${GIT_USER_NAME+GIT_USER_NAME="$GIT_USER_NAME"} \
		${GIT_USER_EMAIL+GIT_USER_EMAIL="$GIT_USER_EMAIL"} \
		"$REPO/$SUBJECT_PATH" "$@"
}

# gitconfig <key> — the global config the run wrote, read the same hermetic way.
gitconfig() {
	env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
		git config --global --get "$1" 2>/dev/null
}

gitconfig_all() {
	env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
		git config --global --get-all "$1" 2>/dev/null
}

# claude_mode / claude_key — read the settings file the way claude does, so a
# file that merely contains the right substring cannot pass.
claude_mode() {
	python3 -c '
import json, sys
print(json.dumps((json.load(open(sys.argv[1])).get("permissions") or {}).get("defaultMode")))
' "$HOMEDIR/.claude/settings.json"
}

claude_key() {
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d[int(k)] if k.isdigit() else d[k]
print(json.dumps(d))
' "$HOMEDIR/.claude/settings.json" "$@"
}

claude_mode_is() {
	local got
	got=$(claude_mode) || die 'settings.json does not parse as JSON'
	[ "$got" = "\"$1\"" ] || die "claude defaultMode is $got, expected \"$1\""
	ok "claude permissions.defaultMode is \"$1\""
}

claude_key_is() {
	local want=$1 got
	shift
	got=$(claude_key "$@") || die 'settings.json does not parse as JSON'
	[ "$got" = "$want" ] || die "settings.json $* is $got, expected $want"
	ok "settings.json keeps $* = $want"
}

tool_on_path() {
	[ -L "$LOCAL_BIN/$1" ] || [ -x "$LOCAL_BIN/$1" ] || die "$1 did not land in $LOCAL_BIN"
	ok "$1 is installed at $LOCAL_BIN/$1"
}

# ============================================================================
# A fresh home volume
# ============================================================================

case_start 'a fresh home volume gets the tools, integrations, posture, identity, safe.directory and the ssh identity'
reset_world
rm -rf "$HOMEDIR/.local"
give_everything
runp
rc_is 0
# The installs come first: everything after them runs the tools they install.
called "$NPM_INSTALL"
called "$CURL_INSTALLER"
called "$HERDR_INSTALLER_RAN"
called_before "$NPM_INSTALL" 'herdr integration status'
called_before "$HERDR_INSTALLER_RAN" 'herdr integration status'
ok 'both channels run before anything that needs the tools'
out_has_line 'provisioned: claude'
out_has_line 'provisioned: codex'
out_has_line 'provisioned: herdr'
tool_on_path claude
tool_on_path codex
tool_on_path herdr
ok 'the installs land in the home volume, where a rebuild cannot touch them'
called 'herdr integration status'
called 'herdr integration install claude'
called 'herdr integration install codex'
called "$KEYGEN_CALL"
called 'codex login status'
called "$PROBE_GITHUB"
ok 'the key is generated with the intended type and size, and with no passphrase'
ok 'the probe is non-interactive and bounded: BatchMode and ConnectTimeout'
out_has 'provisioned: herdr integration (claude)'
out_has 'provisioned: herdr integration (codex)'
ok 'the harness home directories exist before herdr installs into them'
out_has 'provisioned: claude permission posture'
out_has 'provisioned: codex permission posture'
out_has 'provisioned: git user.name'
out_has 'provisioned: git user.email'
out_has "provisioned: git safe.directory ('*')"
claude_mode_is bypassPermissions
file_has "$HOMEDIR/.codex/config.toml" 'approval_policy = "never"'
file_has "$HOMEDIR/.codex/config.toml" 'sandbox_mode = "danger-full-access"'
[ "$(gitconfig user.name)" = 'Fixture Operator' ] || die "git user.name is '$(gitconfig user.name)'"
ok 'git user.name comes from GIT_USER_NAME'
[ "$(gitconfig user.email)" = 'operator@example.com' ] || die "git user.email is '$(gitconfig user.email)'"
ok 'git user.email comes from GIT_USER_EMAIL'
[ "$(gitconfig_all safe.directory)" = '*' ] || die "safe.directory is '$(gitconfig_all safe.directory)'"
ok "safe.directory lists '*'"
out_has 'provisioned: ssh key (~/.ssh/id_devcontainer, RSA-4096)'
out_has 'provisioned: ssh config (github.com)'
file_has "$HOMEDIR/.ssh/id_devcontainer" 'BEGIN OPENSSH PRIVATE KEY'
file_has "$HOMEDIR/.ssh/id_devcontainer.pub" 'ssh-rsa'
mode_is 700 "$HOMEDIR/.ssh"
mode_is 600 "$HOMEDIR/.ssh/id_devcontainer"
# The atomic-generation contract: the pair is written to .provision names and
# renamed, so a crash mid-generation can never leave a half-pair that the next
# run reads as converged.
no_file "$HOMEDIR/.ssh/id_devcontainer.provision"
no_file "$HOMEDIR/.ssh/id_devcontainer.provision.pub"
file_has "$HOMEDIR/.ssh/config" 'Host github.com'
file_counts 1 "$HOMEDIR/.ssh/config" '^  IdentityFile ~/\.ssh/id_devcontainer$'
file_counts 1 "$HOMEDIR/.ssh/config" '^  IdentitiesOnly yes$'
# Host-key verification stays the operator's: no known-hosts file, and nothing
# that would weaken the client's default strict checking.
no_file "$HOMEDIR/.ssh/known_hosts"
file_hasnt "$HOMEDIR/.ssh/config" 'StrictHostKeyChecking'
file_hasnt "$HOMEDIR/.ssh/config" 'UserKnownHostsFile'
out_counts 7 'ok: '
out_hasnt 'missing: '
ok 'the doctor is clean once every credential is in place'
out_has 'ok: claude (2.1.0 (Claude Code))'
out_has 'ok: codex (codex-cli 0.50.0)'
out_has 'ok: herdr (herdr 0.9.0)'
ok 'the report names the installed versions'
out_hasnt 'npm stub:'
out_hasnt 'curl stub:'
out_hasnt 'installer stub:'
out_hasnt 'ssh-keygen stub:'
out_hasnt 'ssh stub:'
out_hasnt 'herdr stub:'
ok 'neither the installers nor the probes leak chatter into the output'

case_start 'a second run changes nothing'
# Continues from the case above deliberately: the state under test is exactly
# what the first run left behind.
before_settings=$(mtime "$HOMEDIR/.claude/settings.json")
before_codex=$(mtime "$HOMEDIR/.codex/config.toml")
before_gitconfig=$(mtime "$HOMEDIR/.gitconfig")
before_sshconfig=$(mtime "$HOMEDIR/.ssh/config")
before_sshkey=$(mtime "$HOMEDIR/.ssh/id_devcontainer")
before_sshpub=$(mtime "$HOMEDIR/.ssh/id_devcontainer.pub")
settings_body=$(cat "$HOMEDIR/.claude/settings.json")
codex_body=$(cat "$HOMEDIR/.codex/config.toml")
gitconfig_body=$(cat "$HOMEDIR/.gitconfig")
sshconfig_body=$(cat "$HOMEDIR/.ssh/config")
sshkey_body=$(cat "$HOMEDIR/.ssh/id_devcontainer")
# mtime has second granularity, so a rewrite inside the same second would be
# invisible; the gap is what gives the assertion teeth.
sleep 1
: >"$STATE/calls.log"
runp
rc_is 0
log_is \
	'herdr integration status' \
	'claude --version' \
	'codex --version' \
	'herdr --version' \
	'codex login status' \
	"$PROBE_GITHUB"
ok 'the tools are present, so neither installer runs; the integrations report current, so install never runs again'
not_called 'ssh-keygen'
ok 'the existing key is never regenerated'
out_hasnt 'provisioned: '
[ "$(mtime "$HOMEDIR/.claude/settings.json")" = "$before_settings" ] || die 'settings.json was rewritten'
ok 'settings.json is untouched'
[ "$(mtime "$HOMEDIR/.codex/config.toml")" = "$before_codex" ] || die 'config.toml was rewritten'
ok 'config.toml is untouched'
[ "$(mtime "$HOMEDIR/.gitconfig")" = "$before_gitconfig" ] || die '.gitconfig was rewritten'
ok '.gitconfig is untouched'
[ "$(mtime "$HOMEDIR/.ssh/config")" = "$before_sshconfig" ] || die 'the ssh config was rewritten'
[ "$(mtime "$HOMEDIR/.ssh/id_devcontainer")" = "$before_sshkey" ] || die 'the ssh key was rewritten'
[ "$(mtime "$HOMEDIR/.ssh/id_devcontainer.pub")" = "$before_sshpub" ] || die 'the public key was rewritten'
ok 'the ssh config and both key halves are untouched'
[ "$(cat "$HOMEDIR/.claude/settings.json")" = "$settings_body" ] || die 'settings.json content changed'
[ "$(cat "$HOMEDIR/.codex/config.toml")" = "$codex_body" ] || die 'config.toml content changed'
[ "$(cat "$HOMEDIR/.gitconfig")" = "$gitconfig_body" ] || die '.gitconfig content changed'
[ "$(cat "$HOMEDIR/.ssh/config")" = "$sshconfig_body" ] || die 'the ssh config content changed'
[ "$(cat "$HOMEDIR/.ssh/id_devcontainer")" = "$sshkey_body" ] || die 'the ssh key content changed'
ok 'every managed file is byte-identical'
[ "$(gitconfig_all safe.directory | grep -cFx '*')" = 1 ] || die "safe.directory gained a duplicate:
$(gitconfig_all safe.directory)"
ok "safe.directory still has exactly one '*' entry"

# ============================================================================
# The operator tools
# ============================================================================

case_start 'only the missing tool is installed'
reset_world
rm -f "$LOCAL_BIN/herdr"
give_everything
runp
rc_is 0
cli_not_called npm
called "$CURL_INSTALLER"
called "$HERDR_INSTALLER_RAN"
out_has_line 'provisioned: herdr'
out_hasnt_line 'provisioned: claude'
out_hasnt_line 'provisioned: codex'
tool_on_path herdr
ok 'the npm channel is left alone when both its tools are present'
reset_world
rm -f "$LOCAL_BIN/codex"
give_everything
runp
rc_is 0
called "$NPM_INSTALL"
cli_not_called curl
out_has_line 'provisioned: codex'
out_hasnt_line 'provisioned: claude'
ok 'one npm tool missing runs the one npm install, and only the missing tool is reported'

case_start 'the herdr installer is downloaded to a file and run, never piped'
reset_world
rm -f "$LOCAL_BIN/herdr"
give_everything
runp
rc_is 0
called_before "$CURL_INSTALLER" "$HERDR_INSTALLER_RAN"
ok 'download completes before anything executes'
installer_path=$(calls | sed -n 's/^curl -fsSL https:\/\/herdr.dev\/install.sh -o //p')
[ -n "$installer_path" ] || die 'the installer path was not captured'
no_file "$installer_path"
ok 'the downloaded installer is removed afterwards'

case_start '--update-tools reinstalls all three and refreshes the integrations, and nothing else'
reset_world
give_everything
runp
rc_is 0
: >"$STATE/calls.log"
sleep 1
before_settings=$(mtime "$HOMEDIR/.claude/settings.json")
runp --update-tools
rc_is 0
called "$NPM_INSTALL"
called "$CURL_INSTALLER"
called "$HERDR_INSTALLER_RAN"
out_has_line 'updated: claude'
out_has_line 'updated: codex'
out_has_line 'updated: herdr'
out_hasnt 'provisioned: '
called 'herdr integration status'
ok 'the integrations are re-checked: a new herdr may install its hooks differently'
out_hasnt 'ok: '
out_hasnt 'missing: '
not_called 'codex login status'
not_called 'ssh'
ok 'no doctor: updating tools is not a credentials check'
[ "$(mtime "$HOMEDIR/.claude/settings.json")" = "$before_settings" ] || die 'settings.json was rewritten'
ok 'the posture is not touched'

case_start '--update-tools refreshes an integration that stopped reporting current'
reset_world
give_everything
runp
rc_is 0
rm -f "$STATE/herdr-codex"
: >"$STATE/calls.log"
runp --update-tools
rc_is 0
called 'herdr integration install codex'
not_called 'herdr integration install claude'
out_has 'provisioned: herdr integration (codex)'

case_start 'a failed npm install is fatal, names both tools, and the other steps still run'
reset_world
rm -rf "$HOMEDIR/.local"
give_everything
NPM_STUB_FAIL=1 runp
rc_nonzero
err_has 'could not install the operator tools: claude, codex'
err_has 'npm stub: ERR! network request failed'
out_hasnt_line 'provisioned: claude'
# The step is one unit, so herdr's install is not attempted after npm failed;
# the following steps still run, and the doctor then reports the three tools
# missing.
cli_not_called curl
out_has_line 'missing: claude'
out_has_line 'missing: codex'
out_has_line 'missing: herdr'
out_matches '^ +dev-bootstrap$'
ok 'the doctor names the tools and the one command that installs them'
claude_mode_is bypassPermissions
ok 'the posture still lands'

case_start 'a failed download, and a failed installer, are both failures'
reset_world
rm -f "$LOCAL_BIN/herdr"
give_everything
CURL_STUB_FAIL=1 runp
rc_nonzero
err_has 'could not install the operator tools: herdr'
err_has 'Could not resolve host: herdr.dev'
not_called 'herdr-installer'
out_hasnt_line 'provisioned: herdr'
reset_world
rm -f "$LOCAL_BIN/herdr"
give_everything
HERDR_INSTALLER_STUB_FAIL=1 runp
rc_nonzero
err_has 'could not install the operator tools: herdr'
err_has 'no release for this platform'
out_hasnt_line 'provisioned: herdr'
out_has_line 'missing: herdr'

case_start 'an installer that exits 0 without putting the tool on PATH is a failure'
reset_world
rm -rf "$HOMEDIR/.local"
give_everything
NPM_STUB_ELSEWHERE=1 runp
rc_nonzero
err_has 'could not install the operator tools: claude, codex'
err_has 'did not appear on PATH'
err_has "$LOCAL_BIN"
out_hasnt_line 'provisioned: claude'
reset_world
rm -f "$LOCAL_BIN/herdr"
give_everything
HERDR_INSTALLER_STUB_ELSEWHERE=1 runp
rc_nonzero
err_has 'could not install the operator tools: herdr'
err_has 'did not appear on PATH'
out_hasnt_line 'provisioned: herdr'
ok "an installer's exit status is not convergence — the binary on PATH is"

# ============================================================================
# Reconciling files somebody else owns
# ============================================================================

case_start 'a stale posture is reconciled without clobbering the neighbours'
reset_world
give_everything
mkdir -p "$HOMEDIR/.claude" "$HOMEDIR/.codex"
cat >"$HOMEDIR/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/herdr-agent-state.sh" } ] }
    ]
  },
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": ["Bash(ls:*)"]
  },
  "theme": "dark"
}
JSON
cat >"$HOMEDIR/.codex/config.toml" <<'TOML'
approval_policy = "untrusted"
model = "gpt-5"

[tui]
notifications = true
TOML
runp
rc_is 0
out_has 'provisioned: claude permission posture'
out_has 'provisioned: codex permission posture'
claude_mode_is bypassPermissions
claude_key_is '"~/.claude/hooks/herdr-agent-state.sh"' hooks SessionStart 0 hooks 0 command
claude_key_is '"dark"' theme
claude_key_is '["Bash(ls:*)"]' permissions allow
ok "herdr's hook and the operator's own keys survive the merge"
file_has "$HOMEDIR/.codex/config.toml" 'approval_policy = "never"'
file_hasnt "$HOMEDIR/.codex/config.toml" 'approval_policy = "untrusted"'
file_has "$HOMEDIR/.codex/config.toml" 'sandbox_mode = "danger-full-access"'
file_has "$HOMEDIR/.codex/config.toml" 'model = "gpt-5"'
file_has "$HOMEDIR/.codex/config.toml" '[tui]'
file_has "$HOMEDIR/.codex/config.toml" 'notifications = true'
# Top-level keys must precede the first table header, or TOML reads them as part
# of that table.
sandbox_line=$(grep -n 'sandbox_mode' "$HOMEDIR/.codex/config.toml" | cut -d: -f1)
table_line=$(grep -n '^\[tui\]' "$HOMEDIR/.codex/config.toml" | cut -d: -f1)
[ "$sandbox_line" -lt "$table_line" ] || die "sandbox_mode (line $sandbox_line) is not above [tui] (line $table_line)"
ok 'the inserted key lands above the table header'

case_start 'reconciling twice is still a no-op the second time'
# Same state, run again: convergence is what makes the reconcile safe to wire
# into postCreateCommand.
sleep 1
before_settings=$(mtime "$HOMEDIR/.claude/settings.json")
before_codex=$(mtime "$HOMEDIR/.codex/config.toml")
: >"$STATE/calls.log"
runp
rc_is 0
out_hasnt 'provisioned: '
[ "$(mtime "$HOMEDIR/.claude/settings.json")" = "$before_settings" ] || die 'settings.json was rewritten'
[ "$(mtime "$HOMEDIR/.codex/config.toml")" = "$before_codex" ] || die 'config.toml was rewritten'
ok 'both posture files are untouched'

case_start 'an existing git identity is never overwritten'
reset_world
give_everything
env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
	git config --global user.name 'The Operator'
env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
	git config --global --add safe.directory '*'
runp
rc_is 0
[ "$(gitconfig user.name)" = 'The Operator' ] || die "git user.name became '$(gitconfig user.name)'"
ok 'the pre-existing user.name survives GIT_USER_NAME'
out_hasnt 'provisioned: git user.name'
[ "$(gitconfig user.email)" = 'operator@example.com' ] || die 'the absent user.email was not seeded'
ok 'the absent user.email is still seeded'
[ "$(gitconfig_all safe.directory | grep -cFx '*')" = 1 ] || die "safe.directory gained a duplicate:
$(gitconfig_all safe.directory)"
ok "a pre-existing safe.directory '*' gains no duplicate"
out_hasnt "provisioned: git safe.directory"
out_has 'ok: git identity'

case_start 'without the env variables, an absent identity is left absent and reported'
reset_world
give_claude_auth
give_codex_auth
give_ssh_ok
runp
rc_is 0
out_hasnt 'provisioned: git user'
out_has 'missing: git identity'
out_has 'git config --global user.name "<name>"'
out_has 'GIT_USER_NAME=<name>'
out_has 'recreate the container'
[ -z "$(gitconfig user.name)" ] || die 'user.name was seeded from nothing'
ok 'nothing is invented for the operator'

# ============================================================================
# The ssh identity
# ============================================================================

case_start 'an existing keypair is never regenerated or overwritten'
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
printf 'SENTINEL PRIVATE\n' >"$HOMEDIR/.ssh/id_devcontainer"
printf 'SENTINEL PUBLIC\n' >"$HOMEDIR/.ssh/id_devcontainer.pub"
runp
rc_is 0
not_called 'ssh-keygen'
out_hasnt 'provisioned: ssh key'
[ "$(cat "$HOMEDIR/.ssh/id_devcontainer")" = 'SENTINEL PRIVATE' ] || die 'the private key was overwritten'
[ "$(cat "$HOMEDIR/.ssh/id_devcontainer.pub")" = 'SENTINEL PUBLIC' ] || die 'the public key was overwritten'
ok 'both halves of the pre-existing keypair are byte-identical'
out_has 'provisioned: ssh config (github.com)'
ok 'the client configuration is still converged around it'

case_start 'a private key without its public half is left exactly as it is'
# "Never regenerated or overwritten" is the stronger invariant: the public half is
# derivable with `ssh-keygen -y`, and the temp-then-rename generation means this
# script can never produce this state itself.
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
printf 'SENTINEL PRIVATE\n' >"$HOMEDIR/.ssh/id_devcontainer"
runp
rc_is 0
not_called 'ssh-keygen'
[ "$(cat "$HOMEDIR/.ssh/id_devcontainer")" = 'SENTINEL PRIVATE' ] || die 'the private key was overwritten'
ok 'the lone private key survives'
no_file "$HOMEDIR/.ssh/id_devcontainer.pub"
ok 'no public half is invented for it'

case_start 'the modes are converged, not merely inherited'
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
chmod 755 "$HOMEDIR/.ssh"
printf 'SENTINEL PRIVATE\n' >"$HOMEDIR/.ssh/id_devcontainer"
chmod 644 "$HOMEDIR/.ssh/id_devcontainer"
runp
rc_is 0
mode_is 700 "$HOMEDIR/.ssh"
mode_is 600 "$HOMEDIR/.ssh/id_devcontainer"
ok 'a directory and a key that arrived with looser modes are repaired'

case_start 'a known_hosts file is never created or modified'
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
printf 'github.com ssh-ed25519 SENTINELHOSTKEY\n' >"$HOMEDIR/.ssh/known_hosts"
known_body=$(cat "$HOMEDIR/.ssh/known_hosts")
before_known=$(mtime "$HOMEDIR/.ssh/known_hosts")
sleep 1
runp
rc_is 0
runp --doctor
rc_is 0
[ "$(mtime "$HOMEDIR/.ssh/known_hosts")" = "$before_known" ] || die 'known_hosts was rewritten'
[ "$(cat "$HOMEDIR/.ssh/known_hosts")" = "$known_body" ] || die 'known_hosts content changed'
ok 'neither mode touches the operator-owned known_hosts'
file_hasnt "$HOMEDIR/.ssh/config" 'StrictHostKeyChecking'
file_hasnt "$HOMEDIR/.ssh/config" 'UserKnownHostsFile'
ok "the client's default strict host-key checking is left alone"

case_start "an operator's own ssh config survives the merge"
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
cat >"$HOMEDIR/.ssh/config" <<'CONF'
Host *
  IdentityFile ~/.ssh/operator_key

Host example.com
  User someone

Host github.com gist.github.com
  IdentityFile ~/.ssh/multi_key
CONF
runp
rc_is 0
out_has 'provisioned: ssh config (github.com)'
file_has "$HOMEDIR/.ssh/config" 'IdentityFile ~/.ssh/operator_key'
file_has "$HOMEDIR/.ssh/config" 'User someone'
# A multi-pattern Host line is somebody else's block: converging inside it would
# change gist.github.com too, which this script does not own.
file_has "$HOMEDIR/.ssh/config" 'IdentityFile ~/.ssh/multi_key'
ok 'the wildcard, foreign and multi-pattern blocks keep their own identities'
file_counts 1 "$HOMEDIR/.ssh/config" '^  IdentityFile ~/\.ssh/id_devcontainer$'
file_counts 1 "$HOMEDIR/.ssh/config" '^  IdentitiesOnly yes$'
# ssh accumulates IdentityFile values across every matching block in file order,
# so the managed block has to precede a `Host *` that carries its own identity —
# otherwise the operator's key is offered first.
gh_line=$(grep -n '^Host github.com$' "$HOMEDIR/.ssh/config" | cut -d: -f1)
star_line=$(grep -n '^Host \*$' "$HOMEDIR/.ssh/config" | cut -d: -f1)
[ -n "$gh_line" ] || die 'no exact "Host github.com" block was inserted'
[ "$gh_line" -lt "$star_line" ] || die "the github block (line $gh_line) is not above Host * (line $star_line)"
ok 'the inserted block lands above the wildcard block'
sleep 1
before_sshconfig=$(mtime "$HOMEDIR/.ssh/config")
sshconfig_body=$(cat "$HOMEDIR/.ssh/config")
runp
rc_is 0
out_hasnt 'provisioned: ssh config'
[ "$(mtime "$HOMEDIR/.ssh/config")" = "$before_sshconfig" ] || die 'the merged config was rewritten'
[ "$(cat "$HOMEDIR/.ssh/config")" = "$sshconfig_body" ] || die 'the merged config content changed'
ok 'the merge is convergent: the second run writes nothing'

case_start 'an exact managed block is converged in place, keeping its other directives'
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
cat >"$HOMEDIR/.ssh/config" <<'CONF'
Host github.com
  IdentityFile ~/.ssh/wrong_key
  PreferredAuthentications publickey
CONF
runp
rc_is 0
out_has 'provisioned: ssh config (github.com)'
file_hasnt "$HOMEDIR/.ssh/config" 'IdentityFile ~/.ssh/wrong_key'
file_has "$HOMEDIR/.ssh/config" 'PreferredAuthentications publickey'
file_counts 1 "$HOMEDIR/.ssh/config" '^Host github.com$'
file_counts 1 "$HOMEDIR/.ssh/config" '^  IdentityFile ~/\.ssh/id_devcontainer$'
file_counts 1 "$HOMEDIR/.ssh/config" '^  IdentitiesOnly yes$'
ok "the identity is rewritten, the missing directive inserted, the operator's own kept"

case_start 'an interrupted earlier generation is repaired, not trusted'
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
printf 'LEFTOVER\n' >"$HOMEDIR/.ssh/id_devcontainer.provision"
runp
rc_is 0
called 'ssh-keygen'
out_has 'provisioned: ssh key'
file_has "$HOMEDIR/.ssh/id_devcontainer" 'BEGIN OPENSSH PRIVATE KEY'
file_has "$HOMEDIR/.ssh/id_devcontainer.pub" 'ssh-rsa'
no_file "$HOMEDIR/.ssh/id_devcontainer.provision"
ok "a crash's leftover temporary file is overwritten, not mistaken for a key"

# ============================================================================
# The doctor
# ============================================================================

# missing_only <label> — every credential present except the one under test,
# under --doctor, which provisions nothing: the identity has to be there as
# configuration, not as the env variables the default run would seed from.
missing_only() {
	reset_world
	give_everything
	give_identity_config
	case "$1" in
	'claude auth') rm -f "$HOMEDIR/.claude/.credentials.json" ;;
	'codex auth') CODEX_STUB_LOGIN_RC=1 ;;
	'git identity') rm -f "$HOMEDIR/.gitconfig" ;;
	'herdr') rm -f "$LOCAL_BIN/herdr" ;;
	*) die "no such credential: $1" ;;
	esac
	runp --doctor
	rc_is 1
	out_counts 1 'missing: '
	out_has "missing: $1"
	out_counts 6 'ok: '
}

case_start 'doctor: claude auth missing, and nothing else'
missing_only 'claude auth'
out_has 'log in once per home volume'

case_start 'doctor: codex auth missing, and nothing else'
missing_only 'codex auth'
# The full command, anchored: plain `codex login` waits for a browser callback on
# localhost:1455, which compose does not publish.
out_matches '^ +codex login --device-auth$'
out_counts 1 'codex login'

case_start 'doctor: git identity missing, and nothing else'
missing_only 'git identity'
out_has 'git config --global user.name "<name>"'
out_has 'git config --global user.email "<email>"'
out_has 'GIT_USER_NAME=<name>'
out_has 'recreate the container'
out_has 'devcontainer up --workspace-folder <checkout> --remove-existing-container'

case_start 'doctor: a missing tool is a finding with the one fix, and --doctor does not install it'
missing_only 'herdr'
out_matches '^ +dev-bootstrap$'
cli_not_called curl
cli_not_called npm
ok 'report only: --doctor writes nothing, installs included'

case_start 'doctor: a tool whose version cannot be read is still present'
reset_world
give_everything
give_identity_config
CLAUDE_STUB_VERSION_FAIL=1 runp --doctor
rc_is 0
out_matches '^ok: claude$'
out_hasnt_line 'missing: claude'
ok 'the version is a convenience in the report, never something it fails over'

case_start 'doctor: everything missing at once'
reset_world
rm -rf "$HOMEDIR/.local"
grant ssh-keygen ssh
runp --doctor
rc_is 1
out_counts 7 'missing: '
out_hasnt 'ok: '
out_has_line 'missing: claude'
out_has_line 'missing: codex'
out_has_line 'missing: herdr'
out_has 'missing: claude auth'
out_has 'missing: codex auth'
out_has 'missing: git identity'
out_has 'missing: ssh github.com'
ok 'a bare fresh machine is reported item by item'

case_start 'doctor: the ok/missing protocol is the whole output'
reset_world
give_everything
give_identity_config
runp --doctor
rc_is 0
out_counts 7 'ok: '
out_hasnt 'missing: '
log_is 'claude --version' 'codex --version' 'herdr --version' 'codex login status' "$PROBE_GITHUB"
out_hasnt 'codex stub: Logged in using ChatGPT'
out_hasnt 'herdr stub:'
out_hasnt 'ssh stub:'
out_hasnt 'ssh-keygen stub:'
ok 'no probe chatter leaks into the report'

# The verdicts, one knob at a time against an otherwise complete environment —
# so each case pins one verdict's label *and* its fix lines.

case_start 'doctor: a host that refuses the shell without a message is still success'
reset_world
give_everything
give_identity_config
SSH_STUB_GITHUB=shell-refused runp --doctor
rc_is 0
out_has 'ok: ssh github.com'

case_start 'doctor: an unregistered key is reported with the registration fix'
reset_world
give_everything
give_identity_config
SSH_STUB_GITHUB=unregistered runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: ssh github.com'
# The probe's own last diagnostic opens the fix, so the verdict that also swallows
# timeouts and DNS failures still reports itself in the client's words.
out_matches '^ +git@github.com: Permission denied \(publickey\).$'
out_has 'cat ~/.ssh/id_devcontainer.pub'
out_has 'register it at GitHub: Settings, then SSH and GPG keys'
out_matches '^ +ssh -T git@github.com$'
ok 'the fix is print, register, then connect once by hand'

case_start 'doctor: an unknown host key resolves to the unregistered verdict, honestly worded'
reset_world
give_everything
give_identity_config
SSH_STUB_GITHUB=unknown-host runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: ssh github.com'
# Same verdict, same remedy — the first connection by hand is exactly what is
# missing — but the leading diagnostic is the probe's, not a false claim about
# registration.
out_matches '^ +Host key verification failed.$'
out_hasnt 'Permission denied'
out_matches '^ +ssh -T git@github.com$'

case_start 'doctor: an expired key is reported apart from an unregistered one'
reset_world
give_everything
give_identity_config
SSH_STUB_GITHUB=expired runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: ssh github.com'
out_has 'the key is registered but has expired'
# The remedy differs, which is the whole reason this verdict exists: re-pasting
# the same key fixes nothing, so the registration walk must not appear.
out_hasnt 'cat ~/.ssh/id_devcontainer.pub'
out_hasnt 'register it at'
ok 'the expired fix is a sign-in, not another registration'

# ============================================================================
# Exit codes and writes
# ============================================================================

case_start '--doctor exits 1 on a finding, and writes nothing'
reset_world
runp --doctor
rc_is 1
no_file "$HOMEDIR/.claude"
no_file "$HOMEDIR/.codex"
no_file "$HOMEDIR/.gitconfig"
# Including the ssh directory: no key, no config, and no known-hosts file — batch
# mode forbids the one write the probe itself could make.
no_file "$HOMEDIR/.ssh"
log_is 'claude --version' 'codex --version' 'herdr --version' 'codex login status' "$PROBE_GITHUB"
ok 'no install, no integration install, no posture, no git writes, no key generation'

case_start 'the default run survives missing credentials'
reset_world
runp
rc_is 0
ok 'postCreateCommand does not fail container creation over the interactive logins'
out_has 'missing: claude auth'
runp --doctor
rc_is 1
ok 'the same state is a failure for the scriptable check'

case_start 'a failed integration install is fatal and names the step'
reset_world
give_everything
HERDR_STUB_INSTALL_FAIL=1 runp
rc_nonzero
err_has 'herdr integration install claude failed'
err_has 'herdr stub: install failed for claude'
called 'herdr integration install codex'
ok 'the other steps still run: one broken install does not skip the rest'
claude_mode_is bypassPermissions

# ============================================================================
# Failures that must never be swallowed
#
# The assertions are the same shape every time: a non-zero exit, the step's own
# "could not …" line naming the path, no `provisioned:` line for that step, and
# the following steps still doing their work.
# ============================================================================

case_start 'an unparsable settings.json fails loudly and is left alone'
reset_world
give_everything
mkdir -p "$HOMEDIR/.claude"
printf '{ "permissions": \n' >"$HOMEDIR/.claude/settings.json"
runp
rc_nonzero
err_has 'could not write the claude permission posture'
err_has "$HOMEDIR/.claude/settings.json"
err_has 'invalid JSON'
out_hasnt 'provisioned: claude permission posture'
[ "$(cat "$HOMEDIR/.claude/settings.json")" = '{ "permissions": ' ] || die 'settings.json was clobbered'
ok 'the unreadable file is not overwritten'
file_has "$HOMEDIR/.codex/config.toml" 'approval_policy = "never"'
ok 'the codex posture still lands'

case_start 'an unwritable settings path fails the run instead of reporting success'
reset_world
give_everything
if [ "$(id -u)" = 0 ]; then
	printf '  -- skipped: running as root, where a read-only directory does not bind\n'
else
	# The directory is read-only and holds no settings.json, so the write has to
	# create the file — which is what the permissions deny. An existing file in
	# an unwritable directory would rewrite fine and prove nothing.
	chmod a-w "$HOMEDIR/.claude"
	runp
	chmod u+w "$HOMEDIR/.claude"
	rc_nonzero
	err_has 'could not write the claude permission posture'
	err_has "$HOMEDIR/.claude/settings.json"
	err_has 'Permission denied'
	out_hasnt 'provisioned: claude permission posture'
	no_file "$HOMEDIR/.claude/settings.json"
	file_has "$HOMEDIR/.codex/config.toml" 'approval_policy = "never"'
	ok 'the codex posture still lands'
fi

case_start 'a settings.json that is a directory fails the run too'
# Root-proof, unlike the case above: the coverage survives a suite run as root,
# where the read-only directory would not bind.
reset_world
give_everything
mkdir -p "$HOMEDIR/.claude/settings.json"
runp
rc_nonzero
err_has 'could not write the claude permission posture'
err_has "$HOMEDIR/.claude/settings.json"
err_has 'Is a directory'
out_hasnt 'provisioned: claude permission posture'
file_has "$HOMEDIR/.codex/config.toml" 'approval_policy = "never"'
ok 'the codex posture still lands'

case_start 'a query that fails is not read as "the key is absent"'
reset_world
give_everything
# A malformed global config makes every `git config --get` exit 128 rather than
# 1. Read as absence, the seed step would write over an operator's real
# identity; the run has to fail instead.
printf '[user\n' >"$HOMEDIR/.gitconfig"
runp
rc_nonzero
err_has 'could not read git user.name'
err_has 'could not read git user.email'
err_has 'could not read git safe.directory'
out_hasnt 'provisioned: git user.name'
out_hasnt 'provisioned: git user.email'
out_hasnt 'provisioned: git safe.directory'
ok 'a broken .gitconfig fails the run rather than reseeding over it'
claude_mode_is bypassPermissions
ok 'the posture steps before it still landed'

case_start 'a failing key generator fails the run and is never read as convergence'
reset_world
give_everything
SSH_KEYGEN_STUB_FAIL=1 runp
rc_nonzero
err_has 'could not provision the ssh key'
err_has "$HOMEDIR/.ssh/id_devcontainer"
err_has 'ssh-keygen stub: generation failed'
out_hasnt 'provisioned: ssh key'
no_file "$HOMEDIR/.ssh/id_devcontainer"
# The stub wrote the private half before failing, exactly as an interrupted real
# run would: these two are the cleanup, without which the next run would find a
# file it treats as a converged key.
no_file "$HOMEDIR/.ssh/id_devcontainer.provision"
no_file "$HOMEDIR/.ssh/id_devcontainer.provision.pub"
out_has 'provisioned: ssh config (github.com)'
ok 'the following step still runs'

case_start 'an absent key generator is a failure too'
reset_world
grant npm curl ssh
give_everything
runp
rc_nonzero
err_has 'could not provision the ssh key'
err_has 'No such file or directory'
err_has 'ssh-keygen'
out_hasnt 'provisioned: ssh key'
no_file "$HOMEDIR/.ssh/id_devcontainer"
ok 'a missing tool is 127, and 127 is not convergence'
out_has 'provisioned: ssh config (github.com)'
ok 'the following step still runs'

case_start 'an unwritable home fails the ssh step instead of reporting success'
reset_world
give_everything
if [ "$(id -u)" = 0 ]; then
	printf '  -- skipped: running as root, where a read-only directory does not bind\n'
else
	# The steps that write inside their own subdirectory need it to exist already,
	# so what the read-only home denies is exactly the mkdir this step has to do.
	mkdir -p "$HOMEDIR/.claude" "$HOMEDIR/.codex"
	chmod a-w "$HOMEDIR"
	runp
	chmod u+w "$HOMEDIR"
	rc_nonzero
	err_has 'could not provision the ssh key'
	err_has "$HOMEDIR/.ssh/id_devcontainer"
	err_has 'Permission denied'
	out_hasnt 'provisioned: ssh key'
	no_file "$HOMEDIR/.ssh"
	claude_mode_is bypassPermissions
	ok 'a step writing inside a still-writable subdirectory still lands'
fi

case_start 'a regular file where the ssh directory belongs fails the run too'
# Root-proof, unlike the case above.
reset_world
give_everything
printf 'not a directory\n' >"$HOMEDIR/.ssh"
runp
rc_nonzero
err_has 'could not provision the ssh key'
err_has 'File exists'
out_hasnt 'provisioned: ssh key'
out_hasnt 'provisioned: ssh config'
[ "$(cat "$HOMEDIR/.ssh")" = 'not a directory' ] || die 'the planted file was clobbered'
ok 'the file in the way is left alone'
claude_mode_is bypassPermissions
ok 'the posture steps before it still landed'

# ============================================================================
# The host guard
# ============================================================================

case_start 'without the container sentinel it refuses to run'
reset_world
# An absent path rather than an unset variable: on a Linux host that is itself
# inside a container, /.dockerenv exists and the default would pass.
SENTINEL="$TMP/no-such-sentinel"
rm -rf "$HOMEDIR/.local"
give_everything
runp
rc_nonzero
err_has 'not inside a container'
err_has 'must never run on the host'
log_empty
# .claude itself is a fixture here (the credentials file); what must not appear
# is anything the script writes.
no_file "$HOMEDIR/.claude/settings.json"
no_file "$HOMEDIR/.codex"
no_file "$HOMEDIR/.gitconfig"
no_file "$HOMEDIR/.ssh"
no_file "$HOMEDIR/.local"
ok 'nothing was provisioned or installed into the home directory'
runp --update-tools
rc_nonzero
err_has 'not inside a container'
log_empty
ok 'the guard covers --update-tools: nothing installs into a host home either'

# ============================================================================
# Usage
# ============================================================================

case_start 'an unknown argument prints usage on stderr'
reset_world
runp --wat
rc_is 2
err_has 'unknown argument: --wat'
err_has 'Usage: dev-bootstrap'
log_empty
no_file "$HOMEDIR/.claude"

case_start '--doctor and --update-tools together are refused'
reset_world
runp --doctor --update-tools
rc_is 2
err_has 'mutually exclusive'
log_empty

case_start '--help prints usage on stdout and runs nothing'
reset_world
runp --help
rc_is 0
out_has 'Usage: dev-bootstrap'
out_has '--doctor'
out_has '--update-tools'
log_empty
no_file "$HOMEDIR/.claude"

finish
