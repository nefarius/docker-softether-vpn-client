#!/bin/sh
set -eu

CLIENT_DIR="${SE_CLIENT_DIR:-/usr/vpnclient}"
NET_DEV="${SE_NET_DEV:-/proc/net/dev}"
READY_ATTEMPTS="${SE_READY_ATTEMPTS:-30}"
READY_INTERVAL="${SE_READY_INTERVAL:-1}"
DNS_MARKER="# softether-split-dns"

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
        *:*:*)
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

require_domain() {
    name="$1"
    value="$2"

    case "$value" in
        ""|-*|*-|.*|*.|*..*|*[!A-Za-z0-9.-]*)
            fail "${name} contains unsupported characters"
            ;;
    esac

    rest=$value
    while [ -n "$rest" ]; do
        case "$rest" in
            *.*)
                label=${rest%%.*}
                rest=${rest#*.}
                ;;
            *)
                label=$rest
                rest=
                ;;
        esac
        case "$label" in
            ""|-*|*-|*[!A-Za-z0-9-]*)
                fail "${name} contains unsupported characters"
                ;;
        esac
        label_len=$(printf '%s' "$label" | awk '{ print length($0) }')
        if [ "$label_len" -gt 63 ]; then
            fail "${name} contains a label longer than 63 characters"
        fi
    done

    value_len=$(printf '%s' "$value" | awk '{ print length($0) }')
    if [ "$value_len" -gt 253 ]; then
        fail "${name} contains a domain longer than 253 characters"
    fi
}

require_domain_list() {
    name="$1"
    list="$2"
    rest=$list
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*)
                item=${rest%%,*}
                rest=${rest#*,}
                ;;
            *)
                item=$rest
                rest=
                ;;
        esac
        require_domain "$name" "$item"
    done
}

require_ipv4() {
    message="$1"
    value="$2"
    ok=$(printf '%s\n' "$value" | awk -F. '
        function reject() { print "no"; exit }
        NF != 4 { reject() }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/) reject()
                if (length($i) > 1 && substr($i, 1, 1) == "0") reject()
                if (($i + 0) > 255) reject()
            }
            print "yes"
        }
    ')
    if [ "$ok" != "yes" ]; then
        fail "$message"
    fi
}

require_ipv4_list() {
    name="$1"
    list="$2"
    rest=$list
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*)
                item=${rest%%,*}
                rest=${rest#*,}
                ;;
            *)
                item=$rest
                rest=
                ;;
        esac
        if [ "$item" = "0.0.0.0" ] || [ "$item" = "127.0.0.1" ]; then
            fail "${name} contains an invalid IPv4 address"
        fi
        require_ipv4 "${name} contains an invalid IPv4 address" "$item"
    done
}

require_hostname() {
    value="$1"
    host_len=$(printf '%s' "$value" | awk '{ print length($0) }')
    if [ "$host_len" -lt 1 ] || [ "$host_len" -gt 63 ]; then
        fail "SE_DHCP_HOSTNAME must be a single label of 1 to 63 characters"
    fi
    case "$value" in
        *[!A-Za-z0-9-]*|-*|*-)
            fail "SE_DHCP_HOSTNAME contains unsupported characters"
            ;;
    esac
}

require_mac() {
    raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '-' ':')
    case "$raw" in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])
            ;;
        *)
            fail "SE_MAC_ADDRESS contains unsupported characters"
            ;;
    esac
    if [ "$raw" = "00:00:00:00:00:00" ]; then
        fail "SE_MAC_ADDRESS must not be the all-zero address"
    fi
    first=${raw%%:*}
    low=$(printf '%s' "$first" | awk '{ print substr($0, 2, 1) }')
    case "$low" in
        1|3|5|7|9|b|d|f)
            fail "SE_MAC_ADDRESS must be a unicast address"
            ;;
    esac
    SE_MAC_LINUX=$raw
    SE_MAC_SOFTETHER=$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' | tr ':' '-')
    export SE_MAC_LINUX SE_MAC_SOFTETHER
}

