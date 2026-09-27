#!/usr/bin/env bash
# backup.sh — backup and restore for PSM-managed configs

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BAK_ROOT="$BAK_DIR"
MAX_BACKUPS=10

# Backups hold every key and password PSM keeps: the directory is root's alone
# (a quick backup is a plain directory in it, so this covers its files too),
# and an archive is written 600.
_backup_root() { mkdir -p "$BAK_ROOT" && chmod 700 "$BAK_ROOT"; }

# ── Quick backup (called before modifications) ────────────────────────────────
do_quick_backup() {
    local desc="${1:-manual}"
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local name="${ts}_${desc//[^A-Za-z0-9._-]/_}"
    local bak="$BAK_ROOT/$name" src dst failed=""
    _backup_root && mkdir -p "$bak" || return 1

    # Nginx, Xray, Hysteria2, PSM's own state, the certificates. A copy that
    # fails (a full disk) is said, not swallowed: an incomplete backup that
    # looks complete is worse than none.
    while IFS='|' read -r src dst; do
        [[ -d "$src" ]] || continue
        cp -a "$src" "$bak/$dst" 2>/dev/null || failed+="${failed:+, }$dst"
    done <<EOF
/etc/nginx|nginx
$XRAY_CFG_DIR|xray
/etc/hysteria|hysteria
$CFG_DIR|psm_config
$NGINX_SSL_DIR|ssl
EOF
    [[ -z "$failed" ]] || log_warn "$(t backup.copy_failed "$failed" "$bak")"

    _rotate_backups
    log_ok "$(t backup.quick_saved "$bak")"
    echo "$bak"
}

# ── Full backup ───────────────────────────────────────────────────────────────
do_full_backup() {
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local name="${ts}_full"
    local bak="$BAK_ROOT/$name"
    _backup_root && mkdir -p "$bak" || return 1

    log_step "$(t backup.full_creating "$bak")"

    # All PSM components
    [[ -d /etc/nginx      ]] && cp -a /etc/nginx      "$bak/nginx"
    [[ -d "$XRAY_CFG_DIR" ]] && cp -a "$XRAY_CFG_DIR" "$bak/xray"
    [[ -d /etc/hysteria   ]] && cp -a /etc/hysteria   "$bak/hysteria"
    [[ -d "$CFG_DIR"      ]] && cp -a "$CFG_DIR"      "$bak/psm_config"
    [[ -d "$NGINX_SSL_DIR" ]] && cp -a "$NGINX_SSL_DIR" "$bak/ssl"

    # Docker compose files (includes any bind-mount data dirs under them)
    [[ -d /opt/psm/compose ]] && cp -a /opt/psm/compose "$bak/docker_compose"

    # Docker named volumes (Portainer/Vaultwarden/etc. — live outside /opt/psm/compose)
    source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
        && declare -f docker_backup_volumes &>/dev/null \
        && docker_backup_volumes "$bak"

    # Compress
    local archive="$BAK_ROOT/${name}.tar.gz"
    ( umask 077; tar -czf "$archive" -C "$BAK_ROOT" "$name" ) && rm -rf "$bak"
    chmod 600 "$archive" 2>/dev/null || true
    _rotate_backups
    log_ok "$(t backup.full_done "$archive")"
    echo "$archive"
}

# ── Selective backup ──────────────────────────────────────────────────────────
do_selective_backup() {
    echo -e "\n  $(t backup.select_prompt)"
    echo    "  1. $(t backup.item.nginx)"
    echo    "  2. $(t backup.item.xray)"
    echo    "  3. $(t backup.item.hysteria)"
    echo    "  4. $(t backup.item.psm)"
    echo    "  5. $(t backup.item.ssl)"
    echo    "  6. $(t backup.item.docker_compose)"
    echo    "  7. $(t backup.item.docker_volumes)"
    read -rp "$(echo -e "${CYAN}$(t common.select)${NC}")" choices

    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local bak="$BAK_ROOT/${ts}_selective"
    _backup_root && mkdir -p "$bak" || return 1

    for c in $choices; do
        case "$c" in
            1) [[ -d /etc/nginx        ]] && cp -a /etc/nginx      "$bak/nginx" ;;
            2) [[ -d "$XRAY_CFG_DIR"   ]] && cp -a "$XRAY_CFG_DIR" "$bak/xray" ;;
            3) [[ -d /etc/hysteria     ]] && cp -a /etc/hysteria   "$bak/hysteria" ;;
            4) [[ -d "$CFG_DIR"        ]] && cp -a "$CFG_DIR"      "$bak/psm_config" ;;
            5) [[ -d "$NGINX_SSL_DIR"  ]] && cp -a "$NGINX_SSL_DIR" "$bak/ssl" ;;
            6) [[ -d /opt/psm/compose  ]] && cp -a /opt/psm/compose "$bak/docker_compose" ;;
            7) source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
                   && declare -f docker_backup_volumes &>/dev/null \
                   && docker_backup_volumes "$bak" ;;
        esac
    done

    local archive="$BAK_ROOT/${ts}_selective.tar.gz"
    ( umask 077; tar -czf "$archive" -C "$BAK_ROOT" "${ts}_selective" ) && rm -rf "$bak"
    chmod 600 "$archive" 2>/dev/null || true
    _rotate_backups
    log_ok "$(t backup.select_done "$archive")"
}

