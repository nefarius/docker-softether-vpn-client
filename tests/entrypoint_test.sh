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
    printf 'supervisord env SE_DNS_ENABLED=%s\n' "${SE_DNS_ENABLED-unset}"
    for arg in "$@"; do
        printf 'supervisord arg=%s\n' "$arg"
    done
} >> "$log"
exit 0
EOF
    chmod 755 "$CASE/bin/supervisord"
    printf '  eth0: 0\n' > "$CASE/netdev"
    printf 'placeholder\n' > "$CASE/client/vpn_client.config"
    SE_RESOLV_CONF="$CASE/resolv.conf"
    SE_DNSMASQ_CONF="$CASE/dnsmasq.conf"
    SE_DNS_RUN_DIR="$CASE/run"
    SE_DNS_STATE_DIR="$CASE/state"
    printf 'nameserver 127.0.0.11\noptions ndots:0\n' > "$SE_RESOLV_CONF"
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
        SE_DNS_DOMAINS="${SE_DNS_DOMAINS-}" \
        SE_DNS_SERVERS="${SE_DNS_SERVERS-}" \
        SE_DNS_SEARCH="${SE_DNS_SEARCH-}" \
        SE_MAC_ADDRESS="${SE_MAC_ADDRESS-}" \
        SE_DHCP_HOSTNAME="${SE_DHCP_HOSTNAME-}" \
        SE_HEALTH_CHECK_TARGET="${SE_HEALTH_CHECK_TARGET-}" \
        SE_RESOLV_CONF="${SE_RESOLV_CONF-}" \
        SE_DNSMASQ_CONF="${SE_DNSMASQ_CONF-}" \
        SE_DNS_RUN_DIR="${SE_DNS_RUN_DIR-}" \
        SE_DNS_STATE_DIR="${SE_DNS_STATE_DIR-}" \
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
    SE_DNS_DOMAINS=""
    SE_DNS_SERVERS=""
    SE_DNS_SEARCH=""
    SE_MAC_ADDRESS=""
    SE_DHCP_HOSTNAME=""
    SE_HEALTH_CHECK_TARGET=""
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
assert_not_contains "$MOCK_LOG" "vpncmd arg=NicSetSetting" "MAC setting was applied without SE_MAC_ADDRESS"
assert_contains "$MOCK_LOG" "supervisord env SE_DNS_ENABLED=false" "split DNS was enabled by default"
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
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=-f" "dhcpcd was not given a config file"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=/etc/dhcpcd-vpn-duid.conf" "dhcpcd did not keep the DUID client identifier"
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

: > "$DHCP_CASE/dhcp.log"
status=0
output="$(
    env PATH="$DHCP_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$DHCP_CASE/dhcp.log" \
        SE_SYS_NET="$DHCP_CASE/sys" \
        SE_NICNAME="office" \
        SE_DHCP_HOSTNAME="vps-services" \
        SE_DHCP_WAIT_ATTEMPTS=2 \
        SE_DHCP_WAIT_INTERVAL=0 \
        sh "$DHCPCD" 2>&1
)" || status=$?
assert_eq "$status" "0" "dhcpcd hostname status"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=--hostname=vps-services" "dhcpcd was not given the hostname"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=/etc/dhcpcd-vpn-duid.conf" "hostname request changed the client identifier"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=-e" "dhcpcd was not given a hook environment"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=SE_NICNAME=office" "dhcpcd hook environment omitted SE_NICNAME"
pass "dhcpcd sends the configured hostname"

: > "$DHCP_CASE/dhcp.log"
status=0
output="$(
    env PATH="$DHCP_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$DHCP_CASE/dhcp.log" \
        SE_SYS_NET="$DHCP_CASE/sys" \
        SE_NICNAME="office" \
        SE_DNS_DOMAINS="lan,home.arpa" \
        SE_DNS_SERVERS="" \
        SE_DNS_RUN_DIR="/run/softether-dns" \
        SE_DHCP_WAIT_ATTEMPTS=2 \
        SE_DHCP_WAIT_INTERVAL=0 \
        sh "$DHCPCD" 2>&1
)" || status=$?
assert_eq "$status" "0" "dhcpcd split DNS environment status"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=SE_DNS_DOMAINS=lan,home.arpa" "dhcpcd hook environment omitted SE_DNS_DOMAINS"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=SE_NICNAME=office" "dhcpcd hook environment omitted the NIC name"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=SE_DNS_RUN_DIR=/run/softether-dns" "dhcpcd hook environment omitted SE_DNS_RUN_DIR"
assert_not_contains "$DHCP_CASE/dhcp.log" "SE_DNS_SERVERS" "unset SE_DNS_SERVERS was passed to the hook"
pass "dhcpcd forwards split DNS settings when servers come from the lease"

