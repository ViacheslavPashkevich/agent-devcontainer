#!/usr/bin/env bash
#
# test-dev-bootstrap.sh — bin/dev-bootstrap's stub matrix: a fresh home volume
# provisioned end to end, a second run that writes nothing, reconciliation over
# files somebody else owns, the doctor's report for every missing-credential
# combination, the failures that must never be swallowed, and the host guard.
#
# `bin/dev-bootstrap` refuses to run outside a container, and it is a Ruby
# program, so this suite runs where both are true — inside the devcontainer,
# from the host:
#
#   devcontainer exec --workspace-folder . bash .devcontainer/test/test-dev-bootstrap.sh
#
# It needs a real `ruby` on PATH, which the image always carries; the host
# baseline in docs/development/setup.md does not promise one, which is why this
# suite is not a host suite like the other two.
#
# The scratch world, the reporting protocol, the safe bin, planting and the
# generic assertions come from test-helper.sh. Divergences the subject forces:
#
#   - HOME is a scratch directory recreated per case — that is the fresh home
#     volume, the state this script exists to provision.
#   - The safe bin's `ruby` is the subject's own interpreter here, not a stub:
#     bin/dev-bootstrap *is* Ruby. Its subprocesses — herdr, codex, ssh-keygen
#     and ssh — are the stubs.
#   - Every stub prints chatter on every call, so "the doctor's output is exactly
#     its ok/missing protocol" is asserted against output that would leak if the
#     script ever streamed a probe.

SUBJECT=dev-bootstrap
# shellcheck source=.devcontainer/test/test-helper.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-helper.sh"

# The subject's interpreter has to resolve through the hermetic PATH, and so
# does the `timeout` the GitHub probe is wrapped in.
require_tools ruby timeout

# --- this suite's world extras ----------------------------------------------

HOMEDIR="$TMP/home"
SENTINEL="$TMP/sentinel"
: >"$SENTINEL"

# The generation call, pinned once and shared by the cases that assert it. `$*`
# in the stub joins argv with single spaces, so ssh-keygen's empty `-N` value —
# the whole "no passphrase" contract — shows up as a doubled space. It is spelled
# with an empty variable so no reformatting can quietly collapse it.
EMPTY=''
KEYGEN_CALL="ssh-keygen -t rsa -b 4096 -N $EMPTY -C brandeasy-devcontainer -q -f $HOMEDIR/.ssh/id_brandeasy.provision"

# The doctor's two probes, likewise pinned once: BatchMode (cannot prompt, cannot
# accept a host key) and ConnectTimeout (cannot hang) appear in every call log
# that carries them, which is where "the probe is non-interactive" is asserted.
PROBE_GITHUB='ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github.com'
PROBE_AZURE='ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@ssh.dev.azure.com'

# The token probe, likewise. The repository comes from the planted workflow.yml
# below and is deliberately not this project's real one, so the assertion proves
# the target is read from config rather than hardcoded. The `timeout 10` wrapper
# resolves separately and never reaches the stub, so it is not in this line.
GH_PROBE='gh api repos/fixture-org/fixture-repo'
GH_PROBE_WT='gh api repos/fixture-org/worktree-repo'

# --- stubs ------------------------------------------------------------------

cat >"$STUBS/herdr" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'herdr %s\n' "$*" >>"$S/calls.log"
case "${1:-} ${2:-}" in
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
printf 'ssh-rsa AAAAfixture brandeasy-devcontainer\n' >"$path.pub"
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
# Unset means unregistered: that is what a fresh home volume with a brand-new key
# actually gets, so the bare-machine cases need no knob.
case "$target" in
*github.com) verdict=${SSH_STUB_GITHUB:-unregistered} ;;
*ssh.dev.azure.com) verdict=${SSH_STUB_AZURE:-unregistered} ;;
*)
	echo "ssh stub: unsupported target: $target" >&2
	exit 2
	;;
esac
# Real wording and real exit statuses, because the verdicts are derived from
# both. Note that success is non-zero at *both* providers.
case "$verdict" in
authenticated)
	case "$target" in
	*github.com) echo "Hi fixture! You've successfully authenticated, but GitHub does not provide shell access." >&2 ;;
	*) echo 'remote: Shell access is not supported.' >&2 ;;
	esac
	exit 1
	;;
shell-refused)
	# Azure DevOps' other success shape, observed against the live service: the
	# server refuses the shell without a message of its own, so ssh reports the
	# refusal itself — after a warning that has nothing to do with the outcome.
	# Authentication already succeeded by then; a rejected key never gets this far.
	echo '** WARNING: connection is not using a post-quantum key exchange algorithm.' >&2
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

cat >"$STUBS/gh" <<'STUB'
#!/bin/sh
set -u
S=${STUB_STATE:?}
printf 'gh %s\n' "$*" >>"$S/calls.log"
case "${GH_STUB:-ok}" in
ok)
	# Chatter on stdout, as everywhere here: the doctor's report has to stay its
	# own protocol even when the probe is talkative.
	echo 'gh stub: calling the API'
	echo '{"full_name":"fixture-org/fixture-repo","private":true}'
	exit 0
	;;
