#!/usr/bin/env bash
# End-to-end SSH tests with isolated keys, ssh-agent, cache and provisioning paths.
# Usage: bash test/remote_provision.bash /absolute/path/to/hola
# Requires OpenSSH client/server. The daemon listens only on loopback.
set -euo pipefail
binary="${1:?Pass the absolute path to the hola binary}"
fixture="$(mktemp -d /tmp/hola-ssh-test.XXXXXXXX)"
sshd_bin="${SSHD_BIN:-$(command -v sshd || true)}"
port="${HOLA_TEST_SSH_PORT:-$((20000 + $$ % 20000))}"
sshd_pid=
agent_pid=
cleanup() {
  [ -z "$sshd_pid" ] || kill "$sshd_pid" 2>/dev/null || true
  [ -z "$agent_pid" ] || kill "$agent_pid" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT
[ -n "$sshd_bin" ] || { echo 'sshd is required' >&2; exit 1; }
mkdir -p "$fixture/home" "$fixture/state" "$fixture/bundle/nested"
export XDG_STATE_HOME="$fixture/state"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/client"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/wrong-host"
cp "$fixture/client.pub" "$fixture/authorized_keys"
printf '[127.0.0.1]:%s %s\n' "$port" "$(cat "$fixture/host.pub")" > "$fixture/known_hosts"
printf '[127.0.0.1]:%s %s\n' "$port" "$(cat "$fixture/wrong-host.pub")" > "$fixture/wrong_known_hosts"
: > "$fixture/empty_known_hosts"
if [ "$(uname)" = Darwin ]; then
  sftp_server=/usr/libexec/sftp-server
else
  sftp_server=/usr/lib/openssh/sftp-server
fi
cat > "$fixture/dispatch" <<EOF
#!/bin/sh
export HOME='$fixture/home'
export XDG_STATE_HOME='$fixture/state'
if [ "\$SSH_ORIGINAL_COMMAND" = internal-sftp ]; then
  exec '$sftp_server'
fi
exec /bin/sh -c "\$SSH_ORIGINAL_COMMAND"
EOF
chmod 700 "$fixture/dispatch"
cat > "$fixture/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $fixture/host
PidFile $fixture/sshd.pid
AuthorizedKeysFile $fixture/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin yes
AllowUsers $(id -un)
Subsystem sftp internal-sftp
ForceCommand $fixture/dispatch
LogLevel ERROR
EOF
"$sshd_bin" -D -e -f "$fixture/sshd_config" > "$fixture/sshd.log" 2>&1 &
sshd_pid=$!
for attempt in {1..30}; do
  if ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$fixture/known_hosts" -o IdentitiesOnly=yes \
      -i "$fixture/client" -p "$port" "$(id -un)@127.0.0.1" true 2>/dev/null; then break; fi
  if ! kill -0 "$sshd_pid" 2>/dev/null; then cat "$fixture/sshd.log"; exit 1; fi
  sleep 0.1
done
common=(--host "$(id -un)@127.0.0.1" --port "$port" --known-hosts "$fixture/known_hosts")
# HOME is isolated so the developer's own ~/.ssh/config never leaks into a run.
run() {
  HOME="$fixture/home" "$binary" provision "$@" > "$fixture/output.log" 2>&1
}
fail() { cat "$fixture/output.log"; cat "$fixture/sshd.log"; exit 1; }
cat > "$fixture/bundle/nested/main's.rb" <<'RUBY'
require_relative '../helper'
phase :deploy
file data_bag['destination'] do
  content File.read('payload.txt') + secrets_bag['token']
end
phase :unused
execute 'must-not-run' do
  command 'exit 42'
end
RUBY
printf "raise 'missing bundle helper' unless File.exist?('payload.txt')\n" > "$fixture/bundle/helper.rb"
printf payload > "$fixture/bundle/payload.txt"
data="{\"destination\":\"$fixture/result\"}"
secrets='{"token":"secret '\'' $(echo should-not-run)"}'
run "$fixture/bundle/nested/main's.rb" "${common[@]}" --identity "$fixture/client" \
  --bundle "$fixture/bundle" --phase deploy --data-bag "$data" --secrets-bag "$secrets" || fail
[ "$(cat "$fixture/result")" = 'payloadsecret '\'' $(echo should-not-run)' ] || fail
grep -q 'Uploading Hola binary' "$fixture/output.log" || fail
echo 'PASS private key, bundle, quoted paths, phase and secret transport'
run "$fixture/bundle/nested/main's.rb" "${common[@]}" --identity "$fixture/client" \
  --bundle "$fixture/bundle" --phase deploy --data-bag "$data" --secrets-bag "$secrets" || fail
if grep -q 'Uploading Hola binary' "$fixture/output.log"; then fail; fi
echo 'PASS binary cache reuse and repeated provision'

# A private agent proves we use SSH_AUTH_SOCK without touching personal keys.
eval "$(ssh-agent -s)" >/dev/null
agent_pid="$SSH_AGENT_PID"
ssh-add "$fixture/client" >/dev/null 2>&1
printf "file '$fixture/agent-result' do\n  content 'agent'\nend\nfile '$fixture/workspace' do\n  content Dir.pwd\nend\n" > "$fixture/single.rb"
run "$fixture/single.rb" "${common[@]}" || fail
[ "$(cat "$fixture/agent-result")" = agent ] || fail
[ ! -d "$(cat "$fixture/workspace")" ] || fail
echo 'PASS SSH agent authentication and single script'

# ~/.ssh/config: aliases, Include with a quoted path, IdentityFile and a per-host IdentityAgent.
mkdir -p "$fixture/home/.ssh" "$fixture/home/Application Support"
cat > "$fixture/home/.ssh/config" <<EOF
Include "~/Application Support/generated.conf"
Host loop
    HostName 127.0.0.1
    Port $port
    User $(id -un)
    IdentityFile none
    IdentityFile ~/missing-key
    IdentityFile $fixture/client
    UserKnownHostsFile $fixture/known_hosts
Host jump
    HostName 127.0.0.1
    ProxyJump bastion.example
Host *
    UserKnownHostsFile $fixture/known_hosts
    Port $port
EOF
cat > "$fixture/home/Application Support/generated.conf" <<EOF
Host agent-*
    HostName 127.0.0.1
    User "$(id -un)"
    IdentityAgent "$SSH_AUTH_SOCK"
    IdentityFile none
EOF
rm -f "$fixture/agent-result"
# No agent reachable, so the IdentityFile list must carry the login.
SSH_AUTH_SOCK= run "$fixture/single.rb" --host loop || fail
[ "$(cat "$fixture/agent-result")" = agent ] || fail
grep -q 'Applying .*/.ssh/config for loop' "$fixture/output.log" || fail
rm -f "$fixture/agent-result"
SSH_AUTH_SOCK= run "$fixture/single.rb" --host agent-loop || fail
[ "$(cat "$fixture/agent-result")" = agent ] || fail
if run "$fixture/single.rb" --host jump; then fail; fi
grep -q 'ProxyJumpUnsupported' "$fixture/output.log" || fail
if run "$fixture/single.rb" --host loop --port 1; then fail; fi
grep -q 'Cannot connect to 127.0.0.1:1' "$fixture/output.log" || fail
echo 'PASS ssh_config aliases, Include, IdentityAgent, ProxyJump refusal and CLI precedence'

# git over SSH resolves the same config: hola git-clone and the git resource.
# libgit2 verifies host keys against ~/.ssh/known_hosts of the isolated HOME.
cp "$fixture/known_hosts" "$fixture/home/.ssh/known_hosts"
cat >> "$fixture/home/.ssh/config" <<EOF
Host gitloop
    HostName 127.0.0.1
    User $(id -un)
    IdentityFile $fixture/client
EOF
git init -q --bare "$fixture/repo.git"
git -C "$fixture/repo.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$fixture/src"
git -C "$fixture/src" -c user.name=hola -c user.email=hola@example.com commit -q --allow-empty -m init
git -C "$fixture/src" push -q "$fixture/repo.git" main
mkdir -p "$fixture/home/repos"
git clone -q --bare "$fixture/repo.git" "$fixture/home/repos/rel.git"
run_clone() {
  HOME="$fixture/home" "$binary" git-clone --quiet "$@" > "$fixture/output.log" 2>&1
}
SSH_AUTH_SOCK= run_clone "gitloop:$fixture/repo.git" "$fixture/clone-abs" || fail
[ "$(git -C "$fixture/clone-abs" remote get-url origin)" = "gitloop:$fixture/repo.git" ] || fail
[ "$(git -C "$fixture/clone-abs" rev-parse HEAD)" = "$(git -C "$fixture/src" rev-parse HEAD)" ] || fail
SSH_AUTH_SOCK= run_clone gitloop:repos/rel.git "$fixture/clone-rel" || fail
[ "$(git -C "$fixture/clone-rel" rev-parse HEAD)" = "$(git -C "$fixture/src" rev-parse HEAD)" ] || fail
SSH_AUTH_SOCK= run_clone "agent-git:$fixture/repo.git" "$fixture/clone-agent" || fail
if SSH_AUTH_SOCK= run_clone "$(id -un)@127.0.0.1:$fixture/repo.git" "$fixture/clone-plain"; then fail; fi
# An encrypted default key cannot be loaded without a passphrase and must be skipped for the next one.
ssh-keygen -q -t ed25519 -N 'passphrase' -f "$fixture/home/.ssh/id_ed25519"
cp "$fixture/client" "$fixture/home/.ssh/id_rsa"
SSH_AUTH_SOCK= run_clone "$(id -un)@127.0.0.1:$fixture/repo.git" "$fixture/clone-plain" || fail
[ "$(git -C "$fixture/clone-plain" rev-parse HEAD)" = "$(git -C "$fixture/src" rev-parse HEAD)" ] || fail
# A corrupted key passes the header check; libssh2's rejection must lead to a retry with the next key.
awk 'NR == 3 { gsub(/./, "A") } { print }' "$fixture/client" > "$fixture/home/.ssh/id_ed25519"
rm -rf "$fixture/clone-plain"
SSH_AUTH_SOCK= run_clone "$(id -un)@127.0.0.1:$fixture/repo.git" "$fixture/clone-plain" || fail
[ "$(git -C "$fixture/clone-plain" rev-parse HEAD)" = "$(git -C "$fixture/src" rev-parse HEAD)" ] || fail
grep -q 'trying the next candidate' "$XDG_STATE_HOME"/hola/logs/*.log || fail
echo 'PASS git-clone through ssh_config: IdentityFile, relative path, IdentityAgent, alias kept, encrypted and corrupted default keys skipped'

cat > "$fixture/git.rb" <<RUBY
git '$fixture/resource-clone' do
  repository 'gitloop:$fixture/repo.git'
  revision 'main'
end
RUBY
SSH_AUTH_SOCK= run "$fixture/git.rb" || fail
[ "$(git -C "$fixture/resource-clone" remote get-url origin)" = "gitloop:$fixture/repo.git" ] || fail
git -C "$fixture/src" -c user.name=hola -c user.email=hola@example.com commit -q --allow-empty -m second
git -C "$fixture/src" push -q "$fixture/repo.git" main
SSH_AUTH_SOCK= run "$fixture/git.rb" || fail
[ "$(git -C "$fixture/resource-clone" rev-parse HEAD)" = "$(git -C "$fixture/src" rev-parse HEAD)" ] || fail
[ "$(git -C "$fixture/resource-clone" remote get-url origin)" = "gitloop:$fixture/repo.git" ] || fail
echo 'PASS git resource clone and sync through ssh_config'

for known in empty_known_hosts wrong_known_hosts; do
  if run "$fixture/single.rb" --host "$(id -un)@127.0.0.1" --port "$port" \
      --known-hosts "$fixture/$known" --identity "$fixture/client"; then fail; fi
  grep -Eq 'UnknownHostKey|HostKeyMismatch' "$fixture/output.log" || fail
done
echo 'PASS unknown and mismatched host keys rejected'

cp "$fixture/known_hosts" "$fixture/hashed_known_hosts"
ssh-keygen -q -H -f "$fixture/hashed_known_hosts" >/dev/null 2>&1
run "$fixture/single.rb" --host "$(id -un)@127.0.0.1" --port "$port" \
  --known-hosts "$fixture/hashed_known_hosts" --identity "$fixture/client" || fail
if run "$fixture/single.rb" "${common[@]}" --identity "$fixture/wrong-host"; then fail; fi
grep -q 'SshKeyAuthenticationFailed' "$fixture/output.log" || fail
echo 'PASS hashed known_hosts and authentication failure'

printf "execute 'failure' do\n  command 'exit 23'\nend\n" > "$fixture/failure.rb"
if run "$fixture/failure.rb" "${common[@]}" --identity "$fixture/client"; then fail; fi
grep -q 'RemoteProvisionFailed' "$fixture/output.log" || fail
echo 'PASS remote resource failure returns nonzero'

ln -s "$fixture/single.rb" "$fixture/bundle/link.rb"
if run "$fixture/bundle/nested/main's.rb" "${common[@]}" --bundle "$fixture/bundle"; then fail; fi
grep -q 'UnsupportedBundleEntry' "$fixture/output.log" || fail
rm "$fixture/bundle/link.rb"
echo 'PASS bundle symlinks rejected'

if run "$fixture/single.rb" "${common[@]}" --bundle "$fixture/bundle"; then fail; fi
grep -q 'ScriptOutsideBundle' "$fixture/output.log" || fail
if run "$fixture/single.rb" "${common[@]}" --remote-binary "$fixture/single.rb"; then fail; fi
grep -q 'RemoteBinaryPlatformMismatch' "$fixture/output.log" || fail
echo 'PASS bundle containment and binary platform checks'

# Drain enough data on both streams to exceed SSH windows, including a silent interval.
cat > "$fixture/output.rb" <<'RUBY'
execute 'large output' do
  command "awk 'BEGIN { for(i=0;i<100000;i++) print \"stdout-line\" }'; awk 'BEGIN { for(i=0;i<100000;i++) print \"stderr-line\" }' >&2; sleep 1"
  live_stream true
end
RUBY
run "$fixture/output.rb" "${common[@]}" --identity "$fixture/client" || fail
echo 'PASS large remote output and silent commands'

if [ "${HOLA_TEST_SUDO:-0}" = 1 ]; then
  run "$fixture/single.rb" "${common[@]}" --identity "$fixture/client" --sudo || fail
  [ ! -d "$(cat "$fixture/workspace")" ] || fail
  echo 'PASS sudo worker result permissions and cleanup'
fi

# Abrupt worker death must never be reported as success or automatically retried.
cat > "$fixture/interrupted.rb" <<RUBY
execute 'interrupted worker' do
  command 'echo attempt >> "$fixture/attempts"; kill -KILL \$PPID'
end
RUBY
if run "$fixture/interrupted.rb" "${common[@]}" --identity "$fixture/client"; then fail; fi
grep -q 'RemoteOutcomeUnknown' "$fixture/output.log" || fail
[ "$(wc -l < "$fixture/attempts" | tr -d ' ')" = 1 ] || fail
retained="$(sed -n 's/^\[ssh\] Workspace retained for inspection: //p' "$fixture/output.log")"
if [[ "$retained" =~ ^/tmp/hola-[a-zA-Z0-9]{12}$ ]]; then
  [ -d "$retained" ] || fail
  rm -rf -- "$retained"
else
  fail
fi
echo 'PASS interrupted worker reports unknown outcome without retry'

echo 'All remote provision integration tests passed.'