: > "$DHCP_CASE/dhcp.log"
status=0
output="$(
    env PATH="$DHCP_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$DHCP_CASE/dhcp.log" \
        SE_SYS_NET="$DHCP_CASE/sys" \
        SE_NICNAME="office" \
        SE_DNS_DOMAINS="lan" \
        SE_DNS_SERVERS="192.168.1.1" \
        SE_DNS_RUN_DIR="" \
        SE_DHCP_WAIT_ATTEMPTS=2 \
        SE_DHCP_WAIT_INTERVAL=0 \
        sh "$DHCPCD" 2>&1
)" || status=$?
assert_eq "$status" "0" "dhcpcd static DNS environment status"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=SE_DNS_SERVERS=192.168.1.1" "dhcpcd hook environment omitted static DNS servers"
assert_not_contains "$DHCP_CASE/dhcp.log" "SE_DNS_RUN_DIR" "the default hook directory was overridden"
pass "dhcpcd forwards static DNS servers and keeps the default run directory"

cat > "$DHCP_CASE/bin/ip" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'ip argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'ip arg=%s\n' "$arg"
    done
} >> "$log"
exit 0
EOF
chmod 755 "$DHCP_CASE/bin/ip"
printf '00:11:22:33:44:55\n' > "$DHCP_CASE/sys/vpn_office/address"
: > "$DHCP_CASE/dhcp.log"
status=0
output="$(
    env PATH="$DHCP_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$DHCP_CASE/dhcp.log" \
        SE_SYS_NET="$DHCP_CASE/sys" \
        SE_NICNAME="office" \
        SE_MAC_LINUX="aa:bb:cc:dd:ee:02" \
        SE_DHCP_WAIT_ATTEMPTS=2 \
        SE_DHCP_WAIT_INTERVAL=0 \
        sh "$DHCPCD" 2>&1
)" || status=$?
assert_eq "$status" "0" "dhcpcd mac fallback status"
assert_contains "$DHCP_CASE/dhcp.log" "ip arg=down" "adapter was not brought down before the MAC change"
assert_contains "$DHCP_CASE/dhcp.log" "ip arg=aa:bb:cc:dd:ee:02" "fallback MAC was not applied"
assert_contains "$DHCP_CASE/dhcp.log" "ip arg=up" "adapter was not brought back up"
assert_contains "$DHCP_CASE/dhcp.log" "dhcpcd arg=/etc/dhcpcd-vpn.conf" "fixed MAC did not select the clientid configuration"
pass "dhcpcd applies a fixed MAC before requesting a lease"

printf 'aa:bb:cc:dd:ee:02\n' > "$DHCP_CASE/sys/vpn_office/address"
: > "$DHCP_CASE/dhcp.log"
status=0
output="$(
    env PATH="$DHCP_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$DHCP_CASE/dhcp.log" \
        SE_SYS_NET="$DHCP_CASE/sys" \
        SE_NICNAME="office" \
        SE_MAC_LINUX="aa:bb:cc:dd:ee:02" \
        SE_DHCP_WAIT_ATTEMPTS=2 \
        SE_DHCP_WAIT_INTERVAL=0 \
        sh "$DHCPCD" 2>&1
)" || status=$?
assert_eq "$status" "0" "dhcpcd matching mac status"
assert_not_contains "$DHCP_CASE/dhcp.log" "ip arg=address" "matching MAC was changed again"
pass "dhcpcd leaves a matching MAC in place"

new_case
base_env
before="$(cat "$SE_RESOLV_CONF")"
run_setup
assert_eq "$status" "0" "dns disabled status"
assert_eq "$(cat "$SE_RESOLV_CONF")" "$before" "disabled split DNS changed resolv.conf"
test ! -e "$SE_DNSMASQ_CONF" || fail "disabled split DNS wrote a dnsmasq config"
assert_contains "$MOCK_LOG" "supervisord env SE_DNS_ENABLED=false" "disabled split DNS exported the wrong flag"
pass "split DNS disabled leaves resolv.conf unchanged"

new_case
base_env
printf 'nameserver 127.0.0.11\nnameserver 10.4.4.4\nsearch svc.cluster.local\noptions ndots:0\n' > "$SE_RESOLV_CONF"
SE_DNS_DOMAINS="lan,home.arpa,1.168.192.in-addr.arpa"
SE_DNS_SEARCH="lan"
run_setup
assert_eq "$status" "0" "split DNS status"
printf '%s\n' "$output" | grep -F -q "Split DNS enabled for lan,home.arpa,1.168.192.in-addr.arpa" || fail "split DNS was not announced"
assert_eq "$(cat "$SE_RESOLV_CONF")" "# softether-split-dns
nameserver 127.0.0.1
search lan
options ndots:0" "split DNS resolv.conf"
assert_eq "$(cat "$SE_DNS_STATE_DIR/upstream.conf")" "nameserver 127.0.0.11
nameserver 10.4.4.4
search svc.cluster.local
options ndots:0" "saved upstream resolvers"
assert_eq "$(cat "$SE_DNSMASQ_CONF")" "no-resolv
listen-address=127.0.0.1
bind-interfaces
port=53
no-hosts
clear-on-reload
server=127.0.0.11
server=10.4.4.4
servers-file=${SE_DNS_RUN_DIR}/servers.conf" "dnsmasq configuration"
assert_eq "$(cat "$SE_DNS_RUN_DIR/servers.conf")" "server=/lan/
server=/home.arpa/
server=/1.168.192.in-addr.arpa/" "local-only domain seed"
assert_contains "$MOCK_LOG" "supervisord env SE_DNS_ENABLED=true" "split DNS was not enabled for Supervisor"
pass "split DNS captures upstream resolvers"