rejected)
	echo 'gh stub: calling the API'
	# The error body on stdout with *no* trailing newline, exactly as gh emits
	# it (observed against the live API): a caller that concatenates the two
	# streams welds this closing brace onto the front of the diagnostic below,
	# which is what the anchored fix-line assertions catch.
	printf '{"message":"Bad credentials"}'
	# gh's own wording for a revoked or expired token.
	echo 'gh: Bad credentials (HTTP 401)' >&2
	exit 1
	;;
not-found)
	echo 'gh stub: calling the API'
	printf '{"message":"Not Found"}'
	# How a fine-grained token scoped to some other repository presents: GitHub
	# hides what the token cannot see rather than admitting it exists.
	echo 'gh: Not Found (HTTP 404)' >&2
	exit 1
	;;
timeout)
	# Deliberately silent: this is what a killed `timeout 10` leaves behind, so
	# the case pins that the report stands up with no diagnostic line to lead with.
	exit 124
	;;
*)
	echo "gh stub: unknown mode: ${GH_STUB:-}" >&2
	exit 2
	;;
esac
STUB

chmod +x "$STUBS/herdr" "$STUBS/codex" "$STUBS/ssh-keygen" "$STUBS/ssh" "$STUBS/gh"

# The worktree fixture the helper built carries no config/ of its own, which is
# the point of the root-resolution case: master.key is gitignored in the real
# repo, so no worktree ever has a copy.

# The gitflow step delegates to bin/setup-gitflow, so the real script rides
# along in the fixture checkout — re-planted per case, because one case swaps
# in a failing stand-in.
plant_setup_gitflow() {
	cp "$SCRIPT_DIR/../../bin/setup-gitflow" "$REPO/bin/setup-gitflow"
	chmod +x "$REPO/bin/setup-gitflow"
}

# The fixture checkout's own config outlives the per-case HOME, so a case's
# `[gitflow]` write would leak into the next case's "fresh" world without this.
clear_gitflow() {
	local key
	for key in $(env -i PATH="$SAFEBIN" GIT_CONFIG_NOSYSTEM=1 \
		git -C "$REPO" config --local --list --name-only | grep '^gitflow' || true); do
		env -i PATH="$SAFEBIN" GIT_CONFIG_NOSYSTEM=1 \
			git -C "$REPO" config --local --unset-all "$key"
	done
}

# --- the case harness -------------------------------------------------------

# plant_workflow_yml <checkout> <repository> — the config the doctor reads its
# GitHub coordinates from. Both checkouts get one, with *different*
# repositories: workflow.yml is committed and therefore checkout-local, so the
# worktree case can prove the doctor answers from the checkout it runs out of
# rather than from the primary one (where the gitignored master.key lives).
plant_workflow_yml() {
	mkdir -p "$1/.claude"
	cat >"$1/.claude/workflow.yml" <<YML
github:
  repository: $2
  token_env: GH_TOKEN
YML
}

reset_world() {
	rm -rf "$STATE" "$HOMEDIR"
	mkdir -p "$STATE" "$HOMEDIR"
	rm -f "$REPO/config/master.key"
	plant_setup_gitflow
	clear_gitflow
	# Rewritten every case, so the malformed-config case cannot leak into the next.
	plant_workflow_yml "$REPO" fixture-org/fixture-repo
	plant_workflow_yml "$WT" fixture-org/worktree-repo
	grant herdr codex ssh-keygen ssh gh
	SENTINEL="$TMP/sentinel"
	unset HERDR_STUB_INSTALL_FAIL CODEX_STUB_LOGIN_RC \
		SSH_KEYGEN_STUB_FAIL SSH_STUB_GITHUB SSH_STUB_AZURE \
		AZURE_DEVOPS_PAT GIT_USER_NAME GIT_USER_EMAIL \
		GH_TOKEN GH_STUB
	OUT=''
	ERR=''
	RC=0
}

# The four things the script cannot provision itself, as fixtures.
give_claude_auth() {
	mkdir -p "$HOMEDIR/.claude"
	printf '{"claudeAiOauth":{"accessToken":"fixture"}}\n' >"$HOMEDIR/.claude/.credentials.json"
}

give_codex_auth() { CODEX_STUB_LOGIN_RC=0; }

give_master_key() {
	mkdir -p "$REPO/config"
	printf 'deadbeef\n' >"$REPO/config/master.key"
}

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

give_pat() { AZURE_DEVOPS_PAT=fixture-pat; }

# The token, plus the API's answer to a token that carries the right grant.
give_gh_token() {
	GH_TOKEN=fixture-gh-token
	GH_STUB=ok
}

