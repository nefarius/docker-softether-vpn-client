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
command -v dhcpcd >/dev/null
command -v supervisord >/dev/null
command -v awk >/dev/null
test ! -e /etc/dhclient-enter-hooks
if command -v dhclient >/dev/null 2>&1; then
    echo "dhclient must not be installed" >&2
    exit 1
fi
dhcpcd --nobackground --debug --nohook resolv.conf --version > /tmp/dhcpcd-probe 2>&1 || true
grep -F -q "unrecognized option: version" /tmp/dhcpcd-probe
if grep -F -q "unrecognized option: nobackground" /tmp/dhcpcd-probe \
    || grep -F -q "unrecognized option: debug" /tmp/dhcpcd-probe \
    || grep -F -q "unrecognized option: nohook" /tmp/dhcpcd-probe
then
    echo "dhcpcd rejected a required option" >&2
    cat /tmp/dhcpcd-probe >&2
    exit 1
fi
python3 - <<'"'"'PY'"'"'
import configparser
parser = configparser.ConfigParser(interpolation=None)
read = parser.read("/etc/supervisord.conf")
if not read:
    raise SystemExit("supervisord.conf was not readable")
for section in ("supervisord", "program:vpnclient", "program:dhcpcd"):
    if section not in parser:
        raise SystemExit("missing " + section)
if parser["program:dhcpcd"]["command"] != "/usr/local/bin/dhcpcd-vpn":
    raise SystemExit("dhcpcd program command changed")
PY
'

status=0
output="$(docker run --rm --entrypoint /entrypoint.sh "$IMAGE" supervisord 2>&1)" || status=$?
if [ "$status" -eq 0 ]; then
    fail "image entrypoint accepted supervisord without VPN settings"
fi
printf '%s\n' "$output" | grep -F -q "Please provide SE_SERVER" || fail "image entrypoint did not report SE_SERVER"

printf 'image smoke passed for %s\n' "$IMAGE"