new_case
base_env
mkdir -p "$SE_DNS_STATE_DIR"
printf 'nameserver 10.1.2.3\noptions ndots:0\n' > "$SE_DNS_STATE_DIR/upstream.conf"
printf '# softether-split-dns\nnameserver 127.0.0.1\nsearch lan\noptions ndots:0\n' > "$SE_RESOLV_CONF"
SE_DNS_DOMAINS="lan"
run_setup
assert_eq "$status" "0" "split DNS restart status"
assert_contains "$SE_DNSMASQ_CONF" "server=10.1.2.3" "restart did not reuse the saved upstream"
assert_not_contains "$SE_DNSMASQ_CONF" "server=127.0.0.1" "restart forwarded DNS to dnsmasq itself"
pass "split DNS reuses the saved upstream on restart"

new_case
base_env
SE_DNS_DOMAINS="lan"
SE_DNS_SERVERS="192.168.1.1,10.0.0.53"
run_setup
assert_eq "$status" "0" "static DNS status"
assert_eq "$(cat "$SE_DNS_RUN_DIR/servers.conf")" "server=/lan/192.168.1.1
server=/lan/10.0.0.53" "static home DNS servers"
pass "split DNS can use static home DNS servers"

new_case
base_env
mkdir -p "$SE_DNS_STATE_DIR"
printf 'nameserver 10.9.8.7\nsearch office.lan\noptions ndots:1\n' > "$SE_DNS_STATE_DIR/upstream.conf"
printf '# softether-split-dns\nnameserver 127.0.0.1\nsearch lan\n' > "$SE_RESOLV_CONF"
run_setup
assert_eq "$status" "0" "split DNS restore status"
printf '%s\n' "$output" | grep -F -q "Split DNS disabled; restored upstream resolvers" || fail "split DNS restore was not announced"
assert_eq "$(cat "$SE_RESOLV_CONF")" "nameserver 10.9.8.7
search office.lan
options ndots:1" "restored resolv.conf"
assert_contains "$MOCK_LOG" "supervisord env SE_DNS_ENABLED=false" "restored split DNS stayed enabled"
pass "disabling split DNS restores the upstream resolv.conf"

for invalid_dns in \
    "SE_DNS_DOMAINS=bad_name|SE_DNS_DOMAINS contains unsupported characters" \
    "SE_DNS_DOMAINS=-bad.lan|SE_DNS_DOMAINS contains unsupported characters" \
    "SE_DNS_SERVERS=10.0.0.256|SE_DNS_DOMAINS=lan|SE_DNS_SERVERS contains an invalid IPv4 address" \
    "SE_DNS_SERVERS=not-an-ip|SE_DNS_DOMAINS=lan|SE_DNS_SERVERS contains an invalid IPv4 address" \
    "SE_DNS_SEARCH=lan|SE_DNS_DOMAINS is required when SE_DNS_SERVERS or SE_DNS_SEARCH is set"
do
    new_case
    base_env
    message=${invalid_dns##*|}
    assignments=${invalid_dns%|*}
    rest=$assignments
    while [ -n "$rest" ]; do
        case "$rest" in
            *\|*)
                assignment=${rest%%|*}
                rest=${rest#*|}
                ;;
            *)
                assignment=$rest
                rest=
                ;;
        esac
        eval "$assignment"
    done
    run_setup
    assert_eq "$status" "1" "invalid DNS status for ${message}"
    printf '%s\n' "$output" | grep -F -q "$message" || fail "invalid DNS message: ${message}"
    assert_not_contains "$MOCK_LOG" "vpnclient arg=start" "invalid DNS started the client"
    pass "rejects ${message}"
done

for valid_target in "192.168.30.139:8081" "ps5-shalltear.lan:443"; do
    new_case
    base_env
    SE_HEALTH_CHECK_TARGET="$valid_target"
    run_setup
    assert_eq "$status" "0" "accepted health target status for ${valid_target}"
    assert_contains "$MOCK_LOG" "vpnclient arg=start" "accepted health target did not start the client"
    pass "accepts SE_HEALTH_CHECK_TARGET ${valid_target}"
done