# The registration the bootstrap cannot do itself, as a fixture: both providers
# answer as they do once the public key is registered.
give_ssh_ok() {
	SSH_STUB_GITHUB=authenticated
	SSH_STUB_AZURE=authenticated
}

give_everything() {
	give_claude_auth
	give_codex_auth
	give_master_key
	give_identity_env
	give_pat
	give_gh_token
	give_ssh_ok
}

# runp [--from <checkout>] <args…> — run the planted script with a hermetic PATH
# and a hermetic HOME. The subject's `#!/usr/bin/env ruby` resolves `ruby`
# through that PATH, so the safe bin's copy is the interpreter. GIT_CONFIG_NOSYSTEM
# keeps /etc/gitconfig from answering the identity checks.
runp() {
	local from="$REPO"
	if [ "${1:-}" = --from ]; then
		from="$2"
		shift 2
	fi
	capture --cd "$from" env -i \
		PATH="$CASEBIN:$SAFEBIN" \
		HOME="$HOMEDIR" \
		GIT_CONFIG_NOSYSTEM=1 \
		STUB_STATE="$STATE" \
		DEV_BOOTSTRAP_SENTINEL="$SENTINEL" \
		${HERDR_STUB_INSTALL_FAIL+HERDR_STUB_INSTALL_FAIL="$HERDR_STUB_INSTALL_FAIL"} \
		${CODEX_STUB_LOGIN_RC+CODEX_STUB_LOGIN_RC="$CODEX_STUB_LOGIN_RC"} \
		${SSH_KEYGEN_STUB_FAIL+SSH_KEYGEN_STUB_FAIL="$SSH_KEYGEN_STUB_FAIL"} \
		${SSH_STUB_GITHUB+SSH_STUB_GITHUB="$SSH_STUB_GITHUB"} \
		${SSH_STUB_AZURE+SSH_STUB_AZURE="$SSH_STUB_AZURE"} \
		${AZURE_DEVOPS_PAT+AZURE_DEVOPS_PAT="$AZURE_DEVOPS_PAT"} \
		${GH_TOKEN+GH_TOKEN="$GH_TOKEN"} \
		${GH_STUB+GH_STUB="$GH_STUB"} \
		${GIT_USER_NAME+GIT_USER_NAME="$GIT_USER_NAME"} \
		${GIT_USER_EMAIL+GIT_USER_EMAIL="$GIT_USER_EMAIL"} \
		"$from/bin/dev-bootstrap" "$@"
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

# repoconfig <key> — the fixture checkout's own config, where the gitflow step
# writes, read the same hermetic way.
repoconfig() {
	env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
		git -C "$REPO" config --local --get "$1" 2>/dev/null
}

# claude_mode / claude_key — read the settings file the way claude does, so a
# file that merely contains the right substring cannot pass.
claude_mode() {
	ruby -rjson -e 'puts (JSON.parse(File.read(ARGV[0]))["permissions"] || {})["defaultMode"].inspect' \
		"$HOMEDIR/.claude/settings.json"
}

claude_key() {
	ruby -rjson -e '
		keys = ARGV[1..].map { |k| k =~ /\A\d+\z/ ? k.to_i : k }
		puts JSON.parse(File.read(ARGV[0])).dig(*keys).inspect
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

# ============================================================================
# A fresh home volume
# ============================================================================

case_start 'a fresh home volume gets integrations, posture, identity, safe.directory, git-flow and the ssh identity'
reset_world
give_everything
runp
rc_is 0
log_is \
	'herdr integration status' \
	'herdr integration install claude' \
	'herdr integration install codex' \
	"$KEYGEN_CALL" \
	'codex login status' \
	"$GH_PROBE" \
	"$PROBE_GITHUB" \
	"$PROBE_AZURE"
ok 'the key is generated with the intended type and size, and with no passphrase'
ok 'each probe is non-interactive and bounded: BatchMode and ConnectTimeout'
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
out_has 'provisioned: git-flow branch model'
[ "$(repoconfig gitflow.initialized)" = true ] || die "gitflow.initialized is '$(repoconfig gitflow.initialized)'"
[ "$(repoconfig gitflow.branch.develop.parent)" = staging ] || die "develop's parent is '$(repoconfig gitflow.branch.develop.parent)'"
[ "$(repoconfig gitflow.branch.feature.startpoint)" = develop ] || die "feature's startpoint is '$(repoconfig gitflow.branch.feature.startpoint)'"
ok 'the git-flow branch model lands in the repository config'
out_has 'provisioned: ssh key (~/.ssh/id_brandeasy, RSA-4096)'
out_has 'provisioned: ssh config (github.com)'
out_has 'provisioned: ssh config (ssh.dev.azure.com)'
file_has "$HOMEDIR/.ssh/id_brandeasy" 'BEGIN OPENSSH PRIVATE KEY'
file_has "$HOMEDIR/.ssh/id_brandeasy.pub" 'ssh-rsa'
mode_is 700 "$HOMEDIR/.ssh"
mode_is 600 "$HOMEDIR/.ssh/id_brandeasy"
# The atomic-generation contract: the pair is written to .provision names and
# renamed, so a crash mid-generation can never leave a half-pair that the next
# run reads as converged.
no_file "$HOMEDIR/.ssh/id_brandeasy.provision"
no_file "$HOMEDIR/.ssh/id_brandeasy.provision.pub"
file_has "$HOMEDIR/.ssh/config" 'Host github.com'
file_has "$HOMEDIR/.ssh/config" 'Host ssh.dev.azure.com'
file_counts 2 "$HOMEDIR/.ssh/config" '^  IdentityFile ~/\.ssh/id_brandeasy$'
file_counts 2 "$HOMEDIR/.ssh/config" '^  IdentitiesOnly yes$'
# Host-key verification stays the operator's: no known-hosts file, and nothing
# that would weaken the client's default strict checking.
no_file "$HOMEDIR/.ssh/known_hosts"
file_hasnt "$HOMEDIR/.ssh/config" 'StrictHostKeyChecking'
file_hasnt "$HOMEDIR/.ssh/config" 'UserKnownHostsFile'
out_counts 8 'ok: '
out_hasnt 'missing: '
ok 'the doctor is clean once every credential is in place'
out_hasnt 'ssh-keygen stub:'
out_hasnt 'ssh stub:'
out_hasnt 'gh stub:'
ok 'neither the generator nor the probes leak chatter into the output'

case_start 'a second run changes nothing'
# Continues from the case above deliberately: the state under test is exactly
# what the first run left behind.
before_settings=$(mtime "$HOMEDIR/.claude/settings.json")
before_codex=$(mtime "$HOMEDIR/.codex/config.toml")
before_gitconfig=$(mtime "$HOMEDIR/.gitconfig")
before_sshconfig=$(mtime "$HOMEDIR/.ssh/config")
before_sshkey=$(mtime "$HOMEDIR/.ssh/id_brandeasy")
before_sshpub=$(mtime "$HOMEDIR/.ssh/id_brandeasy.pub")
before_repocfg=$(mtime "$REPO/.git/config")
settings_body=$(cat "$HOMEDIR/.claude/settings.json")
codex_body=$(cat "$HOMEDIR/.codex/config.toml")
gitconfig_body=$(cat "$HOMEDIR/.gitconfig")
sshconfig_body=$(cat "$HOMEDIR/.ssh/config")
sshkey_body=$(cat "$HOMEDIR/.ssh/id_brandeasy")
repocfg_body=$(cat "$REPO/.git/config")
# mtime has second granularity, so a rewrite inside the same second would be
# invisible; the gap is what gives the assertion teeth.
sleep 1
: >"$STATE/calls.log"
runp
rc_is 0
log_is \
	'herdr integration status' \
	'codex login status' \
	"$GH_PROBE" \
	"$PROBE_GITHUB" \
	"$PROBE_AZURE"
ok 'the integrations report current, so install never runs again'
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
[ "$(mtime "$HOMEDIR/.ssh/id_brandeasy")" = "$before_sshkey" ] || die 'the ssh key was rewritten'
[ "$(mtime "$HOMEDIR/.ssh/id_brandeasy.pub")" = "$before_sshpub" ] || die 'the public key was rewritten'
ok 'the ssh config and both key halves are untouched'
[ "$(cat "$HOMEDIR/.claude/settings.json")" = "$settings_body" ] || die 'settings.json content changed'
[ "$(cat "$HOMEDIR/.codex/config.toml")" = "$codex_body" ] || die 'config.toml content changed'
[ "$(cat "$HOMEDIR/.gitconfig")" = "$gitconfig_body" ] || die '.gitconfig content changed'
[ "$(cat "$HOMEDIR/.ssh/config")" = "$sshconfig_body" ] || die 'the ssh config content changed'
[ "$(cat "$HOMEDIR/.ssh/id_brandeasy")" = "$sshkey_body" ] || die 'the ssh key content changed'
ok 'every managed file is byte-identical'
[ "$(gitconfig_all safe.directory | grep -cFx '*')" = 1 ] || die "safe.directory gained a duplicate:
$(gitconfig_all safe.directory)"
ok "safe.directory still has exactly one '*' entry"
[ "$(mtime "$REPO/.git/config")" = "$before_repocfg" ] || die 'the repository config was rewritten'
[ "$(cat "$REPO/.git/config")" = "$repocfg_body" ] || die 'the repository config content changed'
ok 'the git-flow model is untouched'

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

case_start 'an initialized git-flow model is never re-seeded'
reset_world
give_everything
# The operator's deliberate deviation: initialized, with a tweaked prefix. The
# flag alone gates the step, so the tweak has to survive the run.
env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
	git -C "$REPO" config --local gitflow.initialized true
env -i PATH="$SAFEBIN" HOME="$HOMEDIR" GIT_CONFIG_NOSYSTEM=1 \
	git -C "$REPO" config --local gitflow.branch.feature.prefix topic/
runp
rc_is 0
out_hasnt 'provisioned: git-flow'
[ "$(repoconfig gitflow.branch.feature.prefix)" = 'topic/' ] || die "the operator's prefix became '$(repoconfig gitflow.branch.feature.prefix)'"
[ -z "$(repoconfig gitflow.branch.develop.parent)" ] || die 'the full model was seeded despite the initialized flag'
ok "an operator's deliberate model deviation survives the run"

# ============================================================================
# The ssh identity
# ============================================================================

case_start 'an existing keypair is never regenerated or overwritten'
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
printf 'SENTINEL PRIVATE\n' >"$HOMEDIR/.ssh/id_brandeasy"
printf 'SENTINEL PUBLIC\n' >"$HOMEDIR/.ssh/id_brandeasy.pub"
runp
rc_is 0
not_called 'ssh-keygen'
out_hasnt 'provisioned: ssh key'
[ "$(cat "$HOMEDIR/.ssh/id_brandeasy")" = 'SENTINEL PRIVATE' ] || die 'the private key was overwritten'
[ "$(cat "$HOMEDIR/.ssh/id_brandeasy.pub")" = 'SENTINEL PUBLIC' ] || die 'the public key was overwritten'
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
printf 'SENTINEL PRIVATE\n' >"$HOMEDIR/.ssh/id_brandeasy"
runp
rc_is 0
not_called 'ssh-keygen'
[ "$(cat "$HOMEDIR/.ssh/id_brandeasy")" = 'SENTINEL PRIVATE' ] || die 'the private key was overwritten'
ok 'the lone private key survives'
no_file "$HOMEDIR/.ssh/id_brandeasy.pub"
ok 'no public half is invented for it'

case_start 'the modes are converged, not merely inherited'
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
chmod 755 "$HOMEDIR/.ssh"
printf 'SENTINEL PRIVATE\n' >"$HOMEDIR/.ssh/id_brandeasy"
chmod 644 "$HOMEDIR/.ssh/id_brandeasy"
runp
rc_is 0
mode_is 700 "$HOMEDIR/.ssh"
mode_is 600 "$HOMEDIR/.ssh/id_brandeasy"
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

Host ssh.dev.azure.com
  IdentityFile ~/.ssh/wrong_key
  PreferredAuthentications publickey
CONF
runp
rc_is 0
out_has 'provisioned: ssh config (github.com)'
out_has 'provisioned: ssh config (ssh.dev.azure.com)'
file_has "$HOMEDIR/.ssh/config" 'IdentityFile ~/.ssh/operator_key'
file_has "$HOMEDIR/.ssh/config" 'User someone'
# A multi-pattern Host line is somebody else's block: converging inside it would
# change gist.github.com too, which this script does not own.
file_has "$HOMEDIR/.ssh/config" 'IdentityFile ~/.ssh/multi_key'
ok 'the wildcard, foreign and multi-pattern blocks keep their own identities'
file_hasnt "$HOMEDIR/.ssh/config" 'IdentityFile ~/.ssh/wrong_key'
file_has "$HOMEDIR/.ssh/config" 'PreferredAuthentications publickey'
ok "the exact azure block is converged in place, keeping its operator's directive"
file_counts 2 "$HOMEDIR/.ssh/config" '^  IdentityFile ~/\.ssh/id_brandeasy$'
file_counts 2 "$HOMEDIR/.ssh/config" '^  IdentitiesOnly yes$'
# ssh accumulates IdentityFile values across every matching block in file order,
# so the managed block has to precede a `Host *` that carries its own identity —
# otherwise the operator's key is offered first and Azure DevOps fails outright.
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

case_start 'an interrupted earlier generation is repaired, not trusted'
reset_world
give_everything
mkdir -p "$HOMEDIR/.ssh"
printf 'LEFTOVER\n' >"$HOMEDIR/.ssh/id_brandeasy.provision"
runp
rc_is 0
called 'ssh-keygen'
out_has 'provisioned: ssh key'
file_has "$HOMEDIR/.ssh/id_brandeasy" 'BEGIN OPENSSH PRIVATE KEY'
file_has "$HOMEDIR/.ssh/id_brandeasy.pub" 'ssh-rsa'
no_file "$HOMEDIR/.ssh/id_brandeasy.provision"
ok "a crash's leftover temporary file is overwritten, not mistaken for a key"

# ============================================================================
# The doctor
# ============================================================================

# missing_only <label> — every credential present except the one under test.
missing_only() {
	reset_world
	give_everything
	case "$1" in
	'claude auth') unset_claude_auth ;;
	'codex auth') CODEX_STUB_LOGIN_RC=1 ;;
	'AZURE_DEVOPS_PAT') unset AZURE_DEVOPS_PAT ;;
	'GH_TOKEN') unset GH_TOKEN ;;
	'config/master.key') rm -f "$REPO/config/master.key" ;;
	'git identity') unset GIT_USER_NAME GIT_USER_EMAIL ;;
	*) die "no such credential: $1" ;;
	esac
	runp
	rc_is 0
	out_counts 1 'missing: '
	out_has "missing: $1"
	out_counts 7 'ok: '
}

