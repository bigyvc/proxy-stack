#!/usr/bin/env bash
# check_cli.sh — psm check: what this server's IP looks like to the rest of the
# internet (owner, kind of network, risk) and which streaming and AI services
# let it in, IPv4 and IPv6 apart. The PSM panel's "IP 质量与解锁".
#
#   psm check [all|ip|mail|unlock] [-4|-6] [--keys-stdin] [--json]
#
# The check itself is jinqians/ipcheck, which PSM does not carry: the release
# pinned below is downloaded when this runs, its SHA-256 checked, run from a
# temporary directory and deleted with it.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PSM_IPCHECK_VERSION="0.1.0"
PSM_IPCHECK_SHA256="41bb289c37baa1c05dba14e935a241791c5c81774dc4c835887a8058bab445e0"
# tests point this at a local copy of the release
PSM_IPCHECK_BASE_URL="${PSM_IPCHECK_BASE_URL:-https://github.com/jinqians/ipcheck/releases/download/v${PSM_IPCHECK_VERSION}}"

_check_err() { printf 'psm check: %s\n' "$*" >&2; }

_check_usage() {
    cat <<'EOF'
Usage:
  psm check [all|ip|mail|unlock] [-4|-6] [--keys-stdin] [--json]

What this server's IP looks like from outside: who owns it, where it is
registered (a native or a broadcast IP), whether it is a data centre, a home
or a mobile network, how several databases score it, whether it can send
mail and sits on DNS blacklists, and which services let it in (Netflix,
Disney+, YouTube Premium, Prime Video, ChatGPT, Claude, Gemini, TikTok,
Reddit, Google search). ip, mail, unlock: one part only; -4 / -6: one
address family. --keys-stdin reads optional API keys, one NAME=value a line
(ABUSEIPDB, IPQS, IP2LOCATION), which widen the comparison; they reach the
check through its environment, never the command line. The check is
jinqians/ipcheck, fetched when this runs (a pinned release, its SHA-256
checked) and deleted after.
EOF
}

psm_check_cli() {
    local what=all fam="" json=0 keys=0 tmp got rc line name val kv
    local -a env=()
    while (($#)); do
        case "$1" in
            all|ip|mail|unlock) what="$1" ;;
            -4|-6) fam="$1" ;;
            --keys-stdin) keys=1 ;;
            --json) json=1 ;;
            -h|--help|help) _check_usage; return 0 ;;
            *) _check_err "unknown argument: $1"; _check_usage >&2; return 2 ;;
        esac
        shift
    done
    if ((keys)); then
        # NAME=value lines; anything else, or a value that does not look like a key, is left out
        while IFS= read -r line || [[ -n "$line" ]]; do
            name=${line%%=*} val=${line#*=}
            [[ "$val" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || continue
            case "$name" in ABUSEIPDB|IPQS|IP2LOCATION) env+=("IPCHECK_${name}_KEY=$val") ;; esac
        done
    fi
    command -v curl >/dev/null 2>&1 || { _check_err "curl is needed"; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { _check_err "sha256sum is needed"; return 1; }

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/psm-check.XXXXXX") || return 1
    if ! curl "${PSM_DL[@]}" -fsSL --max-time 60 -o "$tmp/ipcheck.sh" "$PSM_IPCHECK_BASE_URL/ipcheck.sh"; then
        rm -rf "$tmp"
        _check_err "download failed: $PSM_IPCHECK_BASE_URL/ipcheck.sh"
        return 1
    fi
    got=$(sha256sum "$tmp/ipcheck.sh" | cut -d' ' -f1)
    if [[ "$got" != "$PSM_IPCHECK_SHA256" ]]; then
        rm -rf "$tmp"
        _check_err "ipcheck $PSM_IPCHECK_VERSION does not match its checksum (got $got): not run"
        return 1
    fi

    local args=(--lang "$([[ "${PSM_LANG:-zh}" == zh ]] && echo zh || echo en)")
    [[ "$what" == all ]] || args+=("--$what")
    [[ -n "$fam" ]] && args+=("$fam")
    ((json)) && args+=(--json)
    # (manager.sh runs under set -e: a failing check must still be cleaned up)
    rc=0
    # the keys go in by export (a builtin) in a subshell: never in anyone's argv
    (
        for kv in ${env[@]+"${env[@]}"}; do export "${kv?}"; done
        exec bash "$tmp/ipcheck.sh" "${args[@]}"
    ) || rc=$?
    rm -rf "$tmp"
    return "$rc"
}