for invalid_target in \
    "ps5-shalltear.lan:99999|bad port" \
    "ps5-shalltear.lan|missing port" \
    "bad_host:8081|bad host" \
    "ps5-shalltear.lan:|empty port" \
    ":8081|empty host" \
    "192.168.2.256:53|bad address"
do
    new_case
    base_env
    label=${invalid_target##*|}
    SE_HEALTH_CHECK_TARGET=${invalid_target%|*}
    run_setup
    assert_eq "$status" "1" "invalid health target status for ${label}"
    printf '%s\n' "$output" | grep -F -q "SE_HEALTH_CHECK_TARGET must be host:port" || fail "invalid health target message for ${label}"
    assert_not_contains "$MOCK_LOG" "vpnclient arg=start" "invalid health target started the client"
    pass "rejects SE_HEALTH_CHECK_TARGET with ${label}"
done

new_case
base_env
rm -f "$SE_RESOLV_CONF"
SE_DNS_DOMAINS="lan"
run_setup
assert_eq "$status" "1" "missing resolv.conf status"
printf '%s\n' "$output" | grep -F -q "Resolver file ${SE_RESOLV_CONF} is not available" || fail "missing resolv.conf message"
assert_not_contains "$MOCK_LOG" "vpnclient arg=start" "missing resolv.conf started the client"
pass "split DNS requires resolv.conf"

new_case
base_env
printf '# softether-split-dns\nnameserver 127.0.0.1\n' > "$SE_RESOLV_CONF"
SE_DNS_DOMAINS="lan"
run_setup
assert_eq "$status" "1" "missing upstream state status"
printf '%s\n' "$output" | grep -F -q "Split DNS upstream servers were not saved" || fail "missing upstream state message"
pass "split DNS requires the saved upstream"

new_case
base_env
printf 'nameserver 127.0.0.1\n' > "$SE_RESOLV_CONF"
SE_DNS_DOMAINS="lan"
run_setup
assert_eq "$status" "1" "looping upstream status"
printf '%s\n' "$output" | grep -F -q "Refusing to use 127.0.0.1 as an upstream DNS server" || fail "looping upstream message"
pass "split DNS rejects a loop back to itself"

new_case
base_env
SE_MAC_ADDRESS="aa:bb:cc:dd:ee:02"
run_setup
assert_eq "$status" "0" "MAC setup status"
assert_contains "$MOCK_LOG" "vpncmd arg=NicSetSetting" "NicSetSetting was not called"
assert_contains "$MOCK_LOG" "vpncmd arg=/MAC:AA-BB-CC-DD-EE-02" "MAC was not normalized for SoftEther"
printf '%s\n' "$output" | grep -F -q "VPN adapter MAC address set to AA-BB-CC-DD-EE-02" || fail "MAC was not announced"
pass "SE_MAC_ADDRESS is applied to the adapter"

new_case
base_env
SE_MAC_ADDRESS="AA-BB-CC-DD-EE-02"
run_setup
assert_eq "$status" "0" "dashed MAC status"
assert_contains "$MOCK_LOG" "vpncmd arg=/MAC:AA-BB-CC-DD-EE-02" "dashed MAC was not normalized"
pass "SE_MAC_ADDRESS accepts dashed uppercase input"

for invalid_mac in \
    "01:02:03:04:05:06|SE_MAC_ADDRESS must be a unicast address" \
    "ff:ff:ff:ff:ff:ff|SE_MAC_ADDRESS must be a unicast address" \
    "00:00:00:00:00:00|SE_MAC_ADDRESS must not be the all-zero address" \
    "aa:bb:cc:dd:ee|SE_MAC_ADDRESS contains unsupported characters"
do
    new_case
    base_env
    SE_MAC_ADDRESS=${invalid_mac%%|*}
    message=${invalid_mac#*|}
    run_setup
    assert_eq "$status" "1" "invalid MAC status for ${message}"
    printf '%s\n' "$output" | grep -F -q "$message" || fail "invalid MAC message: ${message}"
    assert_not_contains "$MOCK_LOG" "vpnclient arg=start" "invalid MAC started the client"
    pass "rejects ${message}"
done

new_case
base_env
SE_DHCP_HOSTNAME="vps-services"
run_setup
assert_eq "$status" "0" "hostname setup status"
pass "SE_DHCP_HOSTNAME accepts a single label"

for invalid_host in \
    "not_a_host|SE_DHCP_HOSTNAME contains unsupported characters" \
    "-bad|SE_DHCP_HOSTNAME contains unsupported characters" \
    "bad-|SE_DHCP_HOSTNAME contains unsupported characters" \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|SE_DHCP_HOSTNAME must be a single label of 1 to 63 characters"
do
    new_case
    base_env
    SE_DHCP_HOSTNAME=${invalid_host%%|*}
    message=${invalid_host#*|}
    run_setup
    assert_eq "$status" "1" "invalid hostname status for ${message}"
    printf '%s\n' "$output" | grep -F -q "$message" || fail "invalid hostname message: ${message}"
    assert_not_contains "$MOCK_LOG" "vpnclient arg=start" "invalid hostname started the client"
    pass "rejects ${message}"
done

HOOK="${ROOT}/assets/dhcpcd-exit-hook"
HOOK_CASE="$TMP/hook"
mkdir -p "$HOOK_CASE/bin" "$HOOK_CASE/run"
cat > "$HOOK_CASE/bin/pkill" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'pkill argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'pkill arg=%s\n' "$arg"
    done
} >> "$log"
exit "${PKILL_STATUS:-0}"
EOF
chmod 755 "$HOOK_CASE/bin/pkill"

run_hook() {
    env \
        PATH="$HOOK_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$HOOK_CASE/pkill.log" \
        PKILL_STATUS="${PKILL_STATUS:-0}" \
        SE_DNS_DOMAINS="${SE_DNS_DOMAINS-}" \
        SE_DNS_SERVERS="${SE_DNS_SERVERS-}" \
        SE_NICNAME="${SE_NICNAME-vpn}" \
        SE_DNS_RUN_DIR="$HOOK_CASE/run" \
        interface="${interface-}" \
        reason="${reason-}" \
        new_domain_name_servers="${new_domain_name_servers-}" \
        sh -c ". \"\$1\"; printf '%s\n' hook-returned" _ "$HOOK"
}

: > "$HOOK_CASE/pkill.log"
SE_DNS_DOMAINS=""
SE_DNS_SERVERS=""
interface="vpn_vpn"
reason="BOUND"
new_domain_name_servers="192.168.1.1"
status=0
output="$(run_hook 2>&1)" || status=$?
assert_eq "$status" "0" "idle hook status"
assert_eq "$output" "hook-returned" "idle hook did not return to dhcpcd"
test ! -e "$HOOK_CASE/run/servers.conf" || fail "idle hook wrote a servers file"
assert_eq "$(wc -c < "$HOOK_CASE/pkill.log" | tr -d ' ')" "0" "idle hook reloaded dnsmasq"
pass "DHCP hook does nothing unless split DNS is enabled"

SE_DNS_DOMAINS="lan,home.arpa"
SE_DNS_SERVERS=""
interface="vpn_vpn"
reason="BOUND"
new_domain_name_servers="192.168.1.1 10.0.0.53"
: > "$HOOK_CASE/pkill.log"
status=0
output="$(run_hook 2>&1)" || status=$?
assert_eq "$status" "0" "bound hook status"
assert_eq "$output" "hook-returned" "bound hook did not return to dhcpcd"
assert_eq "$(cat "$HOOK_CASE/run/servers.conf")" "server=/lan/192.168.1.1
server=/lan/10.0.0.53
server=/home.arpa/192.168.1.1
server=/home.arpa/10.0.0.53" "bound hook servers file"
assert_contains "$HOOK_CASE/pkill.log" "pkill arg=-HUP" "bound hook did not reload dnsmasq"
assert_contains "$HOOK_CASE/pkill.log" "pkill arg=dnsmasq" "bound hook signalled the wrong process"
pass "DHCP hook forwards VPN domains to the leased DNS servers"

reason="RENEW"
new_domain_name_servers="192.168.1.1"
: > "$HOOK_CASE/pkill.log"
status=0
output="$(run_hook 2>&1)" || status=$?
assert_eq "$status" "0" "renew hook status"
assert_eq "$(cat "$HOOK_CASE/run/servers.conf")" "server=/lan/192.168.1.1
server=/home.arpa/192.168.1.1" "renew hook servers file"
pass "DHCP hook updates servers when the lease is renewed"

for drop_reason in EXPIRE RELEASE NOCARRIER STOP; do
    reason="$drop_reason"
    new_domain_name_servers="192.168.1.1"
    : > "$HOOK_CASE/pkill.log"
    status=0
    output="$(run_hook 2>&1)" || status=$?
    assert_eq "$status" "0" "${drop_reason} hook status"
    assert_eq "$(cat "$HOOK_CASE/run/servers.conf")" "server=/lan/
server=/home.arpa/" "${drop_reason} hook did not stop forwarding"
    pass "DHCP hook stops forwarding on ${drop_reason}"
done

printf 'untouched\n' > "$HOOK_CASE/run/servers.conf"
interface="eth0"
reason="BOUND"
new_domain_name_servers="192.168.1.1"
: > "$HOOK_CASE/pkill.log"
status=0
output="$(run_hook 2>&1)" || status=$?
assert_eq "$status" "0" "other interface hook status"
assert_eq "$(cat "$HOOK_CASE/run/servers.conf")" "untouched" "other interface changed the servers file"
assert_eq "$(wc -c < "$HOOK_CASE/pkill.log" | tr -d ' ')" "0" "other interface reloaded dnsmasq"
pass "DHCP hook ignores other interfaces"

printf 'static\n' > "$HOOK_CASE/run/servers.conf"
interface="vpn_vpn"
reason="BOUND"
SE_DNS_SERVERS="192.168.1.1"
new_domain_name_servers="10.0.0.53"
: > "$HOOK_CASE/pkill.log"
status=0
output="$(run_hook 2>&1)" || status=$?
assert_eq "$status" "0" "static hook status"
assert_eq "$(cat "$HOOK_CASE/run/servers.conf")" "static" "static servers were replaced by the lease"
pass "DHCP hook keeps static home DNS servers"

SE_DNS_SERVERS=""
reason="BOUND"
new_domain_name_servers=""
status=0
output="$(run_hook 2>&1)" || status=$?
assert_eq "$status" "0" "empty lease DNS status"
assert_eq "$(cat "$HOOK_CASE/run/servers.conf")" "server=/lan/
server=/home.arpa/" "empty lease DNS kept forwarding"
pass "DHCP hook does not forward when the lease has no DNS servers"

reason="BOUND"
new_domain_name_servers="not-an-ip 192.168.1.9"
status=0
output="$(run_hook 2>&1)" || status=$?
assert_eq "$status" "0" "mixed lease DNS status"
assert_eq "$(cat "$HOOK_CASE/run/servers.conf")" "server=/lan/192.168.1.9
server=/home.arpa/192.168.1.9" "invalid lease DNS server was forwarded"
pass "DHCP hook ignores a non-address DNS server"

PKILL_STATUS=1
reason="BOUND"
new_domain_name_servers="192.168.1.1"
status=0
output="$(run_hook 2>&1)" || status=$?
assert_eq "$status" "0" "pkill failure status"
assert_eq "$output" "hook-returned" "pkill failure aborted dhcpcd"
PKILL_STATUS=0
pass "DHCP hook ignores a missing dnsmasq process"

SPLIT="${ROOT}/assets/dns-split"
SPLIT_CASE="$TMP/split"
mkdir -p "$SPLIT_CASE/bin"
cat > "$SPLIT_CASE/bin/sleep" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'sleep argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'sleep arg=%s\n' "$arg"
    done
} >> "$log"
exit 0
EOF
cat > "$SPLIT_CASE/bin/dnsmasq" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'dnsmasq argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'dnsmasq arg=%s\n' "$arg"
    done
} >> "$log"
exit 0
EOF
chmod 755 "$SPLIT_CASE/bin/sleep" "$SPLIT_CASE/bin/dnsmasq"
: > "$SPLIT_CASE/log"
status=0
output="$(
    env PATH="$SPLIT_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$SPLIT_CASE/log" \
        SE_DNS_ENABLED="false" \
        sh "$SPLIT" 2>&1
)" || status=$?
assert_eq "$status" "0" "disabled dns-split status"
assert_eq "$output" "" "disabled dns-split output"
assert_contains "$SPLIT_CASE/log" "sleep arg=infinity" "disabled split DNS did not stay idle"
assert_not_contains "$SPLIT_CASE/log" "dnsmasq arg=--keep-in-foreground" "disabled split DNS started dnsmasq"
pass "dns-split stays idle when split DNS is disabled"