# ── List backups ──────────────────────────────────────────────────────────────
list_backups() {
    echo -e "\n${BOLD}$(t backup.available)${NC}"
    local i=1
    find "$BAK_ROOT" -mindepth 1 -maxdepth 1 \( -name "*.tar.gz" -o -type d \) \
        | sort -r | while read -r f; do
            local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
            printf "  %2d. %-50s %s\n" "$i" "$(basename "$f")" "$size"
            ((i++))
          done
}

# ── Restore ───────────────────────────────────────────────────────────────────
# From a full / selective archive or a quick backup (a directory). Nothing is
# stopped or replaced until the backup has been opened; the current state is
# saved first as a quick backup, and each component is copied next to the live
# one before it takes its place, so a copy that fails (a full disk) leaves the
# live component as it was.
do_restore() {
    list_backups
    local archive; ask archive "$(t backup.ask_archive)"
    archive=$(basename -- "$archive")   # a name in the list, never a path out of it
    local full_path="$BAK_ROOT/$archive"
    [[ -n "$archive" && ( -f "$full_path" || -d "$full_path" ) ]] || { log_error "$(t backup.not_found "$full_path")"; return 1; }

    ask_yn "$(t backup.ask_restore "$archive")" N || return 0

    local tmp_dir bak_dir
    tmp_dir=$(mktemp -d) || return 1
    if [[ -d "$full_path" ]]; then
        # a copy: the backup taken before restoring rotates old quick backups,
        # and this one may be the oldest
        cp -a "$full_path" "$tmp_dir/" 2>/dev/null || { rm -rf "$tmp_dir"; log_error "$(t backup.extract_failed "$full_path")"; return 1; }
        bak_dir="$tmp_dir/$archive"
    else
        if ! tar -xzf "$full_path" -C "$tmp_dir" 2>/dev/null; then
            rm -rf "$tmp_dir"
            log_error "$(t backup.extract_failed "$full_path")"; return 1
        fi
        bak_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        [[ -n "$bak_dir" ]] || { rm -rf "$tmp_dir"; log_error "$(t backup.extract_failed "$full_path")"; return 1; }
    fi

    echo -e "\n  $(t backup.restore_prompt)"
    echo    "  1. $(t backup.item.nginx)"
    echo    "  2. $(t backup.item.xray)"
    echo    "  3. $(t backup.item.hysteria)"
    echo    "  4. $(t backup.item.psm)"
    echo    "  5. $(t backup.item.ssl)"
    echo    "  6. $(t backup.item.docker_restore)"
    echo    "  7. $(t backup.item.all)"
    read -rp "$(echo -e "${CYAN}$(t backup.select_default7)${NC}")" rc; rc="${rc:-7}"
    # 选 7（全部恢复）时展开为全部组件；否则保留用户输入的多个数字（空格分隔）
    [[ "$rc" == *7* ]] && rc="1 2 3 4 5 6"

    # what is live now, in case this backup turns out to be the wrong one
    local pre; pre=$(do_quick_backup pre-restore 2>/dev/null | tail -1) && log_info "$(t backup.pre_restore "$pre")"

    _stop_services

    for c in $rc; do
        case "$c" in
            1) _restore_dir "$bak_dir/nginx" /etc/nginx && log_ok "$(t backup.restored.nginx)" ;;
            2) _restore_dir "$bak_dir/xray" "$XRAY_CFG_DIR" && log_ok "$(t backup.restored.xray)" ;;
            3) _restore_dir "$bak_dir/hysteria" /etc/hysteria && log_ok "$(t backup.restored.hysteria)" ;;
            4) _restore_dir "$bak_dir/psm_config" "$CFG_DIR" && log_ok "$(t backup.restored.psm)" ;;
            5) _restore_dir "$bak_dir/ssl" "$NGINX_SSL_DIR" && log_ok "$(t backup.restored.ssl)" ;;
            6)
                _restore_dir "$bak_dir/docker_compose" /opt/psm/compose && log_ok "$(t backup.restored.docker)"
                source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
                    && declare -f docker_restore_volumes &>/dev/null \
                    && docker_restore_volumes "$bak_dir"
                ;;
        esac
    done

    rm -rf "$tmp_dir"
    _start_services
    log_ok "$(t backup.restore_done)"
}

