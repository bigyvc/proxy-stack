#!/usr/bin/env bash
# relay_cli.sh — psm relay: the relays, without questions (the PSM panel's 中转).
#
# A relay listens on this server and forwards to another host: the entry
# machine takes the client's connection and hands it on, and the node on the
# landing machine does not change. Two engines do the forwarding:
#
#   realm   a port forward (TCP, and UDP with --udp), to one target or spread
#           over several by round robin or client IP; optionally a TLS hop
#           between two realm rules (--tls)
#   gost    the same forward with what realm lacks: failover between targets
#           with health checks (--strategy fifo), a rate limit (--speed), and
#           the encrypted tunnel — an entry rule on one machine
#           (--mode tunnel-entry) carrying the traffic in gost's relay
#           protocol over TLS / mTLS / WSS / mWSS to an exit rule on another
#           (--mode tunnel-exit), which alone forwards to the landing side
#
# Both engines' rules live in one store (config/realm/rules.json, the realm
# menu's own), from which realm's config.toml and gost's config.json are
# generated. A monthly traffic quota (--limit-gb, --reset-day) and an expiry
# date (--expires) work on either: the rule's port is metered on PSM_TRF and
# refused (TCP reset, UDP unreachable) while it is over quota or expired.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# 2: engines, modes, several targets, limits, automatic ports
_RELAY_CLI_VERSION=2
_RELAY_PORT_RANGE="20000-60000"
_RELAY_MAX_TARGETS=16

_relay_err() { printf 'psm relay: %s\n' "$*" >&2; }

_relay_usage() {
    cat <<'EOF'
Usage:
  psm relay list [--json]
  psm relay show TAG [--json]
  psm relay add --tag TAG --listen-port PORT|auto --target HOST:PORT [--target HOST:PORT ...]
                [--engine realm|gost] [--strategy round|rand|fifo|hash] [--no-probe]
                [--udp] [--speed MBPS] [--limit-gb N] [--reset-day 0-28]
                [--expires DATE|never] [--port-range MIN-MAX] [--no-firewall] [--json]
  psm relay add --tag TAG --mode tunnel-exit --listen-port PORT|auto --target HOST:PORT ...
                [--transport tls|mtls|wss|mwss] [--tls-sni NAME] [--ws-path PATH]
                [--secret SECRET] [--strategy ...] [--json]
  psm relay add --tag TAG --mode tunnel-entry --listen-port PORT|auto --exit HOST:PORT
                --secret SECRET (--exit-pin SHA256 | --exit-cert FILE | --tls-insecure)
                [--transport ...] [--tls-sni NAME] [--ws-host HOST] [--ws-path PATH]
                [--udp] [--speed MBPS] [--limit-gb N] [--expires DATE] [--json]
  psm relay add --batch FILE|- [the options above, for every line] [--json]
  psm relay update TAG [any option of add; --target replaces the list] [--json]
  psm relay delete TAG --yes [--if-exists] [--json]
  psm relay probe [TAG] [--samples N] [--json]
  psm relay install [--engine realm|gost] [--json]

realm is the default engine of a forward. gost is needed for --strategy rand
or fifo (failover: the first target that answers), for --speed and for the
tunnel modes; with several targets gost checks each over TCP every 15 s and
leaves out one that does not answer (--no-probe when a target speaks only UDP).

A tunnel is two rules with the same tag and secret: the exit, on the machine
that forwards to the landing side, and the entry, which clients connect to.
The exit makes a self-signed certificate (or takes --tls-cert/--tls-key) and
prints the command for the entry, which pins that certificate:

  exit    psm relay add --tag hk --mode tunnel-exit --listen-port 8443 \
              --target 127.0.0.1:443
  entry   psm relay add --tag hk --mode tunnel-entry --listen-port 443 \
              --exit EXIT_IP:8443 --secret SECRET --exit-pin SHA256 --udp

UDP travels inside the tunnel. A tunnel carries protocols in which the client
speaks first, as every proxy protocol does; one in which the server speaks
first (SSH, SMTP, FTP, VNC) waits for ever, and needs a forward instead.

A realm forward's hop can instead be wrapped in realm's TLS (--tls, TCP only):
the rule forwarding to this machine terminates it, one forwarding elsewhere
dials it (--tls-sni, --tls-insecure).

--batch reads one relay per line, "TAG PORT|auto HOST:PORT[,HOST:PORT...]",
the other options applying to every line. --limit-gb meters the listening
port and refuses it once the month's traffic passes the quota (reset on
--reset-day, 0 for never); --expires refuses it from that time on
(YYYY-MM-DD means the end of that day here; an ISO time with Z is UTC).
EOF
}

_relay_load_realm() {
    declare -f _realm_load >/dev/null && return 0
    # shellcheck source=/dev/null
    source "$LIB_DIR/realm.sh"
}
_relay_load_gost() {
    _relay_load_realm
    declare -f gost_apply >/dev/null && return 0
    # shellcheck source=/dev/null
    source "$LIB_DIR/gost.sh"
}

_relay_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
_relay_valid_tag()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
# a name or an address (IPv6 without brackets), as psm-agent and the panel check it
_relay_valid_host() {   # labels do not start or end with "-" (no "--help" either)
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ \
       || "$1" =~ ^[0-9a-fA-F:.]+$ ]] && (( ${#1} <= 253 ))
}

_relay_bool() {
    case "${1,,}" in
        true|1|yes|on)  printf 'true' ;;
        false|0|no|off) printf 'false' ;;
        *) return 1 ;;
    esac
}

_relay_j() { printf '%s' "$1" | jq -r "$2"; }   # <json> <jq filter>: one raw value

# HOST:PORT, [IPv6]:PORT → "host<TAB>port"
_relay_split_hp() {
    local s="$1" h p
    if [[ "$s" =~ ^\[([0-9a-fA-F:.]+)\]:([0-9]+)$ ]]; then
        h=${BASH_REMATCH[1]}; p=${BASH_REMATCH[2]}
    elif [[ "$s" =~ ^([^:]+):([0-9]+)$ ]]; then
        h=${BASH_REMATCH[1]}; p=${BASH_REMATCH[2]}
    else
        return 1
    fi
    _relay_valid_host "$h" && _relay_valid_port "$p" || return 1
    printf '%s\t%s' "$h" "$p"
}

# An expiry as the rule keeps it: an ISO time in UTC, or "" for none.
_relay_expiry() {   # <text>
    local v="$1" e
    case "${v,,}" in ""|never|none|0|null) return 0 ;; esac
    if [[ "$v" =~ ^[0-9]{9,11}$ ]]; then
        e=$v
    elif [[ "$v" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2})(:[0-9]{2})?(\.[0-9]+)?Z$ ]]; then
        e=$(date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}${BASH_REMATCH[3]:-:00}" +%s 2>/dev/null)
    elif [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        e=$(date -d "$v 23:59:59" +%s 2>/dev/null)
    elif [[ "$v" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[\ T]([0-9]{2}:[0-9]{2})(:[0-9]{2})?$ ]]; then
        e=$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}${BASH_REMATCH[3]:-:00}" +%s 2>/dev/null)
    fi
    [[ "$e" =~ ^[0-9]+$ ]] || return 1
    date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
}
_relay_expiry_epoch() {   # <ISO UTC from _relay_expiry> → seconds
    [[ "$1" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})Z$ ]] || return 1
    date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" +%s 2>/dev/null
}

# A self-signed pair for the terminating side, when none was given. The
# dialling side accepts it with --tls-insecure; a real certificate is better
# when the relay has a name of its own.
_relay_self_signed() {   # <name> [file stem] → "<cert>\t<key>"
    local sni="$1" dir crt key
    dir="$CFG_DIR/realm/certs"
    crt="$dir/${2:-$sni}.crt"; key="$dir/${2:-$sni}.key"
    if [[ -s "$crt" && -s "$key" ]]; then
        printf '%s\t%s' "$crt" "$key"; return 0
    fi
    mkdir -p "$dir" || return 1
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days 3650 -subj "/CN=${sni}" -addext "subjectAltName=DNS:${sni}" \
        -keyout "$key" -out "$crt" >/dev/null 2>&1 || {
        _relay_err "could not make a self-signed certificate for $sni"; return 1; }
    chmod 600 "$key" 2>/dev/null || true
    printf '%s\t%s' "$crt" "$key"
}