: > "$SPLIT_CASE/log"
status=0
output="$(
    env PATH="$SPLIT_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$SPLIT_CASE/log" \
        SE_DNS_ENABLED="true" \
        SE_DNSMASQ_BIN="$SPLIT_CASE/bin/dnsmasq" \
        SE_DNSMASQ_CONF="/etc/dnsmasq.d/softether.conf" \
        sh "$SPLIT" 2>&1
)" || status=$?
assert_eq "$status" "0" "enabled dns-split status"
assert_contains "$SPLIT_CASE/log" "dnsmasq arg=--keep-in-foreground" "dnsmasq was not kept in the foreground"
assert_contains "$SPLIT_CASE/log" "dnsmasq arg=--log-facility=-" "dnsmasq was not told to log to stderr"
assert_contains "$SPLIT_CASE/log" "dnsmasq arg=--conf-file=/etc/dnsmasq.d/softether.conf" "dnsmasq config path was wrong"
assert_not_contains "$SPLIT_CASE/log" "sleep arg=infinity" "enabled split DNS stayed idle"
pass "dns-split starts dnsmasq when split DNS is enabled"

GEN_MAC="${ROOT}/assets/gen-mac"

expect_mac() {
    entropy=$1
    expected=$2
    status=0
    output="$(SE_MAC_ENTROPY="$entropy" sh "$GEN_MAC" 2>&1)" || status=$?
    assert_eq "$status" "0" "gen-mac status for ${entropy}"
    assert_eq "$output" "$expected" "gen-mac output for ${entropy}"
}

