#!/usr/bin/env bash
# Joins a GitHub Actions job to an agentiscale network with the job's OIDC
# token and runs the node in the background. action.yml passes the inputs as
# AGENTISCALE_* variables.
set -euo pipefail

fail() {
	echo "::error title=agentiscale::$*"
	exit 1
}

network=${AGENTISCALE_NETWORK:-}
[[ "$network" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
	fail "network-id must be your network's ID, as the console shows it under your network's name"
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] ||
	fail "the job can't ask GitHub for an OIDC token: give it 'permissions: id-token: write'"
control=${AGENTISCALE_CONTROL:-https://control.agentiscale.net}
# Control builds the audience it expects from its URL without trailing
# slashes.
while [ "${control%/}" != "$control" ]; do control=${control%/}; done
data_dir=$AGENTISCALE_DATA_DIR
timeout=${AGENTISCALE_TIMEOUT:-120}
[[ "$timeout" =~ ^[0-9]+$ ]] || fail "timeout-seconds must be a whole number"

case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
Linux/X64 | Linux/ARM64 | macOS/X64 | macOS/ARM64) ;;
*) fail "agentiscaled runs on Linux and macOS runners (x64 or ARM64), not ${RUNNER_OS:-?}/${RUNNER_ARCH:-?}" ;;
esac

# ---- the release, checked against its checksums by agentiscaled's install.sh ----
# The script is pinned to a commit of whiteredhouse/agentiscaled; bump it
# there and here together.
install_sh=https://raw.githubusercontent.com/whiteredhouse/agentiscaled/3d79b175e4a3d68ee0f07205152f2e39b5cbc289/install.sh
min=v0.11.0
version=${AGENTISCALE_VERSION:-latest}
older() { [ "$(printf '%s\n' "$min" "$1" | sort -V | head -n 1)" != "$min" ]; }
if [ "$version" != latest ]; then
	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be a release like v0.12.0 or latest, not '$version'"
	! older "$version" || fail "$version can't join with an OIDC token; use $min or later"
fi
install_dir="${RUNNER_TEMP:-/tmp}/agentiscaled"
bin="$install_dir/agentiscaled"
script=$(mktemp)
curl -sSfL --retry 3 -o "$script" "$install_sh" || fail "couldn't download install.sh"
PATH="$install_dir:$PATH" AGENTISCALE_VERSION=$version AGENTISCALE_INSTALL_DIR=$install_dir sh "$script" ||
	fail "couldn't install agentiscaled $version"
rm -f "$script"
installed=$("$bin" version 2>&1 | sed -n 's/^agentiscaled \([0-9][^ ]*\) .*/v\1/p' | head -n 1)
[ -n "$installed" ] || fail "the installed agentiscaled doesn't report its version"
! older "$installed" || fail "$installed can't join with an OIDC token; use $min or later"
echo "$install_dir" >>"$GITHUB_PATH"

# ---- join with a token for this network only ----
mkdir -p "$data_dir"
chmod 700 "$data_dir"
token_file="$data_dir/oidc-token"
trap 'rm -f "$token_file"' EXIT
answer=$(curl -sSf --retry 3 -G -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
	--data-urlencode "audience=$control/networks/$network" "$ACTIONS_ID_TOKEN_REQUEST_URL") ||
	fail "GitHub didn't issue an OIDC token"
token=$(printf '%s' "$answer" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$token" ] || fail "GitHub's OIDC answer had no token"
echo "::add-mask::$token"
(umask 077 && printf '%s\n' "$token" >"$token_file")
# The node API listens only on its Unix socket, so it takes no TCP port
# from the job.
"$bin" up -foreground -y -clients none -data-dir "$data_dir" -control "$control" \
	-network "$network" -oidc-token-path "$token_file" \
	-hostname "${AGENTISCALE_HOSTNAME:-github-${GITHUB_RUN_ID:-0}}" -bind-addr ""
rm -f "$token_file"

# ---- run the node until the job ends ----
log="$data_dir/node.log"
nohup "$bin" run -data-dir "$data_dir" >>"$log" 2>&1 &
pid=$!
echo "$pid" >"$data_dir/node.pid"
deadline=$((SECONDS + timeout))
until "$bin" status -data-dir "$data_dir" 2>/dev/null | grep -q '^Mesh connection: connected'; do
	if ! kill -0 "$pid" 2>/dev/null; then
		tail -n 40 "$log" || true
		fail "the node exited before it connected to the network; its log is above"
	fi
	if [ "$SECONDS" -ge "$deadline" ]; then
		tail -n 40 "$log" || true
		fail "the node didn't connect to the network within ${timeout}s; its log is above"
	fi
	sleep 2
done
peer=$("$bin" status -data-dir "$data_dir" | sed -n 's/^Node: *\([^ ]*\).*/\1/p')
echo "Joined network $network as $peer"
{
	echo "data-dir=$data_dir"
	echo "peer-id=$peer"
	echo "log=$log"
} >>"$GITHUB_OUTPUT"