unset_claude_auth() { rm -f "$HOMEDIR/.claude/.credentials.json"; }

case_start 'doctor: claude auth missing, and nothing else'
missing_only 'claude auth'
out_has 'log in once per home volume'

case_start 'doctor: codex auth missing, and nothing else'
missing_only 'codex auth'
# The full command, anchored: plain `codex login` waits for a browser callback on
# localhost:1455, which compose does not publish. The substring match this
# replaces passed on that broken form, which is how it shipped.
out_matches '^ +codex login --device-auth$'
out_counts 1 'codex login'

case_start 'doctor: AZURE_DEVOPS_PAT missing, and nothing else'
missing_only 'AZURE_DEVOPS_PAT'
out_has 'AZURE_DEVOPS_PAT=<pat>'
out_has '.devcontainer/.env'
# Compose reads .env at creation time, so the fix has to be a recreate. The
# wording says so explicitly ("a restart is not enough"), and it must not be
# bin/dev-agent --update, which would move the image's tool versions as a side
# effect of fixing a credential.
out_has 'is not enough — recreate the container'
out_has 'devcontainer up --workspace-folder <checkout> --remove-existing-container'
out_hasnt '--update'

case_start 'doctor: GH_TOKEN missing, and nothing else'
missing_only 'GH_TOKEN'
out_has 'GH_TOKEN=<token>'
out_has '.devcontainer/.env'
# The same env-file remedy as the PAT, for the same reason: compose reads the
# file at creation time, and fixing a credential must not drag the image's tool
# versions along with it.
out_has 'is not enough — recreate the container'
out_has 'devcontainer up --workspace-folder <checkout> --remove-existing-container'
out_hasnt '--update'
# The grant is the narrow one the pull-request steps need, named where the
# operator is about to create the token.
out_has 'pull-request write and contents read'
out_has 'fixture-org/fixture-repo'
cli_not_called gh
ok 'a missing token is reported offline: no API call from a bare fresh machine'