# One component: copied beside the live one, then swapped in. Nothing to
# restore (not in this backup) is no error and changes nothing.
_restore_dir() {   # <from> <live path>
    local from="$1" live="$2" next="$2.psm-restore"
    [[ -d "$from" ]] || return 1
    rm -rf "$next"
    if ! cp -a "$from" "$next" 2>/dev/null; then
        rm -rf "$next"
        log_error "$(t backup.restore_item_failed "$live")"
        return 1
    fi
    rm -rf "$live" && mv "$next" "$live"
}

_stop_services() {
    local svc
    for svc in nginx xray hysteria-server; do
        svc_is_active "$svc" && { svc_stop "$svc" || true; }
    done
    return 0
}

_start_services() {
    local svc
    for svc in nginx xray hysteria-server; do
        svc_is_enabled "$svc" && { svc_start "$svc" || log_warn "$svc"; }
    done
    return 0
}

# ── Rotate old backups ────────────────────────────────────────────────────────
# The newest MAX_BACKUPS archives, and the newest MAX_BACKUPS quick backups
# (directories named <date>_<time>_…, which a quick backup is): a quick backup
# is uncompressed, and they used to pile up until the disk was full.
_rotate_backups() {
    local rotated=0 kind count
    for kind in archive quick; do
        if [[ "$kind" == archive ]]; then
            count=$(find "$BAK_ROOT" -maxdepth 1 -type f -name "*.tar.gz" | wc -l)
        else
            count=$(find "$BAK_ROOT" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*_[0-9]*_*' | wc -l)
        fi
        (( count > MAX_BACKUPS )) || continue
        if [[ "$kind" == archive ]]; then
            find "$BAK_ROOT" -maxdepth 1 -type f -name "*.tar.gz"
        else
            find "$BAK_ROOT" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*_[0-9]*_*'
        fi | sort | head -n "$((count - MAX_BACKUPS))" | while IFS= read -r old; do
            rm -rf -- "$old"
        done
        rotated=1
    done
    (( rotated )) && log_info "$(t backup.rotated "$MAX_BACKUPS")"
    return 0
}

# ── Schedule auto-backup ──────────────────────────────────────────────────────
auto_backup_enable() {
    local hour; ask hour "$(t backup.ask_hour)" "3"
    # one number, or the cron line takes whatever was typed
    [[ "$hour" =~ ^[0-9]{1,2}$ ]] && (( 10#$hour <= 23 )) || { log_error "$(t backup.bad_hour)"; return 1; }
    hour=$((10#$hour))
    ensure_cron || true   # RHEL 系最小安装没有 cronie，/etc/cron.d 会被无声忽略
    cat > /etc/cron.d/psm-backup <<EOF
0 ${hour} * * * root $PSM_ROOT/manager.sh --backup-full >> $LOG_DIR/backup.log 2>&1
EOF
    log_ok "$(t backup.auto_enabled "$hour")"
}

auto_backup_disable() {
    rm -f /etc/cron.d/psm-backup
    log_ok "$(t backup.auto_disabled)"
}

# ── Dependency check ─────────────────────────────────────────────────────────
_backup_check_deps() {
    ensure_pkg_deps tar
}

# ── Menu ──────────────────────────────────────────────────────────────────────
backup_menu() {
    _backup_check_deps
    while true; do
        show_menu "$(t backup.menu.title)" \
            "$(t backup.menu.full)" \
            "$(t backup.menu.selective)" \
            "$(t backup.menu.restore)" \
            "$(t backup.menu.list)" \
            "$(t backup.menu.auto_enable)" \
            "$(t backup.menu.auto_disable)" \
            "$(t migrate.menu.export)" \
            "$(t migrate.menu.import)"

        case "$MENU_CHOICE" in
            1) do_full_backup ;;
            2) do_selective_backup ;;
            3) do_restore ;;
            4) list_backups ;;
            5) auto_backup_enable ;;
            6) auto_backup_disable ;;
            7) source "$LIB_DIR/migrate.sh"
               # the bundle holds every key of this server: encrypted unless asked not to
               if ask_yn "$(t migrate.ask_encrypt)" Y; then psm_migrate_export || true; else psm_migrate_export --no-encrypt || true; fi ;;
            8) source "$LIB_DIR/migrate.sh"; migrate_menu_import ;;
            0) return ;;
        esac
        press_enter
    done
}