_relay_cert_sha256() {   # <cert file> → lowercase hex
    local fp
    fp=$(openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null) || return 1
    fp=${fp#*=}; fp=${fp//:/}
    [[ "$fp" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s' "${fp,,}"
}

# What a rule reports beyond itself: an exit's certificate, for the entry to pin.
_relay_item() {   # <rule json>
    local rule="$1" mode crt pem sha
    mode=$(_relay_j "$rule" '.mode // "forward"')
    if [[ "$mode" == tunnel-exit ]]; then
        crt=$(_relay_j "$rule" '.tls_cert // ""')
        if [[ -s "$crt" ]] && pem=$(openssl x509 -in "$crt" 2>/dev/null) && sha=$(_relay_cert_sha256 "$crt"); then
            printf '%s' "$rule" | jq -c --arg p "$pem" --arg s "$sha" '. + {cert_pem: $p, cert_sha256: $s}'
            return
        fi
    fi
    printf '%s' "$rule" | jq -c '.'
}

_relay_result() {   # <status> <rule json> <as_json>
    local status="$1" rule="$2" as_json="$3" item
    item=$(_relay_item "$rule")
    if [[ "$as_json" == "1" ]]; then
        printf '%s' "$item" | jq -c --arg s "$status" --argjson v "$_RELAY_CLI_VERSION" \
            '{status:$s, api_version:$v, item:.}'
        return
    fi
    printf '%s: %s\n' "$status" "$(_relay_j "$item" '.tag')"
    # an exit prints the other half: the command for the entry machine
    if [[ "$status" != deleted && "$(_relay_j "$item" '.mode // ""')" == tunnel-exit ]]; then
        local ip; ip=$(get_ipv4 2>/dev/null || true); [[ -n "$ip" ]] || ip=EXIT_IP
        printf '%s' "$item" | jq -r --arg ip "$ip" '
            "  secret:             \(.secret)",
            "  certificate sha256: \(.cert_sha256 // "?")",
            "  on the entry machine:",
            "    psm relay add --tag \(.tag) --mode tunnel-entry --listen-port PORT --exit \($ip):\(.listen_port) \\",
            "        --transport \(.transport // "tls") --secret \(.secret) --exit-pin \(.cert_sha256 // "?")"
            + (if (.tls_sni // "") != "" then " --tls-sni \(.tls_sni)" else "" end)
            + (if (.ws_path // "") != "" then " --ws-path \(.ws_path)" else "" end)
            + " --udp"'
    fi
}

# ── did the rule really take? ────────────────────────────────────────────────
# realm keeps running when a single endpoint cannot bind: it logs
# "[tcp]failed to bind 0.0.0.0:PORT: Address in use (os error 98)" and goes on
# serving the others. So a restart that leaves the service active is no proof
# that this rule took, and a relay that can never accept a connection would be
# reported as applied. The listening sockets are read straight from /proc, so
# this needs neither ss nor netstat and behaves the same on Debian, Alpine and
# Red Hat.
#
# It answers "is anything listening there", not "is our engine listening
# there": the process squatting the port would otherwise make the check pass.
# That is why the port is also checked for a squatter before the rule is
# applied.
_relay_port_bound() {   # <port> <tcp|udp|both>
    local port="$1" want="$2" hex p ok=1
    hex=$(printf '%04X' "$port")
    for p in tcp udp; do
        [[ "$want" == both || "$want" == "$p" ]] || continue
        if [[ "$p" == tcp ]]; then
            # 0A is TCP_LISTEN; a connected socket on the same port is not a listener
            awk -v p=":${hex}\$" '$4 == "0A" && toupper($2) ~ p { f = 1 } END { exit !f }' \
                /proc/net/tcp /proc/net/tcp6 2>/dev/null || ok=0
        else
            awk -v p=":${hex}\$" 'toupper($2) ~ p { f = 1 } END { exit !f }' \
                /proc/net/udp /proc/net/udp6 2>/dev/null || ok=0
        fi
    done
    [[ "$ok" == 1 ]]
}

# TCP only for a tunnel's exit (UDP travels inside the tunnel), else as --udp says
_relay_proto() {   # <rule json> → tcp|both
    [[ "$(_relay_j "$1" '(.mode // "forward") != "tunnel-exit" and (.udp // false)')" == true ]] && echo both || echo tcp
}

# A free port for --listen-port auto: the hint when it is free (the panel
# picks one it knows nothing else uses), else a random one in the range that no
# relay has and nothing on this machine listens on.
_relay_pick_port() {   # <hint or ""> <MIN-MAX> <tcp|both> <tag of the rule, to allow its own port>
    local hint="$1" range="$2" proto="$3" tag="$4" min max p i rules
    [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || { _relay_err "--port-range must be MIN-MAX"; return 2; }
    min=${BASH_REMATCH[1]}; max=${BASH_REMATCH[2]}
    _relay_valid_port "$min" && _relay_valid_port "$max" && (( min <= max )) \
        || { _relay_err "--port-range must be MIN-MAX within 1-65535"; return 2; }
    rules=$(_realm_load)
    _relay_port_free() {
        local q="$1"
        if printf '%s' "$rules" | jq -e --argjson p "$q" --arg t "$tag" 'any(.[]; .listen_port == $p and .tag != $t)' >/dev/null; then
            return 1
        fi
        # its own port is held by its own engine
        printf '%s' "$rules" | jq -e --argjson p "$q" --arg t "$tag" 'any(.[]; .listen_port == $p and .tag == $t)' >/dev/null && return 0
        ! _relay_port_bound "$q" tcp && { [[ "$proto" != both ]] || ! _relay_port_bound "$q" udp; }
    }
    if [[ -n "$hint" ]] && _relay_valid_port "$hint" && _relay_port_free "$hint"; then
        printf '%s' "$hint"; return 0
    fi
    for ((i = 0; i < 200; i++)); do
        p=$(rand_port "$min" "$max")
        _relay_port_free "$p" && { printf '%s' "$p"; return 0; }
    done
    _relay_err "no free port in $range"; return 1
}

# ── the firewall, the way nodes do it ────────────────────────────────────────
# A port this opened is written down in $CFG_DIR/firewall-ports, and only a
# port written down there is ever closed again: a port the user opened for
# something else of their own must survive a relay being deleted.
_RELAY_FW_LEDGER="$CFG_DIR/firewall-ports"

_relay_fw_open() {   # <port> <tcp|udp|both>
    local port="$1" want="$2" p
    declare -f firewall_backend &>/dev/null || source "$LIB_DIR/system.sh"
    [[ -n "$(firewall_backend)" ]] || return 0   # nothing enforces: nothing to open
    for p in tcp udp; do
        [[ "$want" == both || "$want" == "$p" ]] || continue
        grep -qx "$port/$p" "$_RELAY_FW_LEDGER" 2>/dev/null && continue
        firewall_port_allowed "$port" "$p" && continue
        if firewall_open_port "$port" "$p" >&2; then
            mkdir -p "$CFG_DIR" && printf '%s/%s\n' "$port" "$p" >> "$_RELAY_FW_LEDGER"
        else
            _relay_err "warning: could not open $p/$port in the firewall; the relay is not reachable until it is open"
        fi
    done
    return 0
}

_relay_fw_close() {   # <port>: only what this opened, and only if no rule still uses it
    local port="$1" p others
    [[ -s "$_RELAY_FW_LEDGER" ]] || return 0
    grep -q "^$port/" "$_RELAY_FW_LEDGER" || return 0
    others=$(_realm_load | jq --argjson p "$port" '[.[] | select(.listen_port == $p)] | length' 2>/dev/null)
    [[ "$others" == 0 ]] || return 0
    declare -f firewall_close_port &>/dev/null || source "$LIB_DIR/system.sh"
    for p in tcp udp; do
        grep -qx "$port/$p" "$_RELAY_FW_LEDGER" || continue
        firewall_close_port "$port" "$p" >/dev/null 2>&1 || true
        sed -i "\|^$port/$p\$|d" "$_RELAY_FW_LEDGER"
    done
    return 0
}

# ── how the hop is doing ─────────────────────────────────────────────────────
# Round trip, jitter and loss are measured with plain TCP connects to the
# landing side, not with ping: ICMP is filtered often enough on these networks
# that ping would report loss that is not there, and a relay carries TCP
# anyway, so a connect is what the traffic actually experiences.
#
# Jitter here is the mean absolute difference between consecutive round trips
# over the burst — the same quantity RFC 3550 keeps a running estimate of.
_RELAY_PROBE_SAMPLES=5
_RELAY_PROBE_TIMEOUT=3

# One TCP connect, in milliseconds; nothing at all when it did not connect.
#
# bash opens the connection itself (/dev/tcp) and the shell exits as soon as it
# is up, so the measurement costs about as long as the handshake. curl is not
# used for this: with telnet:// it connects at once but then sits there until
# --max-time expires, which cost three seconds per sample — half a minute for
# every measurement of a couple of relays, and it pushed the readings apart.
#
# `timeout` bounds a port that silently drops packets, which would otherwise
# hang for minutes. Spawning that subshell costs a few milliseconds, so this
# cannot resolve below roughly 5 ms: plenty for a hop between two machines,
# and the floor to keep in mind for one to 127.0.0.1.
_relay_connect_ms() {   # <host> <port>
    local host="$1" port="$2" s e
    local LC_ALL=C
    s="$EPOCHREALTIME"
    timeout "$_RELAY_PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null || return 1
    e="$EPOCHREALTIME"
    awk -v s="$s" -v e="$e" 'BEGIN { printf "%.2f\n", (e - s) * 1000 }'
}

# ── metering, on the same chain the nodes use ────────────────────────────────
# A relay is metered by its listening port through PSM_TRF, exactly as a
# standalone node is. The tag is prefixed so it can never collide with a node's
# own tag in that chain.
_relay_meter_tag() { printf 'relay-%s' "$1"; }

_relay_meter_load() {
    declare -f _trf_ipt_ensure_rules &>/dev/null && return 0
    source "$LIB_DIR/traffic.sh" 2>/dev/null || return 1
}

_relay_meter_ensure() {   # <tag> <listen port>
    _relay_meter_load || return 0
    _trf_ipt_ensure_rules "$(_relay_meter_tag "$1")" "$2" >/dev/null 2>&1 || true
}

_relay_meter_remove() {   # <tag> <listen port>
    _relay_meter_load || return 0
    _trf_ipt_remove_rules "$(_relay_meter_tag "$1")" "$2" >/dev/null 2>&1 || true
}

# Bytes counted for this relay since the rules were put in place (cumulative:
# the panel turns consecutive readings into the traffic of an interval).
_relay_meter_bytes() {   # <tag>
    _relay_meter_load || { echo 0; return 0; }
    _trf_ipt_query_bytes "$(_relay_meter_tag "$1")" 2>/dev/null || echo 0
}

# ── quota and expiry ─────────────────────────────────────────────────────────
# A relay with a quota or an expiry is enrolled in the traffic state the nodes
# use (config/traffic/state.json) as relay-<TAG>, metered from its port on
# PSM_TRF. The periodic check (psm-traffic, every minute) adds up its traffic,
# pauses it over quota — the port answers with a TCP reset and ICMP
# unreachable, exactly as a node over its limit — and lifts that on the reset
# day; relay_limits_check pauses the ones whose time is up.
_relay_limits_enrolled() { [[ -f "$TRAFFIC_STATE" ]] && jq -e --arg t "$1" '.[$t] != null' "$TRAFFIC_STATE" >/dev/null 2>&1; }

_relay_limits_apply() {   # <rule json> [old rule json]
    local rule="$1" old="${2:-}" tag ttag port limit day exp old_port over=0 expired=0 used paused
    _relay_meter_load || return 0
    _trf_lock
    tag=$(_relay_j "$rule" '.tag'); ttag=$(_relay_meter_tag "$tag")
    port=$(_relay_j "$rule" '.listen_port')
    limit=$(_relay_j "$rule" '.limit_bytes // 0 | floor')
    day=$(_relay_j "$rule" '.reset_day // 1')
    exp=$(_relay_j "$rule" '.expires_at // ""')
    old_port=$([[ -n "$old" ]] && _relay_j "$old" '.listen_port' || echo "$port")

    if _relay_limits_enrolled "$ttag"; then
        # a pause is a rule on the old port: lift it before the entry moves or goes
        if [[ "$(_trf_get "$ttag" paused)" == true ]] && { [[ "$old_port" != "$port" ]] || { (( limit == 0 )) && [[ -z "$exp" ]]; }; }; then
            _trf_resume_tag "$ttag" >&2
        fi
        if (( limit == 0 )) && [[ -z "$exp" ]]; then
            _trf_cleanup_node "$ttag" >&2
            _relay_meter_ensure "$tag" "$port"   # that took the meter's counting rules too
            return 0
        fi
    fi
    (( limit > 0 )) || [[ -n "$exp" ]] || return 0

    _trf_init
    _trf_init_tag "$ttag" "$port"
    _trf_set_field "$ttag" limit_bytes "$limit"
    _trf_set_field "$ttag" reset_day "$day"
    _trf_set_str   "$ttag" source iptables
    _trf_set_field "$ttag" count_port "$port"
    _trf_set_str   "$ttag" count_iface ""
    _trf_set_field "$ttag" meter true
    [[ -n "$(_trf_get "$ttag" last_reset)" ]] || _trf_set_str "$ttag" last_reset "$(date +%Y-%m)"
    _trf_ipt_ensure_rules "$ttag" "$port" >/dev/null 2>&1 || true
    _trf_timer_active || _trf_install_timer >&2

    used=$(_trf_to_int "$(_trf_get "$ttag" accumulated_bytes)")
    (( limit > 0 && used >= limit )) && over=1
    if [[ -n "$exp" ]]; then
        local e; e=$(_relay_expiry_epoch "$exp") && (( e <= $(date +%s) )) && expired=1
    fi
    paused=$(_trf_get "$ttag" paused)
    if (( over || expired )); then
        [[ "$paused" == true ]] || _trf_pause_tag "$ttag" >&2
    elif [[ "$paused" == true ]]; then
        _trf_resume_tag "$ttag" >&2
    fi
    return 0
}

_relay_limits_remove() {   # <tag>
    _relay_meter_load || return 0
    _trf_lock
    local ttag; ttag=$(_relay_meter_tag "$1")
    _relay_limits_enrolled "$ttag" && _trf_cleanup_node "$ttag" >&2
    return 0
}

# Called by the periodic traffic check (lib/traffic.sh): pause what has expired.
relay_limits_check() {
    _relay_load_realm
    _relay_meter_load || return 0
    local now rule tag ttag exp e
    now=$(date +%s)
    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        tag=$(_relay_j "$rule" '.tag'); exp=$(_relay_j "$rule" '.expires_at // ""')
        e=$(_relay_expiry_epoch "$exp") || continue
        (( e <= now )) || continue
        ttag=$(_relay_meter_tag "$tag")
        _relay_limits_enrolled "$ttag" || continue
        [[ "$(_trf_get "$ttag" paused)" == true ]] || _trf_pause_tag "$ttag"
    done < <(_realm_load | jq -c '.[] | select((.expires_at // "") != "")')
}

# A relay's quota and pause, as probe and show report them.
_relay_limits_state() {   # <rule json> → {used_bytes, limit_bytes, paused, pause_reason}
    local rule="$1" tag ttag exp e reason="" used=null paused=false
    tag=$(_relay_j "$rule" '.tag'); ttag=$(_relay_meter_tag "$tag")
    if _relay_meter_load && _relay_limits_enrolled "$ttag"; then
        used=$(_trf_to_int "$(_trf_get "$ttag" accumulated_bytes)")
        [[ "$(_trf_get "$ttag" paused)" == true ]] && paused=true
    fi
    if [[ "$paused" == true ]]; then
        reason=quota
        exp=$(_relay_j "$rule" '.expires_at // ""')
        e=$(_relay_expiry_epoch "$exp") && (( e <= $(date +%s) )) && reason=expired
    fi
    jq -nc --argjson u "$used" --argjson l "$(_relay_j "$rule" '.limit_bytes // 0 | floor')" \
        --argjson p "$paused" --arg r "$reason" --arg x "$(_relay_j "$rule" '.expires_at // ""')" \
        '{used_bytes: $u, limit_bytes: $l, paused: $p, pause_reason: $r, expires_at: $x}'
}

# ── probe ────────────────────────────────────────────────────────────────────
_relay_probe_host() {   # <host> <port> <samples> → {rtt_ms, rtt_min_ms, rtt_max_ms, jitter_ms, loss_pct, samples}
    local host="$1" port="$2" n="$3" i ms
    local -a rtts=()
    local sent=0 lost=0
    for ((i = 0; i < n; i++)); do
        sent=$((sent + 1))
        if ms=$(_relay_connect_ms "$host" "$port"); then
            rtts+=("$ms")
        else
            lost=$((lost + 1))
        fi
    done
    local rtt_avg=null rtt_min=null rtt_max=null jitter=null
    if (( ${#rtts[@]} > 0 )); then
        rtt_avg=$(printf '%s\n' "${rtts[@]}" | awk '{ s += $1 } END { printf "%.2f", s / NR }')
        rtt_min=$(printf '%s\n' "${rtts[@]}" | awk 'NR == 1 || $1 < m { m = $1 } END { printf "%.2f", m }')
        rtt_max=$(printf '%s\n' "${rtts[@]}" | awk '$1 > m { m = $1 } END { printf "%.2f", m }')
        if (( ${#rtts[@]} > 1 )); then
            jitter=$(printf '%s\n' "${rtts[@]}" | awk '
                NR > 1 { d = $1 - p; if (d < 0) d = -d; s += d; c++ }
                { p = $1 }
                END { printf "%.2f", (c ? s / c : 0) }')
        else
            jitter=0
        fi
    fi
    local loss; loss=$(awk -v l="$lost" -v s="$sent" 'BEGIN { printf "%.1f", s ? l * 100 / s : 0 }')
    jq -nc --argjson rtt "$rtt_avg" --argjson min "$rtt_min" --argjson max "$rtt_max" \
        --argjson jitter "$jitter" --argjson loss "$loss" --argjson sent "$sent" \
        '{rtt_ms: $rtt, rtt_min_ms: $min, rtt_max_ms: $max, jitter_ms: $jitter, loss_pct: $loss, samples: $sent}'
}

# One rule's measurement, as a JSON object: the hop to its first target (for a
# tunnel's entry, the exit), and with several targets a short reading of each,
# taken side by side so a dead one costs one timeout, not one per target.
_relay_probe_one() {   # <rule json> <samples>
    local rule="$1" n="$2" tag host port main extra="[]" dir i t
    tag=$(_relay_j "$rule" '.tag')
    host=$(_relay_j "$rule" '.remote_host')
    port=$(_relay_j "$rule" '.remote_port')
    main=$(_relay_probe_host "$host" "$port" "$n")
    if [[ "$(_relay_j "$rule" '(.targets // []) | length')" -gt 1 ]]; then
        dir=$(mktemp -d)
        i=0
        while IFS=$'\t' read -r h p; do
            ( _relay_probe_host "$h" "$p" 2 | jq -c --arg h "$h" --argjson p "$p" '{host: $h, port: $p, rtt_ms, loss_pct}' > "$dir/$i" ) &
            i=$((i + 1))
        done < <(_relay_j "$rule" '.targets[] | "\(.host)\t\(.port)"')
        wait
        extra=$(for ((t = 0; t < i; t++)); do cat "$dir/$t"; done | jq -sc '.')
        rm -rf "$dir"
    fi
    jq -nc --arg tag "$tag" --arg host "$host" --argjson port "$port" --argjson m "$main" \
        --argjson targets "$extra" --argjson bytes "$(_relay_meter_bytes "$tag")" \
        --argjson lim "$(_relay_limits_state "$rule")" \
        --arg engine "$(_relay_j "$rule" '.engine // "realm"')" --arg mode "$(_relay_j "$rule" '.mode // "forward"')" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        { tag: $tag, engine: $engine, mode: $mode, remote_host: $host, remote_port: $port } + $m
        + { bytes: $bytes, at: $at } + $lim
        + (if ($targets | length) > 0 then {targets: $targets} else {} end)'
}

_relay_cmd_probe() {
    local as_json=0 one="" n="$_RELAY_PROBE_SAMPLES"
    while (( $# )); do
        case "$1" in
            --json) as_json=1; shift ;;
            --samples)
                [[ $# -ge 2 ]] || { _relay_err '--samples requires a number'; return 2; }
                n="$2"
                [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 20 )) || { _relay_err '--samples must be 1-20'; return 2; }
                shift 2 ;;
            -*) _relay_err "unknown option: $1"; return 2 ;;
            *) one="$1"; shift ;;
        esac
    done
    _relay_load_realm
    local rules; rules=$(_realm_load)
    [[ -n "$one" ]] && rules=$(printf '%s' "$rules" | jq -c --arg t "$one" '[.[] | select(.tag == $t)]')
    if [[ -n "$one" ]] && [[ "$(printf '%s' "$rules" | jq 'length')" == 0 ]]; then
        _relay_err "no such relay: $one"; return 1
    fi

    local items="[]" rule item
    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        item=$(_relay_probe_one "$rule" "$n") || continue
        items=$(jq -c --argjson i "$item" '. + [$i]' <<<"$items")
    done < <(printf '%s' "$rules" | jq -c '.[]')

    if (( as_json )); then
        jq -nc --argjson v "$_RELAY_CLI_VERSION" --argjson items "$items" \
            '{api_version: $v, count: ($items | length), items: $items}'
    else
        printf '%s' "$items" | jq -r '.[] |
            "\(.tag)\t\(.remote_host):\(.remote_port)\t\(if .rtt_ms == null then "unreachable" else "\(.rtt_ms) ms" end)\tjitter \(.jitter_ms // 0) ms\tloss \(.loss_pct)%\t\(.bytes) bytes"
            + (if .paused then "\tpaused (\(.pause_reason))" else "" end),
            (.targets // [] | .[] | "  \(.host):\(.port)\t\(if .rtt_ms == null then "unreachable" else "\(.rtt_ms) ms" end)")'
    fi
}

# ── list / show ──────────────────────────────────────────────────────────────
_relay_cmd_list() {
    local as_json=0
    while (( $# )); do
        case "$1" in
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    _relay_load_realm
    local rules; rules=$(_realm_load)
    if (( as_json )); then
        printf '%s' "$rules" | jq -c --argjson v "$_RELAY_CLI_VERSION" \
            '{api_version:$v, count:length, items:.}'
        return 0
    fi
    printf '%-20s %-6s %-13s %-7s %-30s %-8s %s\n' TAG ENGINE MODE LISTEN TARGET PROTO NOTE
    printf '%s' "$rules" | jq -r '.[] |
        [.tag, (.engine // "realm"), (.mode // "forward"), (.listen_port|tostring),
         (.remote_host + ":" + (.remote_port|tostring)
          + (if ((.targets // []) | length) > 1 then " +\((.targets | length) - 1)" else "" end)),
         (if (.mode // "") == "tunnel-exit" then "tcp" elif .udp then "tcp+udp" else "tcp" end),
         ([ (if (.tls // false) then (if (.tls_cert // "") != "" then "tls terminate" else "tls dial" end) else empty end),
            (if (.mode // "forward") != "forward" then (.transport // "tls") else empty end),
            (if ((.targets // []) | length) > 1 then (.strategy // "round" | if . == "" then "round" else . end) else empty end),
            (if (.speed_mbps // 0) > 0 then "\(.speed_mbps) Mbps" else empty end),
            (if (.limit_bytes // 0) > 0 then "quota \(.limit_bytes / 1073741824 * 100 | floor / 100) GB" else empty end),
            (if (.expires_at // "") != "" then "until \(.expires_at)" else empty end) ] | join(", ") | if . == "" then "-" else . end)]
        | @tsv' 2>/dev/null | while IFS=$'\t' read -r t e m l r p n; do
        printf '%-20s %-6s %-13s %-7s %-30s %-8s %s\n' "$t" "$e" "$m" "$l" "$r" "$p" "$n"
    done
}

_relay_cmd_show() {
    local tag="${1:-}"; shift || true
    local as_json=0
    while (( $# )); do
        case "$1" in
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ -n "$tag" && "$tag" != --* ]] || { _relay_err 'show requires TAG'; return 2; }
    _relay_load_realm
    local rule; rule=$(_realm_get_by_tag "$tag")
    [[ -n "$rule" && "$rule" != "null" ]] || { _relay_err "no such relay: $tag"; return 1; }
    local item; item=$(_relay_item "$rule" | jq -c --argjson s "$(_relay_limits_state "$rule")" '. + $s')
    if (( as_json )); then
        printf '%s' "$item" | jq -c --argjson v "$_RELAY_CLI_VERSION" '{api_version:$v, item:.}'
    else
        printf '%s' "$item" | jq -r 'to_entries[] | select(.key != "cert_pem") | "\(.key): \(.value)"'
    fi
}

# ── the TLS half of a realm rule ─────────────────────────────────────────────
# Which side this rule is depends on where it forwards: to this machine
# (127.0.0.1 / ::1 / localhost) it terminates TLS, anywhere else it dials.
_relay_is_local_addr() {   # <host>: an address of this machine (so the hop ends here)
    local h="$1"
    case "$h" in 127.0.0.1|::1|localhost) return 0 ;; esac
    # A landing rule often names the machine's own public address rather than
    # the loopback; treating that as the dialling side would ask for an SNI and
    # write the wrong half of the pair.
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$h"
}

# realm's transport options are one `;`-separated string, and an option it
# cannot parse makes it panic rather than refuse the config (measured on 2.9.4:
# "tls;nosuchopt=1" panics in kaminari's opt.rs). So nothing with `;` or `=` may
# reach it from a name or a path.
_relay_tls_safe() {   # <what> <value>
    local what="$1" v="$2"
    case "$v" in
        *[';=']*) _relay_err "$what may not contain ';' or '=': $v"; return 1 ;;
    esac
}

_relay_tls_fields() {   # <remote_host> <sni> <cert> <key> <insecure> → json
    local rh="$1" sni="$2" cert="$3" key="$4" insecure="$5" pair
    local terminates=0
    _relay_tls_safe '--tls-sni' "$sni" || return 1
    _relay_tls_safe '--tls-cert' "$cert" || return 1
    _relay_tls_safe '--tls-key' "$key" || return 1
    _relay_is_local_addr "$rh" && terminates=1
    if (( terminates )); then
        [[ -n "$sni" ]] || sni=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo relay.local)
        if [[ -z "$cert" || -z "$key" ]]; then
            pair=$(_relay_self_signed "$sni") || return 1
            cert=${pair%%$'\t'*}; key=${pair#*$'\t'}
        fi
        [[ -s "$cert" && -s "$key" ]] || { _relay_err "certificate files not found: $cert $key"; return 1; }
        jq -nc --arg s "$sni" --arg c "$cert" --arg k "$key" \
            '{tls:true, tls_sni:$s, tls_cert:$c, tls_key:$k, tls_insecure:false}'
    else
        [[ -n "$sni" ]] || { _relay_err '--tls-sni is required when the hop dials TLS'; return 1; }
        jq -nc --arg s "$sni" --argjson i "$insecure" \
            '{tls:true, tls_sni:$s, tls_cert:"", tls_key:"", tls_insecure:$i}'
    fi
}

# ── what the command line and the JSON input ask for ─────────────────────────
# A whole rule as JSON, the way `psm node add --input -` takes a node: the
# panel's agent hands one over on stdin rather than building a command line.
_relay_load_input() {   # <FILE|-|@FILE|JSON>
    local spec="$1" content
    case "$spec" in
        -) content=$(command cat) ;;
        @*) content=$(command cat "${spec#@}") || return 1 ;;
        *) if [[ -f "$spec" ]]; then content=$(command cat "$spec") || return 1; else content="$spec"; fi ;;
    esac
    printf '%s' "$content" | jq -e 'type == "object"' >/dev/null 2>&1 || {
        _relay_err 'input must be a JSON object'; return 1; }
    printf '%s' "$content" | jq -c '.'
}

# The options of add and update, as the JSON fields they set (only those), on
# top of --input/--data. Sets _RP_SPEC, _RP_JSON, _RP_FW, _RP_BATCH and _RP_POS
# (a bare word: update's TAG).
_relay_parse() {
    local spec='{}' input="" v hp
    local -a targets=()
    _RP_JSON=0; _RP_FW=1; _RP_BATCH=""; _RP_POS=""
    _rp_set()  { spec=$(printf '%s' "$spec" | jq -c --arg k "$1" --arg v "$2" '.[$k] = $v'); }
    _rp_setj() { spec=$(printf '%s' "$spec" | jq -c --arg k "$1" --argjson v "$2" '.[$k] = $v'); }
    _rp_need() { [[ $# -ge 2 && -n "$2" ]] || { _relay_err "$1 requires a value"; return 2; }; }
    # --udp / --tls / --tls-insecure: alone they mean true; a following true|false decides
    _rp_flag() {
        if [[ -n "${2:-}" ]] && v=$(_relay_bool "$2"); then _rp_setj "$1" "$v"; return 0; fi
        _rp_setj "$1" true; return 1
    }
    while (( $# )); do
        case "$1" in
            --input|--data) _rp_need "$@" || return 2; input="$2"; shift 2 ;;
            --json) _RP_JSON=1; shift ;;
            --no-firewall) _RP_FW=0; shift ;;
            --batch) _rp_need "$@" || return 2; _RP_BATCH="$2"; shift 2 ;;
            --tag) _rp_need "$@" || return 2; _rp_set tag "$2"; shift 2 ;;
            --engine) _rp_need "$@" || return 2; _rp_set engine "$2"; shift 2 ;;
            --mode)
                _rp_need "$@" || return 2
                case "$2" in entry) v=tunnel-entry ;; exit) v=tunnel-exit ;; direct) v=forward ;; *) v="$2" ;; esac
                _rp_set mode "$v"; shift 2 ;;
            --listen-port)
                _rp_need "$@" || return 2
                if [[ "$2" == auto ]]; then _rp_setj listen_port_auto true
                else _relay_valid_port "$2" || { _relay_err '--listen-port must be 1-65535 or auto'; return 2; }
                     _rp_setj listen_port "$2"; fi
                shift 2 ;;
            --port-range) _rp_need "$@" || return 2; _rp_set port_range "$2"; shift 2 ;;
            --target)
                _rp_need "$@" || return 2
                hp=$(_relay_split_hp "$2") || { _relay_err "--target must be HOST:PORT ([IPv6]:PORT): $2"; return 2; }
                targets+=("$hp"); shift 2 ;;
            --exit)
                _rp_need "$@" || return 2
                hp=$(_relay_split_hp "$2") || { _relay_err "--exit must be HOST:PORT ([IPv6]:PORT): $2"; return 2; }
                _rp_set remote_host "${hp%%$'\t'*}"; _rp_setj remote_port "${hp#*$'\t'}"; shift 2 ;;
            --remote-host) _rp_need "$@" || return 2; _rp_set remote_host "$2"; shift 2 ;;
            --remote-port)
                _rp_need "$@" || return 2
                _relay_valid_port "$2" || { _relay_err '--remote-port must be 1-65535'; return 2; }
                _rp_setj remote_port "$2"; shift 2 ;;
            --strategy) _rp_need "$@" || return 2; _rp_set strategy "$2"; shift 2 ;;
            --no-probe) _rp_setj probe false; shift ;;
            --probe)
                _rp_need "$@" || return 2
                case "$2" in tcp|on|true) _rp_setj probe true ;; off|false|none) _rp_setj probe false ;;
                    *) _relay_err '--probe must be tcp or off'; return 2 ;; esac
                shift 2 ;;
            --udp) if _rp_flag udp "${2:-}"; then shift 2; else shift; fi ;;
            --tls) if _rp_flag tls "${2:-}"; then shift 2; else shift; fi ;;
            --tls-insecure) if _rp_flag tls_insecure "${2:-}"; then shift 2; else shift; fi ;;
            --tls-sni) _rp_need "$@" || return 2; _rp_set tls_sni "$2"; shift 2 ;;
            --tls-cert) _rp_need "$@" || return 2; _rp_set tls_cert "$2"; shift 2 ;;
            --tls-key) _rp_need "$@" || return 2; _rp_set tls_key "$2"; shift 2 ;;
            --transport) _rp_need "$@" || return 2; _rp_set transport "$2"; shift 2 ;;
            --ws-host) _rp_need "$@" || return 2; _rp_set ws_host "$2"; shift 2 ;;
            --ws-path) _rp_need "$@" || return 2; _rp_set ws_path "$2"; shift 2 ;;
            --secret) _rp_need "$@" || return 2; _rp_set secret "$2"; shift 2 ;;
            --exit-cert)
                _rp_need "$@" || return 2
                v=$(openssl x509 -in "$2" 2>/dev/null) || { _relay_err "--exit-cert: not a certificate: $2"; return 2; }
                _rp_set exit_cert_pem "$v"; shift 2 ;;
            --exit-pin) _rp_need "$@" || return 2; _rp_set exit_pin "$2"; shift 2 ;;
            --speed)
                _rp_need "$@" || return 2
                [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { _relay_err '--speed: Mbit/s, a number (0 for none)'; return 2; }
                _rp_setj speed_mbps "$2"; shift 2 ;;
            --limit-gb)
                _rp_need "$@" || return 2
                [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { _relay_err '--limit-gb: a number (0 for none)'; return 2; }
                _rp_setj limit_bytes "$(awk -v g="$2" 'BEGIN { printf "%.0f", g * 1073741824 }')"; shift 2 ;;
            --limit-bytes)
                _rp_need "$@" || return 2
                [[ "$2" =~ ^[0-9]+$ ]] || { _relay_err '--limit-bytes: a whole number'; return 2; }
                _rp_setj limit_bytes "$2"; shift 2 ;;
            --reset-day)
                _rp_need "$@" || return 2
                [[ "$2" =~ ^[0-9]+$ ]] && (( $2 <= 28 )) || { _relay_err '--reset-day: 0-28 (0: never)'; return 2; }
                _rp_setj reset_day "$2"; shift 2 ;;
            --expires) _rp_need "$@" || return 2; _rp_set expires_at "$2"; shift 2 ;;
            -*) _relay_err "unknown option: $1"; return 2 ;;
            *) [[ -z "$_RP_POS" ]] || { _relay_err "unexpected argument: $1"; return 2; }; _RP_POS="$1"; shift ;;
        esac
    done
    if (( ${#targets[@]} )); then
        v=$(printf '%s\n' "${targets[@]}" | jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {host: .[0], port: (.[1] | tonumber)})')
        _rp_setj targets "$v"
    fi
    local from='{}'
    [[ -n "$input" ]] && { from=$(_relay_load_input "$input") || return 2; }
    # the options win over the JSON they were given with
    _RP_SPEC=$(jq -nc --argjson a "$from" --argjson b "$spec" '$a + $b')
}

# ── a rule, checked and completed ────────────────────────────────────────────
# From what was asked (and, for an update, the rule as it is) to the rule that
# goes into the store, or an error. Returns 2 for a request that cannot be
# right, 1 when something on this machine failed.
_relay_build() {   # <spec json> [old rule json]
    local spec="$1" old="${2:-}" r v
    r=$(jq -nc --argjson o "${old:-{\}}" --argjson s "$spec" '
        ($o + $s)
        # a changed first target moves the list with it, and the list sets it
        | if ($s | has("targets")) then .remote_host = .targets[0].host | .remote_port = .targets[0].port
          elif ($s | has("remote_host") or has("remote_port")) and ((.targets // []) | length) > 0 then
               .targets = ([{host: .remote_host, port: .remote_port}] + .targets[1:])
          else . end') || { _relay_err 'bad input'; return 2; }

    local tag mode engine
    tag=$(_relay_j "$r" '.tag // ""')
    _relay_valid_tag "$tag" || { _relay_err 'a tag is required: letters, digits, . _ - (max 64)'; return 2; }
    mode=$(_relay_j "$r" '.mode // "forward" | if . == "" then "forward" else . end')
    case "$mode" in forward|tunnel-entry|tunnel-exit) ;; *) _relay_err "--mode must be forward, tunnel-entry or tunnel-exit"; return 2 ;; esac
    engine=$(_relay_j "$r" '.engine // ""')
    [[ -n "$engine" ]] || { [[ "$mode" == forward ]] && engine=realm || engine=gost; }
    case "$engine" in realm|gost) ;; *) _relay_err "--engine must be realm or gost"; return 2 ;; esac
    [[ "$mode" == forward || "$engine" == gost ]] || { _relay_err "a tunnel is gost's (--engine gost)"; return 2; }
    r=$(printf '%s' "$r" | jq -c --arg m "$mode" --arg e "$engine" '.mode = $m | .engine = $e')

    # the targets: one list, the first also as remote_host/remote_port
    if [[ "$mode" == tunnel-entry ]]; then
        [[ "$(_relay_j "$spec" '(.targets // []) | length')" -le 1 ]] \
            || { _relay_err 'the entry of a tunnel has one exit (--exit HOST:PORT); the landing targets are the exit'"'"'s'; return 2; }
        r=$(printf '%s' "$r" | jq -c 'if (.remote_host // "") != "" and .remote_port != null
                                      then .targets = [{host: .remote_host, port: .remote_port}] else . end')
    fi
    r=$(printf '%s' "$r" | jq -c 'if ((.targets // []) | length) == 0 and (.remote_host // "") != "" and .remote_port != null
                                  then .targets = [{host: .remote_host, port: .remote_port}] else . end')
    local n; n=$(_relay_j "$r" '(.targets // []) | length')
    if (( n == 0 )); then
        [[ "$mode" == tunnel-entry ]] && { _relay_err 'the entry of a tunnel needs --exit HOST:PORT'; return 2; }
        _relay_err 'a target is required: --target HOST:PORT'; return 2
    fi
    (( n <= _RELAY_MAX_TARGETS )) || { _relay_err "at most $_RELAY_MAX_TARGETS targets"; return 2; }
    while IFS=$'\t' read -r h p; do
        _relay_valid_host "$h" || { _relay_err "not a host name or address: $h"; return 2; }
        _relay_valid_port "$p" || { _relay_err "not a port: $p"; return 2; }
    done < <(_relay_j "$r" '.targets[] | "\(.host)\t\(.port)"')
    r=$(printf '%s' "$r" | jq -c '.targets |= map({host: .host, port: (.port | tonumber)})
                                  | .remote_host = .targets[0].host | .remote_port = .targets[0].port')

    # how several targets share the work
    local strategy; strategy=$(_relay_j "$r" '.strategy // ""')
    case "$strategy" in
        ""|round|hash) ;;
        rand|fifo) [[ "$engine" == gost ]] || { _relay_err "realm spreads connections by round or hash only; --strategy $strategy (failover) needs --engine gost"; return 2; } ;;
        *) _relay_err "--strategy must be round, rand, fifo or hash"; return 2 ;;
    esac
    if [[ "$engine" == realm ]]; then
        r=$(printf '%s' "$r" | jq -c 'del(.probe)')
    fi

    # a rate limit is gost's
    v=$(_relay_j "$r" '.speed_mbps // 0 | tostring')
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { _relay_err '--speed: a number'; return 2; }
    if [[ "$(_relay_j "$r" '(.speed_mbps // 0 | tonumber) > 0')" == true && "$engine" != gost ]]; then
        _relay_err '--speed needs --engine gost (realm has no rate limit)'; return 2
    fi

    # quota and expiry, for either engine
    v=$(_relay_j "$r" '.limit_bytes // 0')
    [[ "$v" =~ ^[0-9]+$ ]] || { _relay_err 'the quota must be a whole number of bytes'; return 2; }
    v=$(_relay_j "$r" '.reset_day // 1')
    [[ "$v" =~ ^[0-9]+$ ]] && (( v <= 28 )) || { _relay_err '--reset-day: 0-28'; return 2; }
    v=$(_relay_j "$r" '.expires_at // ""')
    v=$(_relay_expiry "$v") || { _relay_err "--expires: YYYY-MM-DD, YYYY-MM-DD HH:MM, an ISO time in UTC (…Z) or never"; return 2; }
    r=$(printf '%s' "$r" | jq -c --arg x "$v" '.expires_at = $x | .limit_bytes = ((.limit_bytes // 0) | floor)
                                               | .reset_day = ((.reset_day // 1) | tonumber)
                                               | .speed_mbps = ((.speed_mbps // 0) | tonumber)')

    # the tunnel's transport and camouflage
    local transport sni wsh wsp
    sni=$(_relay_j "$r" '.tls_sni // ""'); wsh=$(_relay_j "$r" '.ws_host // ""'); wsp=$(_relay_j "$r" '.ws_path // ""')
    if [[ "$mode" != forward ]]; then
        transport=$(_relay_j "$r" '.transport // "tls" | if . == "" then "tls" else . end')
        case "$transport" in tls|mtls|wss|mwss) ;; *) _relay_err '--transport must be tls, mtls, wss or mwss'; return 2 ;; esac
        [[ -z "$sni" ]] || _relay_valid_host "$sni" || { _relay_err "--tls-sni: a host name: $sni"; return 2; }
        [[ -z "$wsh" ]] || _relay_valid_host "$wsh" || { _relay_err "--ws-host: a host name: $wsh"; return 2; }
        [[ -z "$wsp" || "$wsp" =~ ^/[A-Za-z0-9._~/%-]{0,127}$ ]] || { _relay_err "--ws-path: /, then letters, digits and . _ ~ / % -"; return 2; }
        [[ "$(_relay_j "$r" '.tls // false')" != true ]] || { _relay_err '--tls is realm'"'"'s TLS hop; a tunnel is encrypted by its --transport'; return 2; }
        r=$(printf '%s' "$r" | jq -c --arg t "$transport" '.transport = $t')
        v=$(_relay_j "$r" '.secret // ""')
        if [[ -z "$v" ]]; then
            [[ "$mode" == tunnel-exit ]] || { _relay_err 'the entry of a tunnel needs the exit'"'"'s --secret'; return 2; }
            v=$(openssl rand -hex 16) || { _relay_err 'could not make a secret'; return 1; }
            r=$(printf '%s' "$r" | jq -c --arg s "$v" '.secret = $s')
        fi
        [[ "$v" =~ ^[A-Za-z0-9_-]{8,64}$ ]] || { _relay_err '--secret: 8-64 letters, digits, _ and -'; return 2; }
    else
        r=$(printf '%s' "$r" | jq -c 'del(.transport, .secret, .ws_host, .ws_path, .exit_pin, .exit_ca)')
    fi

    # realm's own TLS hop, as before (a forward only)
    if [[ "$mode" == forward ]]; then
        if [[ "$(_relay_j "$r" '.tls // false')" == true ]]; then
            [[ "$engine" == realm ]] || { _relay_err '--tls is realm'"'"'s TLS hop; with gost use --mode tunnel-entry / tunnel-exit'; return 2; }
            local tlsj
            tlsj=$(_relay_tls_fields "$(_relay_j "$r" '.remote_host')" "$sni" "$(_relay_j "$r" '.tls_cert // ""')" \
                "$(_relay_j "$r" '.tls_key // ""')" "$(_relay_j "$r" '.tls_insecure // false')") || return 1
            r=$(jq -nc --argjson r "$r" --argjson t "$tlsj" '$r * $t')
        else
            r=$(printf '%s' "$r" | jq -c '.tls = false | .tls_sni = "" | .tls_cert = "" | .tls_key = "" | .tls_insecure = false')
        fi
    fi

    # the exit's certificate: given, or self-signed once and kept (the entry pins it)
    if [[ "$mode" == tunnel-exit ]]; then
        local cert key pair
        cert=$(_relay_j "$r" '.tls_cert // ""'); key=$(_relay_j "$r" '.tls_key // ""')
        if [[ -z "$cert" || -z "$key" ]]; then
            pair=$(_relay_self_signed "${sni:-www.bing.com}" "tunnel-$tag") || return 1
            cert=${pair%%$'\t'*}; key=${pair#*$'\t'}
        fi
        [[ -s "$cert" && -s "$key" ]] || { _relay_err "certificate files not found: $cert $key"; return 2; }
        r=$(printf '%s' "$r" | jq -c --arg c "$cert" --arg k "$key" '.tls_cert = $c | .tls_key = $k | .tls_insecure = false | del(.exit_pin, .exit_ca)')
    fi

    # the entry: how it knows the exit is the exit
    if [[ "$mode" == tunnel-entry ]]; then
        local pem pin dir file
        pem=$(_relay_j "$r" '.exit_cert_pem // ""'); pin=$(_relay_j "$r" '.exit_pin // "" | ascii_downcase | gsub(":"; "")')
        dir="$CFG_DIR/realm/pins"; file="$dir/$tag.crt"
        if [[ -n "$pem" ]]; then
            mkdir -p "$dir"
            printf '%s\n' "$pem" | openssl x509 -out "$file.new" 2>/dev/null \
                || { rm -f "$file.new"; _relay_err "the exit's certificate is not a PEM certificate"; return 2; }
            v=$(_relay_cert_sha256 "$file.new")
            [[ -z "$pin" || "$pin" == "$v" ]] || { rm -f "$file.new"; _relay_err "the exit's certificate does not match --exit-pin"; return 2; }
            mv -f "$file.new" "$file"; pin="$v"
        elif [[ -n "$pin" && ( "$pin" != "$(_relay_j "${old:-{\}}" '.exit_pin // ""')" || ! -s "$file" ) ]]; then
            [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || { _relay_err '--exit-pin: the SHA-256 of the exit'"'"'s certificate (64 hex digits)'; return 2; }
            # fetch it once over TLS and keep it if it is the one named
            mkdir -p "$dir"
            local hp; hp=$(_relay_j "$r" 'if (.remote_host | test(":")) then "[\(.remote_host)]:\(.remote_port)" else "\(.remote_host):\(.remote_port)" end')
            timeout 15 openssl s_client -connect "$hp" ${sni:+-servername "$sni"} </dev/null 2>/dev/null \
                | openssl x509 -out "$file.new" 2>/dev/null \
                || { rm -f "$file.new"; _relay_err "could not fetch the exit's certificate from $hp"; return 1; }
            v=$(_relay_cert_sha256 "$file.new")
            [[ "$v" == "$pin" ]] || { rm -f "$file.new"; _relay_err "the exit at $hp shows a certificate with SHA-256 $v, not $pin"; return 1; }
            mv -f "$file.new" "$file"
        fi
        if [[ -n "$pin" ]]; then
            r=$(printf '%s' "$r" | jq -c --arg f "$file" --arg p "$pin" '.exit_ca = $f | .exit_pin = $p | .tls_insecure = false')
        elif [[ "$(_relay_j "$r" '.tls_insecure // false')" == true ]]; then
            r=$(printf '%s' "$r" | jq -c '.exit_ca = "" | .exit_pin = ""')
        else
            # a certificate the entry can verify itself, for the name it dials
            [[ -n "$sni" ]] || { _relay_err "the entry cannot tell the exit is the exit: give --exit-pin (or --exit-cert), --tls-sni for a certificate it can verify, or --tls-insecure"; return 2; }
            r=$(printf '%s' "$r" | jq -c '.exit_ca = "" | .exit_pin = ""')
        fi
        r=$(printf '%s' "$r" | jq -c 'del(.tls_cert, .tls_key)')
    fi

    # what only the request needed
    printf '%s' "$r" | jq -c 'del(.exit_cert_pem, .listen_port_auto, .port_range, .cert_pem, .cert_sha256,
                                  .used_bytes, .paused, .pause_reason) | .udp = (.udp // false)'
}

# The listening port: as given, or picked (--listen-port auto).
_relay_resolve_port() {   # <spec> <rule> [old rule] → the rule with its port
    local spec="$1" r="$2" old="${3:-}" auto hint range proto tag p
    auto=$(_relay_j "$spec" '.listen_port_auto // false')
    tag=$(_relay_j "$r" '.tag')
    if [[ "$auto" == true ]]; then
        hint=$(_relay_j "$spec" '.listen_port // ""')
        [[ -n "$hint" || -z "$old" ]] || hint=$(_relay_j "$old" '.listen_port')
        range=$(_relay_j "$spec" '.port_range // ""'); [[ -n "$range" ]] || range="$_RELAY_PORT_RANGE"
        proto=$(_relay_proto "$r")
        p=$(_relay_pick_port "$hint" "$range" "$proto" "$tag") || return $?
        r=$(printf '%s' "$r" | jq -c --argjson p "$p" '.listen_port = $p')
    fi
    p=$(_relay_j "$r" '.listen_port // ""')
    _relay_valid_port "$p" || { _relay_err '--listen-port is required: 1-65535 or auto'; return 2; }
    printf '%s' "$r" | jq -c '.listen_port = (.listen_port | tonumber)'
}

# ── applying a rule ──────────────────────────────────────────────────────────
_relay_ensure_engine() {   # <realm|gost>
    case "$1" in
        realm) _relay_ensure_realm ;;
        gost)
            _relay_load_gost
            gost_install_unattended >&2 || { _relay_err 'could not install gost'; return 1; }
            [[ -x "$GOST_BIN" ]] || { _relay_err "gost is still missing: $GOST_BIN"; return 1; } ;;
    esac
}

_relay_engine_apply() {   # <realm|gost>
    case "$1" in
        realm) _relay_load_realm; _realm_apply >&2 ;;
        gost) _relay_load_gost; gost_apply ;;
    esac
}

# Write the rule, apply it, and put the store back if the engine refuses it.
_relay_apply_rule() {   # <rule json> <as_json> <status> <open_firewall> [old rule json]
    local rule="$1" as_json="$2" status="$3" open_fw="$4" old="${5:-}"
    local tag prev port proto engine old_engine e
    local -a engines=()
    tag=$(_relay_j "$rule" '.tag')
    engine=$(_relay_j "$rule" '.engine')
    port=$(_relay_j "$rule" '.listen_port')
    proto=$(_relay_proto "$rule")
    prev=$(_realm_load)
    # the old engine first: moving a rule between engines frees its port there
    if [[ -n "$old" ]]; then
        old_engine=$(_relay_j "$old" '.engine // "realm"')
        [[ "$old_engine" != "$engine" ]] && engines+=("$old_engine")
    fi
    engines+=("$engine")

    # Something else already holding the port is the common way for a rule to
    # be dead on arrival, and realm will not say so loudly enough (see below).
    # A rule that already listens there is an engine's own: on a change that
    # keeps the port, that engine is the listener, so only a port no rule used
    # counts.
    if ! printf '%s' "$prev" | jq -e --argjson p "$port" 'any(.[]; .listen_port == $p)' >/dev/null 2>&1 \
       && _relay_port_bound "$port" tcp; then
        _relay_err "port $port is already in use on this machine; nothing changed"
        return 1
    fi
    _relay_ensure_engine "$engine" || return 1

    _realm_upsert "$rule"
    for e in "${engines[@]}"; do
        if ! _relay_engine_apply "$e"; then
            _realm_save "$prev"
            local back
            for back in "${engines[@]}"; do _relay_engine_apply "$back" >/dev/null 2>&1 || true; done
            _relay_err "$engine did not accept the rule for $tag; nothing changed"
            return 1
        fi
    done
    # The service being active is not enough (see _relay_port_bound): the port
    # has to be listening, or this rule is dead while everything reports well.
    local try
    for try in 1 2 3 4 5; do
        _relay_port_bound "$port" "$proto" && break
        [[ "$try" == 5 ]] || sleep 1
    done
    if ! _relay_port_bound "$port" "$proto"; then
        _realm_save "$prev"
        for e in "${engines[@]}"; do _relay_engine_apply "$e" >/dev/null 2>&1 || true; done
        _relay_err "$engine is running but is not listening on $port (is the port already in use?); nothing changed"
        return 1
    fi

    if [[ "$open_fw" == "1" ]]; then
        _relay_fw_open "$port" "$proto"
    fi
    # metering, so the panel can show what the hop carries, and the limits
    _relay_meter_ensure "$tag" "$port"
    _relay_limits_apply "$rule" "$old"
    _relay_result "$status" "$rule" "$as_json"
}

# ── add ──────────────────────────────────────────────────────────────────────
_relay_add_one() {   # <spec json> <as_json> <open_firewall>
    local spec="$1" as_json="$2" open_fw="$3" rule tag lp
    rule=$(_relay_build "$spec") || return $?
    tag=$(_relay_j "$rule" '.tag')
    if _realm_load | jq -e --arg t "$tag" 'any(.[]; .tag == $t)' >/dev/null 2>&1; then
        _relay_err "a relay called $tag exists already; use update"; return 1
    fi
    rule=$(_relay_resolve_port "$spec" "$rule") || return $?
    lp=$(_relay_j "$rule" '.listen_port')
    if _realm_load | jq -e --argjson p "$lp" 'any(.[]; .listen_port == $p)' >/dev/null 2>&1; then
        _relay_err "another relay already listens on port $lp"; return 1
    fi
    _relay_apply_rule "$rule" "$as_json" created "$open_fw"
}

_relay_cmd_add() {
    _relay_parse "$@" || return 2
    [[ -z "$_RP_POS" ]] || { _relay_err "unexpected argument: $_RP_POS"; return 2; }
    local spec="$_RP_SPEC" as_json="$_RP_JSON" open_fw="$_RP_FW" batch="$_RP_BATCH"
    if [[ -n "$batch" ]]; then
        _relay_cmd_batch "$spec" "$batch" "$as_json" "$open_fw"; return $?
    fi
    exec </dev/null
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }
    _relay_load_realm
    _relay_add_one "$spec" "$as_json" "$open_fw"
}

# One relay per line: "TAG PORT|auto HOST:PORT[,HOST:PORT...]"; the other
# options apply to every line. Each line is added on its own, so one that fails
# leaves the others in place, and says which it was.
_relay_cmd_batch() {   # <common spec> <FILE|-> <as_json> <open_firewall>
    local common="$1" src="$2" as_json="$3" open_fw="$4" text line no=0 tag port tlist hp spec out rc err
    local items="[]" failed="[]"
    if [[ "$src" == - ]]; then text=$(command cat); else text=$(command cat "$src" 2>/dev/null) || { _relay_err "cannot read $src"; return 2; }; fi
    exec </dev/null
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }
    _relay_load_realm
    while IFS= read -r line; do
        no=$((no + 1))
        line=${line%%#*}
        read -r tag port tlist _ <<<"$line"
        [[ -n "$tag" ]] || continue
        err=""
        if [[ -z "$port" || -z "$tlist" ]]; then
            err="line $no: TAG PORT|auto HOST:PORT[,HOST:PORT...]"
        else
            spec=$(printf '%s' "$common" | jq -c --arg t "$tag" '.tag = $t | del(.targets, .remote_host, .remote_port)')
            if [[ "$port" == auto ]]; then spec=$(printf '%s' "$spec" | jq -c '.listen_port_auto = true | del(.listen_port)')
            elif _relay_valid_port "$port"; then spec=$(printf '%s' "$spec" | jq -c --argjson p "$port" '.listen_port = $p | del(.listen_port_auto)')
            else err="line $no: not a port: $port"; fi
            local -a tj=()
            if [[ -z "$err" ]]; then
                IFS=',' read -r -a parts <<<"$tlist"
                for hp in "${parts[@]}"; do
                    hp=$(_relay_split_hp "$hp") || { err="line $no: not HOST:PORT: $hp"; break; }
                    tj+=("$hp")
                done
            fi
            if [[ -z "$err" ]]; then
                spec=$(printf '%s' "$spec" | jq -c --argjson t "$(printf '%s\n' "${tj[@]}" | jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {host: .[0], port: (.[1] | tonumber)})')" '.targets = $t')
                rc=0
                out=$(_relay_add_one "$spec" 1 "$open_fw" 2>"$CFG_DIR/.relay-batch.err") || rc=$?
                if (( rc == 0 )); then
                    items=$(jq -c --argjson i "$(printf '%s' "$out" | jq -c '.item')" '. + [$i]' <<<"$items")
                    (( as_json )) || printf 'created: %s\n' "$tag"
                else
                    err="line $no ($tag): $(sed 's/^psm relay: //' "$CFG_DIR/.relay-batch.err" | tail -1)"
                fi
                rm -f "$CFG_DIR/.relay-batch.err"
            fi
        fi
        if [[ -n "$err" ]]; then
            failed=$(jq -c --arg e "$err" --arg t "$tag" --argjson n "$no" '. + [{line: $n, tag: $t, error: $e}]' <<<"$failed")
            (( as_json )) || _relay_err "$err"
        fi
    done <<<"$text"
    if (( as_json )); then
        jq -nc --argjson v "$_RELAY_CLI_VERSION" --argjson i "$items" --argjson f "$failed" \
            '{status: "batch", api_version: $v, count: ($i | length), items: $i, failed: $f}'
    fi
    [[ "$(jq 'length' <<<"$failed")" == 0 ]]
}

# ── delete ───────────────────────────────────────────────────────────────────
_relay_cmd_delete() {
    local tag="${1:-}"; shift || true
    local yes=0 if_exists=0 as_json=0
    while (( $# )); do
        case "$1" in
            --yes|-y) yes=1; shift ;;
            --if-exists) if_exists=1; shift ;;
            --json) as_json=1; shift ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ -n "$tag" && "$tag" != --* ]] || { _relay_err 'delete requires TAG'; return 2; }
    (( yes )) || { _relay_err 'delete needs --yes'; return 2; }
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }
    exec </dev/null

    _relay_load_realm
    local rule; rule=$(_realm_get_by_tag "$tag")
    if [[ -z "$rule" || "$rule" == "null" ]]; then
        (( if_exists )) && { _relay_result absent "$(jq -nc --arg t "$tag" '{tag:$t}')" "$as_json"; return 0; }
        _relay_err "no such relay: $tag"; return 1
    fi
    local port engine
    port=$(_relay_j "$rule" '.listen_port')
    engine=$(_relay_j "$rule" '.engine // "realm"')

    # the pause (a rule on its port) goes before the port does
    _relay_limits_remove "$tag"
    _realm_delete "$tag"
    _relay_engine_apply "$engine" || { _relay_err "$engine did not reload after removing $tag"; return 1; }
    # after the rule has left the store, so _relay_fw_close sees the port free
    _relay_fw_close "$port"
    _relay_meter_remove "$tag" "$port"
    rm -f "$CFG_DIR/realm/pins/$tag.crt" "$CFG_DIR/realm/certs/tunnel-$tag.crt" "$CFG_DIR/realm/certs/tunnel-$tag.key"
    _relay_result deleted "$rule" "$as_json"
}