case_start 'doctor: a missing token fails the scriptable check'
# The acceptance criterion is about --doctor going red, and only --doctor can
# pin that: the default mode exits 0 over findings by design.
reset_world
give_everything
give_identity_config
unset GH_TOKEN
runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: GH_TOKEN'
cli_not_called gh

case_start "doctor: a rejected token is red, in the API's own words"
reset_world
give_everything
give_identity_config
GH_STUB=rejected runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: GH_TOKEN'
out_has 'ok: AZURE_DEVOPS_PAT'
ok 'one rejected credential says nothing about the others'
# The probe's own last diagnostic opens the fix, so the report names what GitHub
# actually said rather than guessing at it.
out_matches '^ +gh: Bad credentials \(HTTP 401\)$'
out_has 'the token was rejected'
out_has 'pull-request write'
out_has 'fixture-org/fixture-repo'
ok 'the fix is to replace the token, scoped to the configured repository'
out_hasnt 'gh stub:'

case_start 'doctor: a token scoped elsewhere reads as rejected, not as a network fault'
# A fine-grained token for another repository gets 404, not 403: GitHub hides
# what the token cannot see. Read as a network fault it would tell the operator
# to check their connection instead of their token's scope.
reset_world
give_everything
give_identity_config
GH_STUB=not-found runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: GH_TOKEN'
out_matches '^ +gh: Not Found \(HTTP 404\)$'
out_has 'the token was rejected'
out_hasnt 'could not validate'

