#!/usr/bin/env bash
#
# smoke-dev-firewall.sh — the egress fence exercised for real, inside the
# container, against the real internet. Where test-dev-firewall.sh proves the
# script issues the right commands, this proves the fence actually fences.
#
# Run it as the dev user, from the host:
#
#   devcontainer exec --workspace-folder . bash .devcontainer/test/smoke-dev-firewall.sh
#
# Not `docker exec`, which defaults to root and would test a privilege the
# agents never have. It needs a *freshly started* container: the opening
# assertion is that the fence is already armed, which is what proves the compose
# command arms it at start. After hand-toggling, `bin/dev-firewall on` restores
# that state. The check leaves the fence armed however it ends.

set -u
export LC_ALL=C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
FIREWALL=$ROOT/bin/dev-firewall
DENY_LOG=/var/log/dev-firewall.log
DNS_LOG=/var/log/dev-firewall-dns.log
ULOGD_LOG=/var/log/dev-firewall-ulogd.log
ALL_LOGS="$DENY_LOG $DNS_LOG $ULOGD_LOG"

# Docker's embedded resolver. /etc/resolv.conf points at our own dnsmasq, but
# that only redirects processes which consult it — this address is the bypass the
# fence has to close at the packet layer.
EMBEDDED_RESOLVER=127.0.0.11

# An allowlisted host and a deliberately absent one. example.com is the blocked
# case everywhere below, and its address is needed to find its own denial in the
# log.
ALLOWED=https://rubygems.org
ALLOWED_SECOND=https://registry.npmjs.org
BLOCKED_HOST=example.com

[ -x "$FIREWALL" ] || {
	echo "not executable: $FIREWALL" >&2
	exit 1
}
[ -e /.dockerenv ] || {
	echo 'not inside the container — run this through devcontainer exec' >&2
	exit 1
}

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
# the rest of the fence be inspected in the same run.
bad() {
	FAILURES=$((FAILURES + 1))
	printf '  FAIL [%s]  %s\n' "$CASE" "$1" >&2
}

check() {
	if [ "$1" = 0 ]; then ok "$2"; else bad "$2${3:+ — $3}"; fi
}

# The fence is left armed no matter how this exits, including on interrupt: the
# container's documented resting state is armed.
trap '"$FIREWALL" on >/dev/null 2>&1 || true' EXIT INT TERM

# reachable <url> — 0 when the whole request completes. --max-time bounds the
# blocked case; the allowed cases are generous enough for a cold TLS handshake.
reachable() {
	curl -fsS -o /dev/null --max-time 30 "$1"
}

# grep without -q on purpose: -q closes the pipe on the first match, and the
# SIGPIPE that follows would kill a healthy `status` mid-report.
status_says() {
	"$FIREWALL" status | grep -E "$1" >/dev/null
}

# resolves_via <nameserver> <name> — the addresses that one nameserver hands back,
# empty when it hands back nothing. Bypasses NSS and /etc/resolv.conf entirely,
# which is the point: this asks a specific resolver directly, the way the code
# that motivated the gate does. Every error counts as "resolved nothing" — a
# REJECT surfaces on a connected UDP socket as EPERM or ECONNREFUSED rather than
# as a DNS answer — and the timeout bounds a hypothetical DROP.
resolves_via() {
	ruby -rresolv -e '
		begin
			Resolv::DNS.open(nameserver: [ARGV[0]]) do |dns|
				dns.timeouts = 2
				print dns.getaddresses(ARGV[1]).join(" ")
			end
		rescue StandardError
			print ""
		end
	' "$1" "$2" 2>/dev/null
}

# log_size <file> — bytes, 0 for a file that is not there.
log_size() { wc -c <"$1" 2>/dev/null || echo 0; }

# ============================================================================

case_start 'the container arms itself at start'
status_says '^enforcement: armed$'
check $? 'enforcement: armed without anyone arming it' 'a hand-toggled container fails here by design'
status_says '^resolver: up'
check $? 'the resolver is running'
status_says '^logger: up'
check $? 'the denial logger is running'
status_says '^rotator: up'
check $? 'the log rotator is running'
# The pid is claimed, so it is checked: whatever `status` names has to be the
# rotation loop itself, not a stale pidfile pointing at some reused pid.
rotator_pid=$("$FIREWALL" status | sed -n 's/^rotator: up (pid \([0-9]*\)).*/\1/p')
[ -n "$rotator_pid" ] &&
	tr '\0' ' ' <"/proc/$rotator_pid/cmdline" 2>/dev/null | grep -q 'dev-firewall.*rotate'
check $? "the pid status reports (${rotator_pid:-none}) is running dev-firewall rotate"