check_upstream_ns() {
    ns=$1
    if [ "$ns" = "127.0.0.1" ]; then
        fail "Refusing to use 127.0.0.1 as an upstream DNS server"
    fi
    case "$ns" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            require_ipv4 "Upstream nameserver ${ns} is invalid" "$ns"
            ;;
        *:*)
            case "$ns" in
                *[!0-9A-Fa-f:]*)
                    fail "Upstream nameserver ${ns} is unsupported"
                    ;;
            esac
            ;;
        *)
            fail "Upstream nameserver ${ns} is unsupported"
            ;;
    esac
}

read_resolv_line() {
    IFS= read -r resolv_line || [ -n "$resolv_line" ]
}

save_upstream_from_resolv() {
    tmp="${DNS_STATE_FILE}.tmp"
    : > "$tmp"
    found_ns=0
    while read_resolv_line; do
        case "$resolv_line" in
            nameserver\ *)
                ns=${resolv_line#nameserver }
                ns=${ns%%[[:space:]]*}
                case "$ns" in
                    ""|\#*)
                        continue
                        ;;
                esac
                check_upstream_ns "$ns"
                printf 'nameserver %s\n' "$ns" >> "$tmp"
                found_ns=1
                ;;
            options\ *|search\ *)
                printf '%s\n' "$resolv_line" >> "$tmp"
                ;;
        esac
    done < "$RESOLV_CONF"
    if [ "$found_ns" -eq 0 ]; then
        rm -f "$tmp"
        fail "No upstream nameserver found in ${RESOLV_CONF}"
    fi
    mv "$tmp" "$DNS_STATE_FILE"
}

assert_upstream_usable() {
    found_ns=0
    while read_resolv_line; do
        case "$resolv_line" in
            nameserver\ *)
                ns=${resolv_line#nameserver }
                ns=${ns%%[[:space:]]*}
                check_upstream_ns "$ns"
                found_ns=1
                ;;
        esac
    done < "$DNS_STATE_FILE"
    if [ "$found_ns" -eq 0 ]; then
        fail "No upstream nameserver found in ${DNS_STATE_FILE}"
    fi
}

capture_upstream() {
    if grep -F -x -q "$DNS_MARKER" "$RESOLV_CONF"; then
        if [ ! -s "$DNS_STATE_FILE" ]; then
            fail "Split DNS upstream servers were not saved; recreate the container"
        fi
    else
        save_upstream_from_resolv
    fi
    assert_upstream_usable
}

write_dnsmasq_conf() {
    tmp="${DNSMASQ_CONF}.tmp"
    {
        printf '%s\n' "no-resolv"
        printf '%s\n' "listen-address=127.0.0.1"
        printf '%s\n' "bind-interfaces"
        printf '%s\n' "port=53"
        printf '%s\n' "no-hosts"
        printf '%s\n' "clear-on-reload"
        while read_resolv_line; do
            case "$resolv_line" in
                nameserver\ *)
                    ns=${resolv_line#nameserver }
                    printf 'server=%s\n' "${ns%%[[:space:]]*}"
                    ;;
            esac
        done < "$DNS_STATE_FILE"
        printf 'servers-file=%s\n' "$DNS_SERVERS_FILE"
    } > "$tmp"
    mv "$tmp" "$DNSMASQ_CONF"
}

write_split_servers() {
    servers=$1
    tmp="${DNS_SERVERS_FILE}.tmp"
    : > "$tmp"
    rest=$SE_DNS_DOMAINS
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*)
                domain=${rest%%,*}
                rest=${rest#*,}
                ;;
            *)
                domain=$rest
                rest=
                ;;
        esac
        if [ -z "$servers" ]; then
            printf 'server=/%s/\n' "$domain" >> "$tmp"
        else
            rest_servers=$servers
            while [ -n "$rest_servers" ]; do
                case "$rest_servers" in
                    *,*)
                        server_ip=${rest_servers%%,*}
                        rest_servers=${rest_servers#*,}
                        ;;
                    *)
                        server_ip=$rest_servers
                        rest_servers=
                        ;;
                esac
                printf 'server=/%s/%s\n' "$domain" "$server_ip" >> "$tmp"
            done
        fi
    done
    mv "$tmp" "$DNS_SERVERS_FILE"
}

