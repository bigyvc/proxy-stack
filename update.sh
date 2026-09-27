#!/usr/bin/env bash
# update.sh — PSM self-update and component upgrade

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PSM_ROOT/lib"

source "$LIB_DIR/common.sh"

PSM_VERSION_FILE="$PSM_ROOT/.version"
CURRENT_VERSION=$(cat "$PSM_VERSION_FILE" 2>/dev/null || echo "dev")

psm_check_version() {
    log_info "$(t update.current_ver "$CURRENT_VERSION")"
    if [[ -d "$PSM_ROOT/.git" ]]; then
        # compare with the remote branch: fetch --dry-run's output (errors
        # included, as it was counted) said "update available" when offline
        if timeout 20 git -C "$PSM_ROOT" fetch -q 2>/dev/null; then
            local behind
            behind=$(git -C "$PSM_ROOT" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)
            (( behind > 0 )) && log_info "$(t update.available)" \
                             || log_info "$(t update.uptodate)"
        else
            log_warn "$(t update.check_failed)"
        fi
    else
        log_info "$(t update.not_git)"
    fi
}

psm_update_scripts() {
    log_step "$(t update.backing_up)"
    source "$LIB_DIR/backup.sh"
    do_quick_backup "pre-update" &>/dev/null

    log_step "$(t update.pulling)"
    if [[ -d "$PSM_ROOT/.git" ]]; then
        # PSM's state (config/, backup/, logs/) is ignored by git (.gitignore), so
        # only edits to the scripts are reverted — saved as a patch first.
        # The chmod +x below is not a local change: ignore file modes.
        git -C "$PSM_ROOT" config core.fileMode false 2>/dev/null || true
        if ! git -C "$PSM_ROOT" diff --quiet HEAD -- 2>/dev/null; then
            local patch; patch="${HOME:-/root}/psm-local-changes-$(date +%Y%m%d%H%M%S).patch"
            git -C "$PSM_ROOT" diff HEAD > "$patch" 2>/dev/null && log_warn "$(t update.local_saved "$patch")"
        fi
        timeout 5 git -C "$PSM_ROOT" reset -q --hard HEAD 2>/dev/null || true
        psm_repo_slim "$PSM_ROOT" 2>/dev/null || true
        # --no-stat: a diffstat would download the files the slim checkout skips
        timeout 30 git -C "$PSM_ROOT" pull --ff-only --no-stat \
            && log_ok "$(t update.git_done)" \
            || log_error "$(t update.git_fail)"
    else
        log_warn "$(t update.not_git_reinstall)"
    fi
    # Recursively chmod — covers lib/xray/, lib/tgbot/, lib/expiry/ etc.
    find "$PSM_ROOT" -name "*.sh" -exec chmod +x {} +
}

psm_update_xray() {
    log_step "$(t update.xray)"
    source "$LIB_DIR/xray/core.sh"
    xray_upgrade
}

psm_update_singbox() {
    # 未安装则跳过：sb_upgrade 会走完整安装流程，避免「更新所有组件」意外装上第二内核
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        log_info "$(t update.singbox_not_installed)"
        return 0
    fi
    log_step "$(t update.singbox)"
    source "$LIB_DIR/singbox/core.sh"
    sb_upgrade
}

psm_update_mihomo() {
    if [[ ! -f "$MIHOMO_BIN" ]]; then
        log_info "$(t update.mihomo_not_installed)"
        return 0
    fi
    log_step "$(t update.mihomo)"
    source "$LIB_DIR/mihomo/core.sh"
    mh_upgrade
}

psm_update_hysteria2() {
    log_step "$(t update.hy2)"
    source "$LIB_DIR/hysteria2.sh"
    hy2_install
}

psm_update_nginx() {
    log_step "$(t update.nginx)"
    source "$LIB_DIR/nginx.sh"
    nginx_upgrade
}

# The rule data Xray routes by. Each file is checked against the .sha256sum
# the release publishes next to it before it replaces the one in use; a
# download that fails or does not match leaves the old one (and a failure no
# longer ends the whole update, nor does a missing Xray directory).
psm_update_geofiles() {
    log_step "$(t update.geo)"
    local base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    local dir=/usr/local/share/xray f tmp want got ok=1
    mkdir -p "$dir"
    tmp=$(mktemp -d) || return 1
    for f in geoip.dat geosite.dat; do
        if curl "${PSM_DL[@]}" -fsSL "$base/$f" -o "$tmp/$f" \
            && curl "${PSM_DL[@]}" -fsSL "$base/$f.sha256sum" -o "$tmp/$f.sha256sum"; then
            want=$(awk '{ print $1; exit }' "$tmp/$f.sha256sum")
            got=$(sha256sum "$tmp/$f" | awk '{ print $1 }')
            if [[ -n "$want" && "$want" == "$got" ]]; then
                install -m 644 "$tmp/$f" "$dir/$f"
                continue
            fi
        fi
        ok=0; log_warn "$(t update.geo_failed "$f")"
    done
    rm -rf "$tmp"
    (( ok )) && log_ok "$(t update.geo_done)"
    svc_restart xray 2>/dev/null || true
    return 0
}

# shellcheck disable=SC2120  # optional target; the menu calls it without one
psm_update() {
    require_root

    echo -e "\n${BOLD}${CYAN}$(t update.header)${NC}\n"
    psm_check_version

    # `psm --update <what>`: no questions, for psm-agent, the panel and cron.
    # Without it the menu below reads from a stdin that is not there, and the
    # caller gets the menu and a non-zero exit instead of an update.
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        case "$target" in
            scripts|psm)        psm_update_scripts ;;
            xray)               psm_update_xray ;;
            singbox|sing-box)   psm_update_singbox ;;
            mihomo)             psm_update_mihomo ;;
            hysteria2|hy2)      psm_update_hysteria2 ;;
            nginx)              psm_update_nginx ;;
            geo|geofiles)       psm_update_geofiles ;;
            all)
                psm_update_scripts
                psm_update_xray
                psm_update_singbox
                psm_update_mihomo
                psm_update_hysteria2
                psm_update_nginx
                psm_update_geofiles
                ;;
            *)  printf 'psm update: unknown target: %s (scripts, xray, singbox, mihomo, hysteria2, nginx, geo, all)\n' "$target" >&2
                return 2 ;;
        esac
        return $?
    fi

    show_menu "$(t update.menu.title)" \
        "$(t update.menu.scripts)" \
        "$(t update.menu.xray)" \
        "$(t update.menu.singbox)" \
        "$(t update.menu.mihomo)" \
        "$(t update.menu.hy2)" \
        "$(t update.menu.nginx)" \
        "$(t update.menu.geo)" \
        "$(t update.menu.all)"

    case "$MENU_CHOICE" in
        1) psm_update_scripts ;;
        2) psm_update_xray ;;
        3) psm_update_singbox ;;
        4) psm_update_mihomo ;;
        5) psm_update_hysteria2 ;;
        6) psm_update_nginx ;;
        7) psm_update_geofiles ;;
        8)
            psm_update_scripts
            psm_update_xray
            psm_update_singbox
            psm_update_mihomo
            psm_update_hysteria2
            psm_update_nginx
            psm_update_geofiles
            ;;
        0) return ;;
    esac
}

# If called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    psm_update
fi