case_start 'doctor: an unreachable API is red without blaming the token'
reset_world
give_everything
give_identity_config
GH_STUB=timeout runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: GH_TOKEN'
out_has 'could not validate the token against github.com'
out_has 'gh api repos/fixture-org/fixture-repo'
# Rotating a credential fixes no network, so that remedy must not appear — and
# the killed probe produced no output at all, which the report has to survive.
out_hasnt 'rejected'
out_hasnt 'gh stub:'
ok 'a probe that never got an answer reports the network, not the credential'

case_start 'doctor: a config without the github block is a finding, not a crash'
reset_world
give_everything
give_identity_config
printf 'target_branch: develop\n' >"$REPO/.claude/workflow.yml"
runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: github token'
out_has 'has no github: block'
err_empty
cli_not_called gh
ok 'without a target there is nothing to probe, and the doctor still reports'

case_start 'doctor: an unparsable config is reported the same way'
reset_world
give_everything
give_identity_config
printf 'github: [\n' >"$REPO/.claude/workflow.yml"
runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: github token'
out_has 'could not read'
err_empty
cli_not_called gh
ok "the parser's complaint is a finding, never a backtrace"

case_start 'doctor: config/master.key missing, and nothing else'
missing_only 'config/master.key'
out_has 'scp <other-machine>:<checkout>/config/master.key config/master.key'
# scp is not in the image, so the fix has to say where it runs — the same way the
# PAT and git-identity fixes label their host-side recreate.
out_has 'from the host'