write_resolv_from_state() {
    include_marker=$1
    tmp="${DNS_STATE_DIR}/resolv.tmp"
    {
        if [ "$include_marker" = "yes" ]; then
            printf '%s\n' "$DNS_MARKER"
            printf '%s\n' "nameserver 127.0.0.1"
        else
            while read_resolv_line; do
                case "$resolv_line" in
                    nameserver\ *)
                        printf '%s\n' "$resolv_line"
                        ;;
                esac
            done < "$DNS_STATE_FILE"
        fi
        if [ "$include_marker" = "yes" ] && [ -n "${SE_DNS_SEARCH:-}" ]; then
            search_value=$(printf '%s' "$SE_DNS_SEARCH" | tr ',' ' ')
            printf 'search %s\n' "$search_value"
        else
            while read_resolv_line; do
                case "$resolv_line" in
                    search\ *)
                        printf '%s\n' "$resolv_line"
                        ;;
                esac
            done < "$DNS_STATE_FILE"
        fi
        while read_resolv_line; do
            case "$resolv_line" in
                options\ *)
                    printf '%s\n' "$resolv_line"
                    ;;
            esac
        done < "$DNS_STATE_FILE"
    } > "$tmp"
    # /etc/resolv.conf is a bind mount. Overwrite it in place.
    cat "$tmp" > "$RESOLV_CONF"
    rm -f "$tmp"
}

configure_split_dns() {
    RESOLV_CONF="${SE_RESOLV_CONF:-/etc/resolv.conf}"
    DNSMASQ_CONF="${SE_DNSMASQ_CONF:-/etc/dnsmasq.d/softether.conf}"
    DNS_RUN_DIR="${SE_DNS_RUN_DIR:-/run/softether-dns}"
    DNS_STATE_DIR="${SE_DNS_STATE_DIR:-/var/lib/softether-dns}"
    DNS_STATE_FILE="${DNS_STATE_DIR}/upstream.conf"
    DNS_SERVERS_FILE="${DNS_RUN_DIR}/servers.conf"

    if [ -z "${SE_DNS_DOMAINS:-}" ]; then
        if [ -n "${SE_DNS_SERVERS:-}" ] || [ -n "${SE_DNS_SEARCH:-}" ]; then
            fail "SE_DNS_DOMAINS is required when SE_DNS_SERVERS or SE_DNS_SEARCH is set"
        fi
        if [ -f "$RESOLV_CONF" ] && grep -F -x -q "$DNS_MARKER" "$RESOLV_CONF"; then
            if [ ! -s "$DNS_STATE_FILE" ]; then
                fail "Split DNS upstream servers were not saved; recreate the container"
            fi
            write_resolv_from_state no
            log "Split DNS disabled; restored upstream resolvers"
        fi
        SE_DNS_ENABLED=false
        export SE_DNS_ENABLED
        return
    fi

    require_domain_list "SE_DNS_DOMAINS" "$SE_DNS_DOMAINS"
    if [ -n "${SE_DNS_SERVERS:-}" ]; then
        require_ipv4_list "SE_DNS_SERVERS" "$SE_DNS_SERVERS"
    fi
    if [ -n "${SE_DNS_SEARCH:-}" ]; then
        require_domain_list "SE_DNS_SEARCH" "$SE_DNS_SEARCH"
    fi

    if [ ! -f "$RESOLV_CONF" ]; then
        fail "Resolver file ${RESOLV_CONF} is not available"
    fi

    mkdir -p "$(dirname "$DNSMASQ_CONF")" "$DNS_RUN_DIR" "$DNS_STATE_DIR"
    capture_upstream
    write_dnsmasq_conf
    write_split_servers "${SE_DNS_SERVERS:-}"
    write_resolv_from_state yes
    SE_DNS_ENABLED=true
    export SE_DNS_ENABLED
    log "Split DNS enabled for ${SE_DNS_DOMAINS}"
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

    if [ -n "${SE_MAC_ADDRESS:-}" ]; then
        require_mac "$SE_MAC_ADDRESS"
    fi
    if [ -n "${SE_DHCP_HOSTNAME:-}" ]; then
        require_hostname "$SE_DHCP_HOSTNAME"
    fi
    configure_split_dns

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

    if [ -n "${SE_MAC_ADDRESS:-}" ]; then
        vpncmd localhost /CLIENT /CMD NicSetSetting "$SE_NICNAME" "/MAC:${SE_MAC_SOFTETHER}"
        log "VPN adapter MAC address set to ${SE_MAC_SOFTETHER}"
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