case_start 'dnsmasq is the resolver the container actually uses'
# Not "resolv.conf looks right": dev-firewall.probe is answered by our own
# dnsmasq and by nothing else, so a 127.0.0.1 answer through NSS is proof that
# name resolution really goes through it.
[ "$(getent hosts dev-firewall.probe | awk '{ print $1; exit }')" = 127.0.0.1 ]
check $? 'the system resolver answers dev-firewall.probe — it is our dnsmasq'
[ "$(grep -c '^nameserver' /etc/resolv.conf)" = 1 ] &&
	grep -q '^nameserver 127.0.0.1$' /etc/resolv.conf
check $? '/etc/resolv.conf names 127.0.0.1 and nothing else' 'a second nameserver would bypass the ipset feeding'

case_start 'the embedded resolver is out of reach from the agent identity'
# The bypass this closes: resolv.conf binds only the processes that read it, so
# naming Docker's resolver directly used to resolve anything at all while status
# said `armed` — and a DNS query's labels carry data out on their own.
[ -z "$(resolves_via "$EMBEDDED_RESOLVER" "$BLOCKED_HOST")" ]
check $? "a direct query to $EMBEDDED_RESOLVER for $BLOCKED_HOST resolves nothing"
# The gate is on the path, not on the name: an allowlisted domain is refused
# there too, because it is the unlogged resolver that is off limits.
[ -z "$(resolves_via "$EMBEDDED_RESOLVER" "${ALLOWED#https://}")" ]
check $? "the same path is closed for the allowlisted ${ALLOWED#https://}"
# The positive control. Without it, a probe that rescues every error would pass
# just as well on a broken ruby.
[ -n "$(resolves_via 127.0.0.1 "$BLOCKED_HOST")" ]
check $? 'the same probe against the local dnsmasq does resolve' 'without this the two checks above prove nothing'

case_start 'the fence does not fence the database'
getent hosts postgres >/dev/null
check $? 'the compose service name still resolves'
pg_isready -h postgres -U postgres >/dev/null
check $? 'postgres is reachable with the fence armed'

case_start 'the allowlist is fed by the resolver at runtime, not seeded at init'
# `on` flushes the ipset and restarts dnsmasq with an empty cache, so the fetch
# below can only succeed if the answer to *this* query landed in the set.
"$FIREWALL" on >/dev/null
check $? 're-arming flushes the allowlist ipset'
reachable "$ALLOWED"
check $? "$ALLOWED is reachable after the flush" 'nothing seeded the set — the resolver fed it'
# A second domain, not resolved since that flush: per-query feeding rather than
# a one-shot fill at arm time. (A literal rotation — one name answering with a
# new address — needs authoritative DNS this check does not have; dnsmasq adds
# every answer it returns, so these are the same code path.)
reachable "$ALLOWED_SECOND"
check $? "$ALLOWED_SECOND is reachable without re-arming"

case_start 'the gem audit can still reach its advisory database'
# The trap worth its own case: bundler-audit does not fail when it cannot
# refresh, it audits a stale database and reports green. A blocked github.com
# turns the QA gate's security step into a lie.
git ls-remote https://github.com/rubysec/ruby-advisory-db.git HEAD >/dev/null 2>&1
check $? 'github.com is reachable, so the advisory DB can refresh'

case_start 'SSH host-key scans reach both Git providers through the armed fence'
# Credential-free on purpose: ssh-keyscan reads the host key before any
# authentication, so these hold with no key registered at either provider.
# What they guard: narrowing the accept rule to a port, or trimming the
# dev.azure.com suffix, would break all SSH Git with no other signal. stderr is
# keyscan's own comment chatter; only the keys on stdout count as an answer.
[ -n "$(ssh-keyscan -T 10 github.com 2>/dev/null)" ]
check $? 'github.com answers a host-key scan'
[ -n "$(ssh-keyscan -T 10 ssh.dev.azure.com 2>/dev/null)" ]
check $? 'ssh.dev.azure.com answers a host-key scan' 'the dev.azure.com suffix must cover this host'

case_start 'a non-allowlisted domain is blocked, and blocked fast'
# Every address the name has, not just the first: curl picks its own, and which
# one it lands on is not this check's business.
blocked_ips=$(getent ahostsv4 "$BLOCKED_HOST" | awk '{ print $1 }' | sort -u)
blocked_pattern="DST=($(printf '%s\n' "$blocked_ips" | paste -sd '|' -)) "
[ -n "$blocked_ips" ]
check $? "$BLOCKED_HOST still resolves (the deny is at the IP layer)"
baseline=$(wc -l <"$DENY_LOG" 2>/dev/null || echo 0)
started=$(date +%s)
curl -fsS -o /dev/null --max-time 20 "https://$BLOCKED_HOST"
curl_rc=$?
elapsed=$(($(date +%s) - started))
[ "$curl_rc" != 0 ]
check $? "https://$BLOCKED_HOST is refused"
# 28 is curl's timeout: REJECT has to fail in milliseconds, because DROP would
# cost an agent minutes of dead air per denial.
[ "$curl_rc" != 28 ] && [ "$elapsed" -lt 10 ]
check $? "the refusal is immediate (${elapsed}s), not a timeout"

case_start 'the denial is logged and annotated with its domain'
# NFLOG delivery to ulogd is asynchronous, so an immediate read is a race.
found=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if [ "$(wc -l <"$DENY_LOG" 2>/dev/null || echo 0)" -gt "$baseline" ] &&
		tail -n +"$((baseline + 1))" "$DENY_LOG" | grep -qE "$blocked_pattern"; then
		found=0
		break
	fi
	sleep 1
done
check $found "a new line in $DENY_LOG is the blocked attempt on $BLOCKED_HOST"
"$FIREWALL" status | grep -E ":443/TCP +$BLOCKED_HOST\$" >/dev/null
check $? "status lists the denial annotated $BLOCKED_HOST"

case_start "the fence's exhaust is bounded"
# `--force` rotates regardless of size, which is what makes the retention path
# testable without writing 4 MiB of denials. The timer runs the same code with
# the threshold applied.
"$FIREWALL" rotate --force >/dev/null
check $? 'rotate --force exits clean'
for log in $ALL_LOGS; do
	live=$(log_size "$log")
	kept=$(log_size "$log.1")
	[ "$kept" -gt 0 ] && [ "$live" -lt "$kept" ]
	check $? "$(basename "$log"): the generation holds the old bytes (${kept}B), the live file was truncated (${live}B)"
	[ ! -e "$log.2" ] && [ ! -e "$log.1.1" ]
	check $? "$(basename "$log"): exactly one generation is kept"
done
# Copy-truncate's whole premise: the writers hold the same inode and need no
# reopen. Both of them are checked, because ulogd and dnsmasq are separate
# daemons with separate file handles.
dns_before=$(log_size "$DNS_LOG")
getent hosts "${ALLOWED_SECOND#https://}" >/dev/null
grew=1
for _ in 1 2 3 4 5; do
	[ "$(log_size "$DNS_LOG")" -gt "$dns_before" ] && grew=0 && break
	sleep 1
done
check $grew 'dnsmasq keeps writing to the truncated query log'
deny_before=$(wc -l <"$DENY_LOG" 2>/dev/null || echo 0)
curl -fsS -o /dev/null --max-time 20 "https://$BLOCKED_HOST" 2>/dev/null
logged=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ "$(wc -l <"$DENY_LOG" 2>/dev/null || echo 0)" -gt "$deny_before" ] && logged=0 && break
	sleep 1
done
check $logged 'ulogd keeps writing to the truncated denial log'
# A second rotation replaces the generation instead of stacking generations —
# bounded means bounded across rotations, not just after the first one.
"$FIREWALL" rotate --force >/dev/null
check $? 'a second rotate --force exits clean'
stacked=''
for log in $ALL_LOGS; do
	[ -e "$log.2" ] || [ -e "$log.1.1" ] && stacked="$stacked $log"
done
[ -z "$stacked" ]
check $? 'the second rotation kept one generation per log' "stacked:$stacked"
status_says '^enforcement: armed$'
check $? 'rotating changed nothing about enforcement'
status_says '^rotator: up'
check $? 'the rotator is still up after rotating by hand'

case_start 'off lifts enforcement and on re-arms it'
"$FIREWALL" off >/dev/null
check $? 'off exits clean'
status_says '^enforcement: off$'
check $? 'status reports off'
reachable "https://$BLOCKED_HOST"
check $? "$BLOCKED_HOST is reachable with enforcement off"
# The resolver survives `off` — that is the whole point of toggling only the
# jump, so a debugging session keeps its names and its denial annotations.
status_says '^resolver: up'
check $? 'the resolver stayed up across the toggle'
"$FIREWALL" on >/dev/null
check $? 'on exits clean'
status_says '^enforcement: armed$'
check $? 'status reports armed again'
curl -fsS -o /dev/null --max-time 20 "https://$BLOCKED_HOST"
[ "$?" != 0 ]
check $? "$BLOCKED_HOST is refused again"

# ============================================================================

printf '\n'
if [ "$FAILURES" = 0 ]; then
	printf '%s checks passed — the fence holds\n' "$CHECKS"
	exit 0
fi
printf '%s checks passed, %s failed\n' "$CHECKS" "$FAILURES" >&2
exit 1