case_start 'doctor: git identity missing, and nothing else'
missing_only 'git identity'
out_has 'git config --global user.name "<name>"'
out_has 'git config --global user.email "<email>"'
out_has 'GIT_USER_NAME=<name>'
out_has 'recreate the container'
out_has 'devcontainer up --workspace-folder <checkout> --remove-existing-container'
out_hasnt '--update'

case_start 'doctor: everything missing at once'
reset_world
runp
rc_is 0
out_counts 8 'missing: '
out_hasnt 'ok: '
out_has 'missing: claude auth'
out_has 'missing: codex auth'
out_has 'missing: AZURE_DEVOPS_PAT'
out_has 'missing: GH_TOKEN'
out_has 'missing: config/master.key'
out_has 'missing: git identity'
# The key was just generated here, so both hosts answer "not registered" — which
# is what a fresh machine before the operator's registration step really is.
out_has 'missing: ssh github.com'
out_has 'missing: ssh ssh.dev.azure.com'
ok 'a bare fresh machine is reported credential by credential'

case_start 'doctor: the ok/missing protocol is the whole output'
reset_world
give_everything
give_identity_config
runp --doctor
rc_is 0
out_counts 8 'ok: '
out_hasnt 'missing: '
out_has 'ok: GH_TOKEN'
ok 'a token the API accepts for the configured repository reads green'
out_has 'ok: ssh ssh.dev.azure.com'
# The `authenticated` knob answers exactly as Azure DevOps does — "Shell access is
# not supported." on stderr with a non-zero status — so this line is the assertion
# that its refusal of interactive shells is read as success rather than failure.
ok "Azure DevOps' shell refusal plus non-zero status reads as success"
log_is 'codex login status' "$GH_PROBE" "$PROBE_GITHUB" "$PROBE_AZURE"
out_hasnt 'codex stub: Logged in using ChatGPT'
out_hasnt 'herdr stub:'
out_hasnt 'ssh stub:'
out_hasnt 'ssh-keygen stub:'
out_hasnt 'gh stub:'
ok 'no probe chatter leaks into the report'

# The three verdicts, one knob at a time against an otherwise complete
# environment — so each case pins one verdict's label *and* its fix lines.

case_start 'doctor: a host that refuses the shell without a message is still success'
reset_world
give_everything
give_identity_config
SSH_STUB_AZURE=shell-refused runp --doctor
rc_is 0
out_counts 8 'ok: '
out_hasnt 'missing: '
out_has 'ok: ssh ssh.dev.azure.com'
ok "both of Azure DevOps' shell refusals read as success: its own message, and ssh's"

case_start 'doctor: an unregistered key is reported per host, with the registration fix'
reset_world
give_everything
give_identity_config
SSH_STUB_GITHUB=unregistered runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: ssh github.com'
out_has 'ok: ssh ssh.dev.azure.com'
ok 'one host being unusable says nothing about the other'
# The probe's own last diagnostic opens the fix, so the verdict that also swallows
# timeouts and DNS failures still reports itself in the client's words.
out_matches '^ +git@github.com: Permission denied \(publickey\).$'
out_has 'cat ~/.ssh/id_brandeasy.pub'
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
SSH_STUB_AZURE=expired runp --doctor
rc_is 1
out_counts 1 'missing: '
out_has 'missing: ssh ssh.dev.azure.com'
out_has 'ok: ssh github.com'
out_has 'the key is registered but has expired'
out_has 'https://dev.azure.com/<organization>'
# The remedy differs, which is the whole reason this verdict exists: re-pasting
# the same key fixes nothing, so the registration walk must not appear.
out_hasnt 'cat ~/.ssh/id_brandeasy.pub'
out_hasnt 'register it at'
ok 'the expired fix is a web sign-in, not another registration'

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
log_is 'codex login status' "$PROBE_GITHUB" "$PROBE_AZURE"
ok 'no integration install, no posture, no git writes, no key generation'

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
# Each of these used to exit 1 out of a subprocess and be read as "already
# converged", so the run reported success while provisioning nothing. The
# assertions are the same shape every time: a non-zero exit, the step's own
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
	err_has 'Errno::EACCES'
	out_hasnt 'provisioned: claude permission posture'
	no_file "$HOMEDIR/.claude/settings.json"
	file_has "$HOMEDIR/.codex/config.toml" 'approval_policy = "never"'
	ok 'the codex posture still lands'
fi