expect_mac "00 11 22 33 44 55" "02:11:22:33:44:55"
expect_mac "01 aa bb cc dd ee" "02:aa:bb:cc:dd:ee"
expect_mac "04 00 00 00 00 01" "06:00:00:00:00:01"
expect_mac "a5 10 20 30 40 50" "a6:10:20:30:40:50"
expect_mac "0b ff ff ff ff ff" "0a:ff:ff:ff:ff:ff"
expect_mac "fe 01 02 03 04 05" "fe:01:02:03:04:05"
expect_mac "FF FF FF FF FF FF" "fe:ff:ff:ff:ff:ff"
pass "gen-mac forces a locally administered unicast address"

status=0
output="$(SE_MAC_ENTROPY="00 11 22 33 44" sh "$GEN_MAC" 2>&1)" || status=$?
assert_eq "$status" "1" "short gen-mac entropy status"
printf '%s\n' "$output" | grep -F -q "Could not read 6 random bytes" || fail "short gen-mac entropy message"
pass "gen-mac rejects a short entropy string"

i=0
while [ "$i" -lt 20 ]; do
    i=$((i + 1))
    output="$(sh "$GEN_MAC")"
    case "$output" in
        [0-9a-f][26ae]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
        *)
            fail "gen-mac printed an incompatible address: ${output}"
            ;;
    esac
