#!/bin/sh
set -eu

CLIENT_DIR="${SE_CLIENT_DIR:-/usr/vpnclient}"
NET_DEV="${SE_NET_DEV:-/proc/net/dev}"
READY_ATTEMPTS="${SE_READY_ATTEMPTS:-30}"
READY_INTERVAL="${SE_READY_INTERVAL:-1}"

log() {
    printf '%s\n' "$1" >&2
}

fail() {
    log "$1"
    exit 1
}

require_value() {
    name="$1"
    value="$2"

    if [ -z "$value" ]; then
        fail "Please provide ${name} environment variable"
    fi

    case "$value" in
        *[[:cntrl:]]*)
            fail "${name} contains unsupported characters"
            ;;
    esac
}

require_server() {
    require_value SE_SERVER "$1"

    case "$1" in
        *[!A-Za-z0-9._:-]*)
            fail "SE_SERVER contains unsupported characters"
            ;;
    esac
}

require_nic() {
    require_value SE_NICNAME "$1"

    case "$1" in
        *[!A-Za-z0-9_-]*)
            fail "SE_NICNAME contains unsupported characters"
            ;;
    esac

    nic_len="$(printf '%s' "$1" | awk '{ print length($0) }')"
    if [ "$nic_len" -gt 11 ]; then
        fail "SE_NICNAME must be 11 characters or fewer so vpn_${1} fits in a Linux interface name"
    fi
}

stop_client() {
    vpnclient stop >/dev/null 2>&1 || true
}

if [ "${1:-}" = "supervisord" ]; then
    require_server "${SE_SERVER:-}"
    require_value SE_HUB "${SE_HUB:-}"
    require_value SE_USERNAME "${SE_USERNAME:-}"
    require_value SE_PASSWORD "${SE_PASSWORD:-}"
    require_value SE_ACCOUNT_NAME "${SE_ACCOUNT_NAME:-}"

    SE_NICNAME="$(printf '%s' "${SE_NICNAME:-}" | tr '[:upper:]' '[:lower:]')"
    export SE_NICNAME
    require_nic "$SE_NICNAME"

    case "${SE_TYPE:-}" in
        standard | radius) ;;
        *)
            fail "SE_TYPE must be standard or radius"
            ;;
    esac

    if [ ! -f "$NET_DEV" ]; then
        fail "Network device table ${NET_DEV} is not available"
    fi

    rm -f "${CLIENT_DIR}/vpn_client.config"

    vpnclient start
    trap stop_client EXIT

    attempt=0
    until vpncmd localhost /CLIENT /CMD NicList >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$READY_ATTEMPTS" ]; then
            fail "Timed out waiting for the SoftEther VPN client service"
        fi
        sleep "$READY_INTERVAL"
    done

    iface="vpn_${SE_NICNAME}"
    if grep -F -q "${iface}:" "$NET_DEV"; then
        log "NIC ${SE_NICNAME} already exists, skipping creation"
    else
        vpncmd localhost /CLIENT /CMD NicCreate "$SE_NICNAME"
    fi

    vpncmd localhost /CLIENT /CMD AccountCreate "$SE_ACCOUNT_NAME" \
        "/SERVER:${SE_SERVER}" \
        "/HUB:${SE_HUB}" \
        "/USERNAME:${SE_USERNAME}" \
        "/NICNAME:${SE_NICNAME}"

    if ! vpncmd localhost /CLIENT /CMD AccountPasswordSet "$SE_ACCOUNT_NAME" \
        "/PASSWORD:${SE_PASSWORD}" \
        "/TYPE:${SE_TYPE}" >/dev/null 2>&1; then
        fail "Failed to set the VPN account password"
    fi

    vpncmd localhost /CLIENT /CMD AccountStartupSet "$SE_ACCOUNT_NAME"

    stop_client
    trap - EXIT
fi

if [ "$#" -eq 0 ]; then
    fail "No command specified"
fi

exec "$@"