# ── update ───────────────────────────────────────────────────────────────────
_relay_cmd_update() {
    _relay_parse "$@" || return 2
    local spec="$_RP_SPEC" as_json="$_RP_JSON" tag="$_RP_POS" v
    # A JSON body (how the agent sends a change) names the relay too; it cannot
    # rename one — realm and gost key a rule by its tag.
    v=$(_relay_j "$spec" '.tag // ""')
    if [[ -n "$v" && -n "$tag" && "$v" != "$tag" ]]; then
        _relay_err "input renames $tag to $v; a relay cannot be renamed, delete and add instead"
        return 2
    fi
    [[ -n "$tag" ]] || tag="$v"
    [[ -n "$tag" ]] || { _relay_err 'update requires TAG'; return 2; }
    [[ "$(_relay_j "$spec" 'del(.tag) | length')" != 0 ]] || { _relay_err 'update needs at least one field to change'; return 2; }
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }
    exec </dev/null

    _relay_load_realm
    local old; old=$(_realm_get_by_tag "$tag")
    [[ -n "$old" && "$old" != "null" ]] || { _relay_err "no such relay: $tag"; return 1; }
    old=$(printf '%s' "$old" | jq -c '.')
    spec=$(printf '%s' "$spec" | jq -c --arg t "$tag" '.tag = $t')

    local new lp old_port
    new=$(_relay_build "$spec" "$old") || return $?
    new=$(_relay_resolve_port "$spec" "$new" "$old") || return $?
    lp=$(_relay_j "$new" '.listen_port')
    if _realm_load | jq -e --arg t "$tag" --argjson p "$lp" \
        'any(.[]; .tag != $t and .listen_port == $p)' >/dev/null 2>&1; then
        _relay_err "another relay already listens on port $lp"; return 1
    fi

    if jq -e --argjson a "$old" --argjson b "$new" -n '$a == $b' >/dev/null; then
        # the rule is as asked; its limits may still need catching up (an
        # expiry that has passed, a quota already used)
        _relay_limits_apply "$new" "$old"
        _relay_result unchanged "$old" "$as_json"; return 0
    fi

    # only the port is needed: _relay_fw_close closes whichever of tcp/udp this
    # relay had actually written into the ledger, and leaves the rest alone
    old_port=$(_relay_j "$old" '.listen_port')
    _relay_apply_rule "$new" "$as_json" updated 1 "$old" || return 1
    # the old port closes only once the new rule is live, and only if this
    # opened it and no other rule still listens there
    if [[ "$lp" != "$old_port" ]]; then
        _relay_fw_close "$old_port"
        # the old port's accounting rules would otherwise keep counting for a
        # port this relay no longer listens on
        _relay_meter_remove "$tag" "$old_port"
        _relay_meter_ensure "$tag" "$lp"
    fi
}