done
pass "gen-mac prints a compatible random address"

READY="${ROOT}/assets/vpn-ready"
READY_CASE="$TMP/ready"
mkdir -p "$READY_CASE/bin" "$READY_CASE/run"
cat > "$READY_CASE/bin/vpncmd" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'vpncmd argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'vpncmd arg=%s\n' "$arg"
    done
} >> "$log"
if [ "${VPNCMD_STATUS:-0}" != "0" ]; then
    printf 'vpncmd unavailable\n' >&2
    exit 1
fi
if [ "${VPNCMD_ESTABLISHED:-yes}" = "yes" ]; then
    printf '%s\n' 'Session Status|Connection Completed (Session Established)'
else
    printf '%s\n' 'Session Status|Connecting'
fi
exit 0
EOF
cat > "$READY_CASE/bin/ip" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'ip argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'ip arg=%s\n' "$arg"
    done
} >> "$log"
if [ "${IP_STATUS:-0}" != "0" ]; then
    exit 1
fi
printf '%s\n' "${IP_OUTPUT-2: vpn_vpn inet 192.168.2.130/24 scope global}"
exit 0
EOF
cat > "$READY_CASE/bin/pgrep" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'pgrep argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'pgrep arg=%s\n' "$arg"
    done
} >> "$log"
if [ "${PGREP_STATUS:-0}" != "0" ]; then
    exit 1
fi
exit 0
EOF
cat > "$READY_CASE/bin/nc" <<'EOF'
#!/bin/sh
log="${MOCK_LOG:?}"
{
    printf 'nc argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'nc arg=%s\n' "$arg"
    done
} >> "$log"
exit "${NC_STATUS:-0}"
EOF
chmod 755 "$READY_CASE/bin/vpncmd" "$READY_CASE/bin/ip" "$READY_CASE/bin/pgrep" "$READY_CASE/bin/nc"

ready_reset() {
    : > "$READY_CASE/log"
    rm -f "$READY_CASE/run/servers.conf"
    SE_ACCOUNT_NAME="default"
    SE_NICNAME="vpn"
    SE_DNS_DOMAINS=""
    SE_DNS_RUN_DIR="$READY_CASE/run"
    SE_HEALTH_CHECK_TARGET=""
    SE_HEALTH_CHECK_TIMEOUT=""
    VPNCMD_STATUS=0
    VPNCMD_ESTABLISHED="yes"
    IP_STATUS=0
    IP_OUTPUT="2: vpn_vpn inet 192.168.2.130/24 scope global"
    PGREP_STATUS=0
    NC_STATUS=0
}

run_ready() {
    env \
        PATH="$READY_CASE/bin:/usr/bin:/bin" \
        MOCK_LOG="$READY_CASE/log" \
        SE_ACCOUNT_NAME="$SE_ACCOUNT_NAME" \
        SE_NICNAME="$SE_NICNAME" \
        SE_DNS_DOMAINS="$SE_DNS_DOMAINS" \
        SE_DNS_RUN_DIR="$SE_DNS_RUN_DIR" \
        SE_HEALTH_CHECK_TARGET="$SE_HEALTH_CHECK_TARGET" \
        SE_HEALTH_CHECK_TIMEOUT="$SE_HEALTH_CHECK_TIMEOUT" \
        VPNCMD_STATUS="$VPNCMD_STATUS" \
        VPNCMD_ESTABLISHED="$VPNCMD_ESTABLISHED" \
        IP_STATUS="$IP_STATUS" \
        IP_OUTPUT="$IP_OUTPUT" \
        PGREP_STATUS="$PGREP_STATUS" \
        NC_STATUS="$NC_STATUS" \
        sh "$READY"
}

