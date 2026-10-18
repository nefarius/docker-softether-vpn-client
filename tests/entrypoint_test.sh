#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="${ROOT}/assets/entrypoint.sh"
DHCPCD="${ROOT}/assets/dhcpcd-vpn"
TMP="$(mktemp -d)"
PASS=0

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    PASS=$((PASS + 1))
    printf 'ok %s\n' "$1"
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        fail "${3}: expected [${2}] got [${1}]"
    fi
}

assert_contains() {
    if ! grep -F -q -- "$2" "$1"; then
        printf 'Log contents:\n' >&2
        cat "$1" >&2
        fail "$3"
    fi
}

assert_not_contains() {
    if grep -F -q -- "$2" "$1"; then
        printf 'Log contents:\n' >&2
        cat "$1" >&2
        fail "$3"
    fi
}

new_case() {
    CASE="$TMP/case-$$-$PASS"
    rm -rf "$CASE"
    mkdir -p "$CASE/bin" "$CASE/client"
    MOCK_LOG="$CASE/log"
    : > "$MOCK_LOG"
    cat > "$CASE/bin/vpnclient" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'vpnclient argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'vpnclient arg=%s\n' "$arg"
    done
} >> "$log"
exit 0
EOF
    cat > "$CASE/bin/vpncmd" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'vpncmd argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'vpncmd arg=%s\n' "$arg"
    done
} >> "$log"
if [ "${VPNCMD_FAIL_COMMAND:-}" = "$4" ]; then
    printf 'vpncmd failed:'
    for arg in "$@"; do
        printf ' %s' "$arg"
    done
    printf '\n'
    exit 1
fi
exit 0
EOF
    chmod 755 "$CASE/bin/vpnclient" "$CASE/bin/vpncmd"
    cat > "$CASE/bin/supervisord" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'supervisord argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'supervisord arg=%s\n' "$arg"
    done
} >> "$log"
exit 0
EOF
    chmod 755 "$CASE/bin/supervisord"
    printf '  eth0: 0\n' > "$CASE/netdev"
    printf 'placeholder\n' > "$CASE/client/vpn_client.config"
}

run_entry() {
    # shellcheck disable=SC2086
    env \
        PATH="$CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$MOCK_LOG" \
        SE_CLIENT_DIR="$CASE/client" \
        SE_NET_DEV="$CASE/netdev" \
        SE_READY_ATTEMPTS="${SE_READY_ATTEMPTS:-5}" \
        SE_READY_INTERVAL=0 \
        VPNCMD_FAIL_COMMAND="${VPNCMD_FAIL_COMMAND:-}" \
        SE_SERVER="${SE_SERVER-}" \
        SE_HUB="${SE_HUB-}" \
        SE_USERNAME="${SE_USERNAME-}" \
        SE_PASSWORD="${SE_PASSWORD-}" \
        SE_ACCOUNT_NAME="${SE_ACCOUNT_NAME-default}" \
        SE_NICNAME="${SE_NICNAME-vpn}" \
        SE_TYPE="${SE_TYPE-standard}" \
        sh "$ENTRYPOINT" "$@"
}

run_setup() {
    status=0
    output="$(run_entry supervisord -c /etc/supervisord.conf 2>&1)" || status=$?
}

base_env() {
    SE_SERVER="vpn.example.net:443"
    SE_HUB="TheHub"
    SE_USERNAME="vpnuser"
    SE_PASSWORD="secret"
    SE_ACCOUNT_NAME="default"
    SE_NICNAME="vpn"
    SE_TYPE="standard"
    SE_READY_ATTEMPTS=5
    VPNCMD_FAIL_COMMAND=""
}

new_case
base_env
unset SE_SERVER
run_setup
assert_eq "$status" "1" "missing SE_SERVER status"
printf '%s\n' "$output" | grep -F -q "Please provide SE_SERVER" || fail "missing SE_SERVER message"
assert_not_contains "$MOCK_LOG" "vpnclient arg=start" "missing SE_SERVER must not start the client"
pass "missing SE_SERVER"

for missing in SE_HUB SE_USERNAME SE_PASSWORD SE_ACCOUNT_NAME SE_NICNAME; do
    new_case
    base_env
    eval "unset $missing"
    if [ "$missing" = "SE_ACCOUNT_NAME" ] || [ "$missing" = "SE_NICNAME" ]; then
        eval "$missing="
    fi
    run_setup
    assert_eq "$status" "1" "missing ${missing} status"
    printf '%s\n' "$output" | grep -F -q "Please provide ${missing}" || fail "missing ${missing} message"
    pass "missing ${missing}"