# ── install ──────────────────────────────────────────────────────────────────
# An engine itself, without questions: the panel's agent gets one installed by
# the first rule that needs it, the way a core is by the first node.
_relay_ensure_realm() {
    _relay_load_realm
    [[ -x "$REALM_BIN" ]] && return 0
    realm_install_unattended >&2 || { _relay_err 'could not install realm'; return 1; }
    [[ -x "$REALM_BIN" ]] || { _relay_err "realm is still missing: $REALM_BIN"; return 1; }
}

_relay_cmd_install() {
    local as_json=0 engine=realm
    while (( $# )); do
        case "$1" in
            --json) as_json=1; shift ;;
            --engine) engine="${2:-}"; shift 2 ;;
            *) _relay_err "unknown option: $1"; return 2 ;;
        esac
    done
    case "$engine" in realm|gost) ;; *) _relay_err '--engine must be realm or gost'; return 2 ;; esac
    [[ $EUID -eq 0 ]] || { _relay_err 'must run as root'; return 1; }
    exec </dev/null
    _relay_ensure_engine "$engine" || return 1
    local ver bin
    if [[ "$engine" == gost ]]; then bin="$GOST_BIN"; ver="gost $(gost_version)"
    else bin="$REALM_BIN"; ver=$("$REALM_BIN" --version 2>/dev/null | head -1); fi
    if (( as_json )); then
        jq -nc --arg v "$ver" --arg b "$bin" --arg e "$engine" --argjson ver "$_RELAY_CLI_VERSION" \
            '{status:"installed", api_version:$ver, item:{engine:$e, binary:$b, version:$v}}'
    else
        printf 'installed: %s\n' "$ver"
    fi
}

# ── psm relay ────────────────────────────────────────────────────────────────
psm_relay_cli() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        list)    _relay_cmd_list "$@" ;;
        show)    _relay_cmd_show "$@" ;;
        add)     _relay_cmd_add "$@" ;;
        update)  _relay_cmd_update "$@" ;;
        delete)  _relay_cmd_delete "$@" ;;
        probe)   _relay_cmd_probe "$@" ;;
        install) _relay_cmd_install "$@" ;;
        help|--help|-h|"") _relay_usage ;;
        *) _relay_err "unknown command: $cmd"; _relay_usage >&2; return 2 ;;
    esac
}