case_start 'a settings.json that is a directory fails the run too'
# Root-proof, unlike the case above: the AC's coverage survives a suite run as
# root, where the read-only directory would not bind.
reset_world
give_everything
mkdir -p "$HOMEDIR/.claude/settings.json"
runp
rc_nonzero
err_has 'could not write the claude permission posture'
err_has "$HOMEDIR/.claude/settings.json"
err_has 'Errno::EISDIR'
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
# A malformed global config fails repo-local reads too — git parses every
# config file on startup — so the gitflow gate hits the same policy.
err_has 'could not read gitflow.initialized'
out_hasnt 'provisioned: git user.name'
out_hasnt 'provisioned: git user.email'
out_hasnt 'provisioned: git safe.directory'
out_hasnt 'provisioned: git-flow'
ok 'a broken .gitconfig fails the run rather than reseeding over it'
claude_mode_is bypassPermissions
ok 'the posture steps before it still landed'

case_start 'a failing setup-gitflow fails the run, and the following step still runs'
reset_world
give_everything
cat >"$REPO/bin/setup-gitflow" <<'SH'
#!/bin/sh
echo 'setup-gitflow stub: refusing' >&2
exit 1
SH
chmod +x "$REPO/bin/setup-gitflow"
runp
rc_nonzero
err_has 'could not configure git-flow'
err_has 'setup-gitflow stub: refusing'
out_hasnt 'provisioned: git-flow'
[ -z "$(repoconfig gitflow.initialized)" ] || die 'gitflow config appeared despite the failure'
out_has 'provisioned: ssh key (~/.ssh/id_brandeasy, RSA-4096)'
ok 'the following step still runs'

case_start 'a failing key generator fails the run and is never read as convergence'
reset_world
give_everything
SSH_KEYGEN_STUB_FAIL=1 runp
rc_nonzero
err_has 'could not provision the ssh key'
err_has "$HOMEDIR/.ssh/id_brandeasy"
err_has 'ssh-keygen stub: generation failed'
out_hasnt 'provisioned: ssh key'
no_file "$HOMEDIR/.ssh/id_brandeasy"
# The stub wrote the private half before failing, exactly as an interrupted real
# run would: these two are the cleanup, without which the next run would find a
# file it treats as a converged key.
no_file "$HOMEDIR/.ssh/id_brandeasy.provision"
no_file "$HOMEDIR/.ssh/id_brandeasy.provision.pub"
out_has 'provisioned: ssh config (github.com)'
ok 'the following step still runs'

case_start 'an absent key generator is a failure too'
reset_world
grant herdr codex ssh gh
give_everything
runp
rc_nonzero
err_has 'could not provision the ssh key'
err_has 'No such file or directory'
err_has 'ssh-keygen'
out_hasnt 'provisioned: ssh key'
no_file "$HOMEDIR/.ssh/id_brandeasy"
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
	err_has "$HOMEDIR/.ssh/id_brandeasy"
	err_has 'Errno::EACCES'
	out_hasnt 'provisioned: ssh key'
	no_file "$HOMEDIR/.ssh"
	claude_mode_is bypassPermissions
	ok 'a step writing inside a still-writable subdirectory still lands'
fi

case_start 'a regular file where the ssh directory belongs fails the run too'
# Root-proof, unlike the case above: the AC's coverage survives a suite run as
# root, where a read-only home would not bind.
reset_world
give_everything
printf 'not a directory\n' >"$HOMEDIR/.ssh"
runp
rc_nonzero
err_has 'could not provision the ssh key'
err_has 'Errno::EEXIST'
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
ok 'nothing was provisioned into the home directory'

# ============================================================================
# Root resolution
# ============================================================================

case_start 'a worktree copy answers for the primary checkout'
reset_world
give_everything
# master.key exists only in the primary checkout, as it does in reality: it is
# gitignored, so no worktree ever has its own copy.
[ -e "$WT/config/master.key" ] && die 'the worktree fixture has its own master.key'
# --doctor provisions nothing, so the identity it checks has to be there already.
give_identity_config
runp --from "$WT" --doctor
rc_is 0
out_has 'ok: config/master.key'
ok 'no false "missing" from a worktree'
# The two resolutions pull in opposite directions, and each has to win where it
# belongs: master.key answers from the primary checkout above, while the
# committed workflow.yml answers from the worktree's own copy — otherwise a
# story adding a github: block could never see it from the worktree adding it.
called "$GH_PROBE_WT"
not_called "$GH_PROBE"
ok 'the committed config is read checkout-locally, not from the primary checkout'

# ============================================================================
# Usage
# ============================================================================

case_start 'an unknown argument prints usage on stderr'
reset_world
runp --wat
rc_is 2
err_has 'unknown argument: --wat'
err_has 'Usage: bin/dev-bootstrap'
log_empty
no_file "$HOMEDIR/.claude"

case_start '--help prints usage on stdout and runs nothing'
reset_world
runp --help
rc_is 0
out_has 'Usage: bin/dev-bootstrap'
out_has '--doctor'
log_empty
no_file "$HOMEDIR/.claude"

finish