done

new_case
base_env
SE_TYPE="cert"
run_setup
assert_eq "$status" "1" "invalid SE_TYPE status"
printf '%s\n' "$output" | grep -F -q "SE_TYPE must be standard or radius" || fail "invalid SE_TYPE message"
pass "invalid SE_TYPE"

new_case
base_env
SE_SERVER="vpn.example.net 443"
run_setup
assert_eq "$status" "1" "unsafe SE_SERVER status"
printf '%s\n' "$output" | grep -F -q "SE_SERVER contains unsupported characters" || fail "unsafe SE_SERVER message"
pass "unsafe SE_SERVER"

new_case
base_env
SE_SERVER="2001:db8::1"
run_setup
assert_eq "$status" "1" "IPv6 SE_SERVER status"
printf '%s\n' "$output" | grep -F -q "SE_SERVER contains unsupported characters" || fail "IPv6 SE_SERVER message"
assert_not_contains "$MOCK_LOG" "vpnclient arg=start" "IPv6 SE_SERVER must not start the client"
pass "IPv6 SE_SERVER"

new_case
base_env
SE_NICNAME="thisnameistoolong"
run_setup
assert_eq "$status" "1" "long SE_NICNAME status"
printf '%s\n' "$output" | grep -F -q "11 characters" || fail "long SE_NICNAME message"
pass "long SE_NICNAME"

new_case
status=0
output="$(
    env PATH="$CASE/bin:/usr/bin:/bin" MOCK_LOG="$MOCK_LOG" \
        sh "$ENTRYPOINT" /bin/echo "hello vpn" 2>&1
)" || status=$?
assert_eq "$status" "0" "passthrough status"
assert_eq "$output" "hello vpn" "passthrough output"
assert_eq "$(wc -c < "$MOCK_LOG" | tr -d ' ')" "0" "passthrough must not call vpnclient"
pass "command passthrough"

new_case
status=0
output="$(env PATH="/usr/bin:/bin" sh "$ENTRYPOINT" 2>&1)" || status=$?
assert_eq "$status" "1" "missing command status"
printf '%s\n' "$output" | grep -F -q "No command specified" || fail "missing command message"
pass "missing command"

new_case
base_env
SE_HUB="The Hub"
SE_PASSWORD="secret \$(touch ${CASE}/pwned) and spaces"
SE_NICNAME="OfficeVPN"
run_setup
assert_eq "$status" "0" "successful setup status"
assert_eq "$output" "" "successful setup stays quiet"
test ! -e "$CASE/client/vpn_client.config" || fail "old client config was not removed"
test ! -e "$CASE/pwned" || fail "password was evaluated by the shell"
assert_contains "$MOCK_LOG" "vpnclient arg=start" "client was not started"
assert_contains "$MOCK_LOG" "vpncmd arg=NicCreate" "adapter was not created"
assert_contains "$MOCK_LOG" "vpncmd arg=officevpn" "adapter name was not normalized"
assert_contains "$MOCK_LOG" "vpncmd arg=/HUB:The Hub" "hub argument was split"
assert_contains "$MOCK_LOG" "vpncmd arg=/PASSWORD:secret \$(touch ${CASE}/pwned) and spaces" "password was not passed literally"
assert_contains "$MOCK_LOG" "vpncmd arg=/TYPE:standard" "password type was not set"
assert_contains "$MOCK_LOG" "vpncmd arg=AccountStartupSet" "auto-connect was not set"
assert_contains "$MOCK_LOG" "vpnclient arg=stop" "client was not stopped before exec"
assert_contains "$MOCK_LOG" "supervisord arg=-c" "supervisord was not executed"
assert_contains "$MOCK_LOG" "supervisord arg=/etc/supervisord.conf" "supervisord configuration was not preserved"
pass "successful quoted setup"

new_case
base_env
printf '  vpn_vpn:0\n' > "$CASE/netdev"
run_setup
assert_eq "$status" "0" "existing adapter status"
printf '%s\n' "$output" | grep -F -q "NIC vpn already exists, skipping creation" || fail "existing adapter message"
assert_not_contains "$MOCK_LOG" "vpncmd arg=NicCreate" "existing adapter was created again"
assert_contains "$MOCK_LOG" "vpncmd arg=AccountCreate" "account setup did not continue"
pass "existing adapter"

