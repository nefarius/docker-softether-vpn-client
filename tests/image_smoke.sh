#!/bin/sh
set -eu

IMAGE="${1:-${IMAGE:-docker-softether-vpn-client:local}}"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

docker image inspect "$IMAGE" >/dev/null

docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
set -eu
test -x /entrypoint.sh
test -x /usr/bin/vpnclient
test -x /usr/vpnclient/vpnclient
test -s /usr/vpnclient/hamcore.se2
test -x /usr/bin/vpncmd
test -x /usr/vpncmd/vpncmd
test -s /usr/vpncmd/hamcore.se2
test -f /etc/supervisord.conf
test -x /usr/local/bin/dhcpcd-vpn
test -x /usr/local/bin/dns-split
test -x /usr/local/bin/gen-mac
test -x /usr/local/bin/vpn-ready
command -v nc >/dev/null
command -v pgrep >/dev/null
nc -z -w 1 127.0.0.1 1 >/tmp/nc-probe 2>&1 || true
if grep -F -q "unrecognized option" /tmp/nc-probe || grep -F -q "invalid option" /tmp/nc-probe; then
    echo "nc rejected -z or -w" >&2
    cat /tmp/nc-probe >&2
    exit 1
fi
test -f /etc/dhcpcd.exit-hook
test -f /etc/dhcpcd-vpn.conf
test -f /etc/dhcpcd-vpn-duid.conf
grep -F -x -q "clientid" /etc/dhcpcd-vpn.conf
grep -F -x -q "duid" /etc/dhcpcd-vpn-duid.conf
command -v dhcpcd >/dev/null
command -v dnsmasq >/dev/null
command -v ip >/dev/null
command -v pkill >/dev/null
command -v supervisord >/dev/null
command -v awk >/dev/null
test ! -e /etc/dhclient-enter-hooks
if command -v dhclient >/dev/null 2>&1; then
    echo "dhclient must not be installed" >&2
    exit 1
fi
dhcpcd --nobackground --debug --nohook resolv.conf --broadcast --noipv4ll -f /etc/dhcpcd-vpn.conf --version > /tmp/dhcpcd-probe 2>&1 || true
grep -F -q "unrecognized option: version" /tmp/dhcpcd-probe
if grep -F -q "unrecognized option: nobackground" /tmp/dhcpcd-probe \
    || grep -F -q "unrecognized option: debug" /tmp/dhcpcd-probe \
    || grep -F -q "unrecognized option: nohook" /tmp/dhcpcd-probe \
    || grep -F -q "unrecognized option: broadcast" /tmp/dhcpcd-probe \
    || grep -F -q "unrecognized option: noipv4ll" /tmp/dhcpcd-probe \
    || grep -F -q "unrecognized option: f" /tmp/dhcpcd-probe
then
    echo "dhcpcd rejected a required option" >&2
    cat /tmp/dhcpcd-probe >&2
    exit 1
fi
dhcpcd --hostname=smoke --version > /tmp/dhcpcd-hostname 2>&1 || true
if grep -F -q "unrecognized option: hostname" /tmp/dhcpcd-hostname; then
    echo "dhcpcd rejected --hostname" >&2
    cat /tmp/dhcpcd-hostname >&2
    exit 1
fi
mkdir -p /tmp/dns
printf "%s\n" "server=/lan/" > /tmp/dns/servers.conf
cat > /tmp/dns/dnsmasq.conf <<EOF
no-resolv
listen-address=127.0.0.1
bind-interfaces
port=53
no-hosts
clear-on-reload
server=127.0.0.11
servers-file=/tmp/dns/servers.conf
EOF
if ! dnsmasq --conf-file=/tmp/dns/dnsmasq.conf --test >/tmp/dnsmasq-test 2>&1; then
    echo "dnsmasq rejected the split DNS configuration" >&2
    cat /tmp/dnsmasq-test >&2
    exit 1
fi
dnsmasq --keep-in-foreground --conf-file=/tmp/dns/dnsmasq.conf --port=5353 >/tmp/dnsmasq-run 2>&1 &
dns_pid=$!
seen=0
i=0
while [ "$i" -lt 25 ]; do
    if pgrep -x /usr/sbin/dnsmasq >/dev/null 2>&1 || pgrep -x dnsmasq >/dev/null 2>&1; then
        seen=1
        break
    fi
    i=$((i + 1))
    sleep 0.1
done
kill "$dns_pid" 2>/dev/null || true
wait "$dns_pid" 2>/dev/null || true
if [ "$seen" -ne 1 ]; then
    echo "pgrep did not see a running dnsmasq" >&2
    cat /tmp/dnsmasq-run >&2
    exit 1
fi
python3 - <<'"'"'PY'"'"'
import configparser
parser = configparser.ConfigParser(interpolation=None)
read = parser.read("/etc/supervisord.conf")
if not read:
    raise SystemExit("supervisord.conf was not readable")
for section in ("supervisord", "program:vpnclient", "program:dhcpcd", "program:dnsmasq"):
    if section not in parser:
        raise SystemExit("missing " + section)
if parser["program:dhcpcd"]["command"] != "/usr/local/bin/dhcpcd-vpn":
    raise SystemExit("dhcpcd program command changed")
if parser["program:dnsmasq"]["command"] != "/usr/local/bin/dns-split":
    raise SystemExit("dnsmasq program command changed")
if parser["program:dnsmasq"]["autostart"] != "true":
    raise SystemExit("dnsmasq autostart changed")
PY
'

status=0
output="$(docker run --rm --entrypoint /entrypoint.sh "$IMAGE" supervisord 2>&1)" || status=$?
if [ "$status" -eq 0 ]; then
    fail "image entrypoint accepted supervisord without VPN settings"
fi
printf '%s\n' "$output" | grep -F -q "Please provide SE_SERVER" || fail "image entrypoint did not report SE_SERVER"

health_test="$(docker image inspect --format '{{json .Config.Healthcheck.Test}}' "$IMAGE")"
printf '%s\n' "$health_test" | grep -F -q "/usr/local/bin/vpn-ready" || fail "image health check is not vpn-ready: ${health_test}"

mac_a="$(docker run --rm "$IMAGE" gen-mac)"
mac_b="$(docker run --rm "$IMAGE" gen-mac)"
case "$mac_a" in
    [0-9a-f][26ae]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
    *)
        fail "gen-mac printed an incompatible address: ${mac_a}"
        ;;
esac
case "$mac_b" in
    [0-9a-f][26ae]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
    *)
        fail "gen-mac printed an incompatible address: ${mac_b}"
        ;;
esac
if [ "$mac_a" = "$mac_b" ]; then
    fail "gen-mac returned the same address twice"
fi

printf 'image smoke passed for %s\n' "$IMAGE"