ready_reset
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "0" "ready without split DNS status"
assert_eq "$output" "" "ready without split DNS output"
assert_not_contains "$READY_CASE/log" "pgrep arg=dnsmasq" "split DNS check ran while disabled"
assert_not_contains "$READY_CASE/log" "nc arg=-z" "probe ran without a target"
pass "vpn-ready passes when the session and address are up"

ready_reset
VPNCMD_ESTABLISHED="no"
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "1" "session down status"
printf '%s\n' "$output" | grep -F -q "VPN session is not established" || fail "session down message"
assert_not_contains "$READY_CASE/log" "ip arg=addr" "address check ran before the session was up"
pass "vpn-ready fails when the session is not established"

ready_reset
VPNCMD_STATUS=1
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "1" "vpncmd failure status"
printf '%s\n' "$output" | grep -F -q "VPN session status is unavailable" || fail "vpncmd failure message"
pass "vpn-ready fails when vpncmd cannot report status"

ready_reset
IP_OUTPUT="2: vpn_vpn"
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "1" "missing address status"
printf '%s\n' "$output" | grep -F -q "VPN adapter vpn_vpn has no IPv4 address" || fail "missing address message"
assert_not_contains "$READY_CASE/log" "pgrep arg=dnsmasq" "split DNS check ran without an address"
pass "vpn-ready fails when the adapter has no IPv4 address"

ready_reset
IP_STATUS=1
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "1" "missing adapter status"
printf '%s\n' "$output" | grep -F -q "VPN adapter vpn_vpn has no IPv4 address" || fail "missing adapter message"
pass "vpn-ready fails when the adapter is missing"

ready_reset
SE_NICNAME="Office"
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "0" "uppercase NIC status"
assert_contains "$READY_CASE/log" "ip arg=vpn_office" "uppercase NIC was not normalized"
pass "vpn-ready lowercases SE_NICNAME"

ready_reset
SE_DNS_DOMAINS="lan"
PGREP_STATUS=1
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "1" "dnsmasq missing status"
printf '%s\n' "$output" | grep -F -q "Split DNS is not running" || fail "dnsmasq missing message"
pass "vpn-ready fails when dnsmasq is not running"

ready_reset
SE_DNS_DOMAINS="lan"
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "1" "missing servers file status"
printf '%s\n' "$output" | grep -F -q "Split DNS forwarders are not configured" || fail "missing servers file message"
pass "vpn-ready fails when the servers file is missing"

ready_reset
SE_DNS_DOMAINS="lan"
printf 'server=/lan/\n' > "$READY_CASE/run/servers.conf"
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "1" "placeholder servers status"
printf '%s\n' "$output" | grep -F -q "Split DNS forwarders are not configured" || fail "placeholder servers message"
pass "vpn-ready fails while a domain has no forwarder"

ready_reset
SE_DNS_DOMAINS="lan,home.arpa"
printf 'server=/lan/192.168.2.1\nserver=/home.arpa/192.168.2.1\n' > "$READY_CASE/run/servers.conf"
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "0" "split DNS ready status"
assert_eq "$output" "" "split DNS ready output"
assert_contains "$READY_CASE/log" "pgrep arg=dnsmasq" "split DNS check did not look for dnsmasq"
assert_not_contains "$READY_CASE/log" "nc arg=-z" "probe ran without a target"
pass "vpn-ready passes when split DNS has forwarders"

ready_reset
SE_HEALTH_CHECK_TARGET="192.168.30.139:8081"
NC_STATUS=1
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "1" "probe refused status"
printf '%s\n' "$output" | grep -F -q "Health check target 192.168.30.139:8081 is not reachable" || fail "probe refused message"
assert_contains "$READY_CASE/log" "nc arg=-z" "probe did not scan"
assert_contains "$READY_CASE/log" "nc arg=-w" "probe did not set a timeout"
assert_contains "$READY_CASE/log" "nc arg=3" "probe did not use the default timeout"
assert_contains "$READY_CASE/log" "nc arg=192.168.30.139" "probe host was wrong"
assert_contains "$READY_CASE/log" "nc arg=8081" "probe port was wrong"
pass "vpn-ready fails when the health target refuses the connection"

ready_reset
SE_DNS_DOMAINS="lan"
printf 'server=/lan/192.168.2.1\n' > "$READY_CASE/run/servers.conf"
SE_HEALTH_CHECK_TARGET="ps5-shalltear.lan:8081"
SE_HEALTH_CHECK_TIMEOUT="7"
status=0
output="$(run_ready 2>&1)" || status=$?
assert_eq "$status" "0" "probe success status"
assert_contains "$READY_CASE/log" "nc arg=7" "probe did not use SE_HEALTH_CHECK_TIMEOUT"
assert_contains "$READY_CASE/log" "nc arg=ps5-shalltear.lan" "probe hostname was wrong"
pass "vpn-ready probes the configured host and port"

printf '%s tests passed\n' "$PASS"