new_case
base_env
VPNCMD_FAIL_COMMAND="AccountCreate"
run_setup
assert_eq "$status" "1" "setup failure status"
assert_contains "$MOCK_LOG" "vpnclient arg=start" "failed setup did not start the client"
assert_contains "$MOCK_LOG" "vpnclient arg=stop" "failed setup did not stop the client"
pass "setup failure cleanup"

new_case
base_env
SE_PASSWORD="visible-secret-value"
VPNCMD_FAIL_COMMAND="AccountPasswordSet"
run_setup
assert_eq "$status" "1" "password failure status"
printf '%s\n' "$output" | grep -F -q "Failed to set the VPN account password" || fail "password failure message"
if printf '%s\n' "$output" | grep -F -q "visible-secret-value"; then
    fail "password failure exposed SE_PASSWORD"
fi
assert_contains "$MOCK_LOG" "vpnclient arg=stop" "password failure did not stop the client"
pass "password failure hides the password"

new_case
base_env
VPNCMD_FAIL_COMMAND="NicList"
SE_READY_ATTEMPTS=2
run_setup
assert_eq "$status" "1" "readiness timeout status"
printf '%s\n' "$output" | grep -F -q "Timed out waiting for the SoftEther VPN client service" || fail "readiness timeout message"
assert_contains "$MOCK_LOG" "vpnclient arg=stop" "timed-out setup did not stop the client"
pass "client readiness timeout"

DHCP_CASE="$TMP/dhcp"
mkdir -p "$DHCP_CASE/bin" "$DHCP_CASE/sys"
cat > "$DHCP_CASE/bin/dhcpcd" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'dhcpcd argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'dhcpcd arg=%s\n' "$arg"
    done
} >> "$log"
exit 0
EOF
chmod 755 "$DHCP_CASE/bin/dhcpcd"
mkdir -p "$DHCP_CASE/sys/vpn_office"
: > "$DHCP_CASE/dhcp.log"

status=0
output="$(
    env PATH="$DHCP_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$DHCP_CASE/dhcp.log" \
        SE_SYS_NET="$DHCP_CASE/sys" \
        SE_NICNAME="office" \
        SE_DHCP_WAIT_ATTEMPTS=2 \
        SE_DHCP_WAIT_INTERVAL=0 \
        sh "$DHCPCD" 2>&1
)" || status=$?
assert_eq "$status" "0" "dhcpcd status"
assert_eq "$output" "" "dhcpcd output"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=--nobackground" "dhcpcd was not kept in the foreground"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=--nohook" "dhcpcd hook suppression was not requested"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=resolv.conf" "dhcpcd was allowed to update resolv.conf"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=--broadcast" "dhcpcd did not request a broadcast offer"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=--noipv4ll" "dhcpcd was allowed to fall back to IPv4LL"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=vpn_office" "dhcpcd used the wrong interface"
pass "dhcpcd starts for an existing adapter"

status=0
output="$(
    env PATH="$DHCP_CASE/bin:/usr/bin:/bin" \
        SE_SYS_NET="$DHCP_CASE/sys" \
        SE_DHCP_WAIT_ATTEMPTS=2 \
        SE_DHCP_WAIT_INTERVAL=0 \
        sh "$DHCPCD" 2>&1
)" || status=$?
assert_eq "$status" "1" "missing dhcp nic status"
printf '%s\n' "$output" | grep -F -q "Please provide SE_NICNAME" || fail "missing dhcp nic message"
pass "dhcpcd requires SE_NICNAME"

status=0
output="$(
    env PATH="$DHCP_CASE/bin:/usr/bin:/bin" \
        SE_SYS_NET="$DHCP_CASE/sys" \
        SE_NICNAME="missing" \
        SE_DHCP_WAIT_ATTEMPTS=2 \
        SE_DHCP_WAIT_INTERVAL=0 \
        sh "$DHCPCD" 2>&1
)" || status=$?
assert_eq "$status" "1" "dhcp wait status"
printf '%s\n' "$output" | grep -F -q "Timed out waiting for vpn_missing" || fail "dhcp wait message"
pass "dhcpcd waits for the adapter"

printf '%s tests passed\n' "$PASS"
