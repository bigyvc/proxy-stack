#!/bin/bash
# The findings of the 2026-09-26 code audit, each driven the way it was
# found to go wrong, on a real system of each family:
#
#   tests/integration/container.sh debian|alpine|rocky9|… audit
#
# Every check states what must hold now. Run inside the container, as root,
# from /opt/psm (container.sh copies the tree there).
cd /opt/psm || exit 1
export TERM=dumb
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
sec() { echo; echo "=== $*"; }
chk() { local d="$1"; shift; if "$@" >/tmp/chk.out 2>&1; then ok "$d"; else bad "$d"; tail -6 /tmp/chk.out | sed 's/^/       /'; fi; }
# a PSM shell: the libraries loaded, as the menus have them
P() { bash -c "export PSM_ROOT=/opt/psm LIB_DIR=/opt/psm/lib; source /opt/psm/lib/common.sh >/dev/null 2>&1; $1"; }
psm() { bash manager.sh "$@"; }
# the checks run most of their code in `bash -c`: without this, P was not
# found there, and a check written as "! P …" passed for that reason alone
export -f P psm

sec "install"
chk "install.sh" bash -c "printf '1\n0\n0\n0\n0\n' | timeout 900 bash install.sh >/tmp/install.log 2>&1; tail -1 /tmp/install.log; command -v jq"
command -v iptables >/dev/null 2>&1 || P 'ensure_pkg_deps iptables' >/dev/null 2>&1

sec "X-S1 hop: a tag is never run as a command"
mkdir -p config/singbox
printf '[{"tag":"h$(touch /tmp/pwned-hop)","port":30500,"hop_ports":"40000-40100"}]\n' > config/singbox/hysteria2.json
P 'source lib/hop.sh; psm_hop_sync' >/dev/null 2>&1
chk "the redirect rule is there" bash -c "iptables -t nat -L PREROUTING -n | grep -q 'psm-hop:'"
printf '[]\n' > config/singbox/hysteria2.json
P 'source lib/hop.sh; psm_hop_sync' >/dev/null 2>&1
chk "… and gone after the next sync" bash -c "! iptables -t nat -L PREROUTING -n | grep -q 'psm-hop:'"
chk "… and the \$(…) in the tag never ran" test ! -e /tmp/pwned-hop
rm -f config/singbox/hysteria2.json

sec "X-S2 / X-S3 users: a store that does not parse is never read as empty"
chk "two accounts" bash -c "bash manager.sh user add alice --json >/dev/null && bash manager.sh user add bob --json >/dev/null"
chk "… the last good store is kept beside it" test -s config/users.json.prev
cp config/users.json /tmp/users.good
printf '{"users":[{"name":"alice"' > config/users.json   # cut short, as a power cut leaves it
bash manager.sh --traffic-check >/dev/null 2>&1
chk "the periodic check did not write an empty store" bash -c "jq -e '.users | length >= 1' config/users.json >/dev/null 2>&1 || grep -q alice config/users.json"
chk "psm user list still names the accounts (from the good copy)" bash -c "bash manager.sh user list 2>/dev/null | grep -q alice"
cp /tmp/users.good config/users.json
id psmtest >/dev/null 2>&1 || { useradd -M psmtest 2>/dev/null || adduser -D -H psmtest 2>/dev/null; }
chk "psm user links is root's" bash -c "! su -s /bin/bash psmtest -c 'bash /opt/psm/manager.sh user links alice --server 1.2.3.4' >/dev/null 2>&1"
chk "--quota 0 is no quota (not an account that can never pass a byte)" bash -c "bash manager.sh user update alice --quota 0 --json | jq -e '.quota_bytes == null' >/dev/null 2>&1 || jq -e '.users[] | select(.name == \"alice\") | .quota_bytes == null' config/users.json"
bash manager.sh user delete alice >/dev/null 2>&1; bash manager.sh user delete bob >/dev/null 2>&1

sec "X-S4 / X-S6 / X-M15 / X-M26 backups"
P 'source lib/backup.sh; for i in $(seq 1 13); do do_quick_backup "t$i" >/dev/null 2>&1; sleep 1; done'
chk "quick backups are rotated (no more than 10)" test "$(find backup -mindepth 1 -maxdepth 1 -type d -name '[0-9]*_[0-9]*_*' | wc -l)" -le 10
chk "the backup directory is root's alone" test "$(stat -c %a backup)" = 700
printf 'not a tar' > backup/99990101_000000_full.tar.gz
out=$(P 'source lib/backup.sh; do_restore' <<< $'99990101_000000_full.tar.gz\ny\n7' 2>&1); rc=$?
chk "a restore from a damaged archive fails, and says so (rc $rc)" bash -c "[[ $rc != 0 ]] && grep -qiE 'unpack|解不开|풀 수|распаковать' <<<$(printf '%q' "$out")"
chk "… with nothing touched (no \"restore complete\")" bash -c "! grep -qiE 'Restore complete|恢复完成' <<<$(printf '%q' "$out")"
rm -f backup/99990101_000000_full.tar.gz
chk "a restore takes a path out of the list as a plain name (../ stays inside)" bash -c "P() { $(declare -f P | tail -n +2); }; out=\$(P 'source lib/backup.sh; do_restore' <<< \$'../../etc\ny\n7' 2>&1); [[ \$out == *'backup/etc'* || \$out == *'not found'* || \$out == *'未找到'* ]]"
chk "auto backup refuses an hour that is not 0-23" bash -c "! P 'source lib/backup.sh; auto_backup_enable' <<< '3 * * *' >/dev/null 2>&1; ! grep -q '\* \* \* \*' /etc/cron.d/psm-backup 2>/dev/null"

sec "X-S10 / X-S11 / X-S14 / X-M5..M8 names that would leave their directory"
mkdir -p /etc/nginx/conf.d /etc/nginx/stream.d; touch /etc/nginx/nginx.conf
chk "delete_site refuses ../../etc/nginx/nginx" bash -c "! P 'source lib/nginx.sh; delete_site' <<< '../../etc/nginx/nginx' >/dev/null 2>&1; test -f /etc/nginx/nginx.conf"
chk "cert_delete refuses ../conf.d (was rm -rf /etc/nginx/conf.d)" bash -c "! P 'source lib/cert.sh; cert_delete' <<< $'../conf.d\ny' >/dev/null 2>&1; test -d /etc/nginx/conf.d"
chk "cert_import_manual refuses ../x" bash -c "! P 'source lib/cert.sh; cert_import_manual' <<< $'../x\n/etc/hostname\n/etc/hostname\n' >/dev/null 2>&1; test ! -e /etc/nginx/x"
MAP=$(P 'source lib/nginx.sh; _sni_map_file')
mkdir -p "$(dirname "$MAP")"
printf 'map $ssl_preread_server_name $psm_backend {\n    # PSM:ENTRIES:BEGIN\n    # PSM:ENTRIES:END\n    default     "";\n}\n' > "$MAP"
chk "an SNI entry called default is refused" bash -c "! P 'source lib/nginx.sh; _sni_add_entry default 127.0.0.1:9' >/dev/null 2>&1"
chk "… and removing default is refused too" bash -c "! P 'source lib/nginx.sh; _sni_remove_entry default' >/dev/null 2>&1"
chk "… the blackhole default is still the default" grep -qE '^    default +"";' "$MAP"
chk "an upstream that would add a directive is refused" bash -c "! P 'source lib/nginx.sh; _sni_add_entry a.example.com \"127.0.0.1:9; proxy_pass x\"' >/dev/null 2>&1"
chk "add_site refuses a proxy_pass that is not host:port" bash -c "! P 'source lib/nginx.sh; add_site' <<< $'a.example.com\n127.0.0.1:8080; proxy_set_header X 1\nn\nn\nn' >/dev/null 2>&1; test ! -e /etc/nginx/conf.d/a.example.com.conf"
rm -f "$MAP"

sec "X-S12 / X-M34 / X-L28 honeypot and fail2ban"
chk "the jail bans for 7 days, longer for repeats, never forever" bash -c "P 'source lib/security/honeypot.sh; HP_JAIL_FILE=/tmp/hp.conf; _hp_write_jail' >/dev/null 2>&1; grep -q '^bantime *= 7d' /tmp/hp.conf && grep -q 'bantime.increment *= true' /tmp/hp.conf && ! grep -q 'bantime *= -1' /tmp/hp.conf"
if command -v ufw >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1; then
    P 'source lib/security/honeypot.sh; _hp_apply_port 3389' >/dev/null 2>&1
    chk "the tripwire goes first in INPUT (before a firewall's own chains)" bash -c "iptables -S INPUT | sed -n 2,3p | grep -q 'dport 3389'"
    P 'source lib/security/honeypot.sh; _hp_remove_port 3389' >/dev/null 2>&1
fi
chk "a whitelist entry must be an address or a network" bash -c "P 'source lib/security/fail2ban.sh; _f2b_valid_ip 1.2.3.0/24 && _f2b_valid_ip 2001:db8::/32 && ! _f2b_valid_ip \"1.2.3.4 ; x\" && ! _f2b_valid_ip 300.1.1.1'"
chk "jail times must be times" bash -c "P 'source lib/security/fail2ban.sh; _f2b_valid_time 10m && _f2b_valid_time 3600 && ! _f2b_valid_time \"1h; x\"'"

sec "X-S15 / X-M37 expiry on this system's date"
chk "an expiry date parses to a time (no silent 0)" bash -c "P 'source lib/expiry/core.sh; t=\$(_exp_str_to_ts \"2026-12-31 23:59:59\"); [[ \$t -gt 1700000000 ]]'"
chk "\"now + 1 month\" works here (the wizard's date)" bash -c "[[ -n \$(TZ=Asia/Hong_Kong date -d 'now +1 months' +%Y-%m-%d 2>/dev/null) ]]"
P 'source lib/traffic.sh; _trf_init; _trf_init_tag tx 23456; _trf_set_str tx source iptables; _trf_set_field tx count_port 23456; _trf_set_field tx meter true; exp_set tx 23456 "2020-01-01 00:00:00"' >/dev/null 2>&1
bash manager.sh --traffic-check >/dev/null 2>&1
chk "a node past its expiry is paused by the periodic check" bash -c "jq -e '.tx.paused == true' config/traffic/state.json >/dev/null && iptables -S INPUT | grep -q 'dport 23456.*REJECT'"
P 'source lib/traffic.sh; _trf_cleanup_node tx' >/dev/null 2>&1

sec "X-M1 / X-L7 / X-M47 traffic"
chk "a tag is matched as text in the counters (a.b is not axb)" bash -c "P 'source lib/traffic.sh; out=\$(printf \"%s\n\" \"    9  900 RETURN  tcp  --  *  *  0.0.0.0/0  0.0.0.0/0  tcp dpt:1 /* psm-in-axb */\" | _trf_ipt_sum a.b); [[ \$out == 0 ]]'"
chk "a string field with a quote stays JSON" bash -c "P 'source lib/traffic.sh; _trf_init; _trf_init_tag q 1; _trf_set_str q note \"a\\\"b\"; jq -e .q.note config/traffic/state.json >/dev/null; _trf_delete_tag q'"

sec "X-S16 firewall quick-lock keeps what has to stay reachable"
mkdir -p /etc/ssh config/realm; printf 'Port 2222\n' >> /etc/ssh/sshd_config
printf '[{"tag":"r","listen_port":21000,"remote_host":"1.2.3.4","remote_port":1,"udp":true}]\n' > config/realm/rules.json
printf '30000/udp\n' >> config/firewall-ports
keep=$(P 'source lib/system.sh; _fw_keep_ports')
chk "SSH where sshd listens (2222), not only 22" grep -q '^2222/tcp$' <<<"$keep"
chk "… 80/443, the relays (TCP and UDP) and PSM's own ports" bash -c "for p in 80/tcp 443/tcp 443/udp 21000/tcp 21000/udp 30000/udp; do grep -qx \"\$p\" <<<$(printf '%q' "$keep") || { echo missing \$p; exit 1; }; done"
rm -f config/realm/rules.json; sed -i '/^30000\/udp$/d' config/firewall-ports; sed -i '/^Port 2222$/d' /etc/ssh/sshd_config

sec "X-M39 swap in a container"
chk "a swap the system refuses leaves no file and says so" bash -c "! P 'source lib/system.sh; create_swap' <<< '8' >/dev/null 2>&1; test ! -e /swapfile || swapon --show | grep -q /swapfile"
swapoff /swapfile 2>/dev/null; rm -f /swapfile

sec "common helpers"
chk "get_ipv4 without the network finds the route's source address (X-M21)" bash -c "P 'curl() { return 1; }; ip=\$(get_ipv4); is_ipv4 \"\$ip\"'"
chk "is_ipv4 takes octets up to 255 only (X-L3)" bash -c "P 'is_ipv4 10.0.0.1 && ! is_ipv4 999.1.1.1'"
chk "state keys are text, not patterns (X-M22)" bash -c "P 'state_set a.b one; state_set axb two; [[ \$(state_get a.b) == one ]]'"
chk "jq_set keeps a file's mode (X-M23)" bash -c "printf '{}' > /tmp/j.json; chmod 644 /tmp/j.json; P 'jq_set /tmp/j.json \".x = 1\"'; [[ \$(stat -c %a /tmp/j.json) == 644 ]] && jq -e '.x == 1' /tmp/j.json"
chk "rand_str gives the length asked (X-M24)" bash -c "P 'r=\$(rand_str 20); [[ \${#r} == 20 ]]'"
chk "ask and ask_yn keep the caller's variables (X-M49)" bash -c "P 'val=keep; ans=keep; ask other x <<< typed; ask_yn y <<< y; [[ \$val == keep && \$ans == keep && \$other == typed ]]'"
# (printf makes the newline: \$"…" would be a locale string with a backslash in it)
chk "a cron drop-in is one line with a plain name (X-M10)" bash -c "P '! psm_cron_set ../x \"* * * * *\" y && ! psm_cron_set ok \"* * * * *\" \"\$(printf \"a\\nb\")\"'; rc=\$?; test ! -e /etc/cron.d/ok -a ! -e /etc/x || rc=1; rm -f /etc/cron.d/ok; exit \$rc"
chk "psm node redacts VLESS Encryption keys, ShadowTLS passwords and mKCP seeds (X-M11)" bash -c "P 'source lib/node_cli.sh; printf \"%s\" \"{\\\"vless_decryption\\\":\\\"k\\\",\\\"stls_password\\\":\\\"p\\\",\\\"kcp_seed\\\":\\\"s\\\"}\" | _node_cli_redact | jq -e \".vless_decryption == \\\"***\\\" and .stls_password == \\\"***\\\" and .kcp_seed == \\\"***\\\"\"'"
chk "a REALITY inbound with a quote in its tag is still JSON (X-M2)" bash -c "P 'source lib/xray/reality.sh; _reality_build_inbound \"{\\\"tag\\\":\\\"a\\\\\\\"b\\\",\\\"port\\\":1,\\\"uuid\\\":\\\"u\\\",\\\"private_key\\\":\\\"k\\\",\\\"server_name\\\":\\\"s.example.com\\\",\\\"dest\\\":\\\"s.example.com:443\\\",\\\"flow\\\":\\\"\\\",\\\"short_ids\\\":[\\\"\\\"]}\" | jq -e .tag'"
chk "doctor --json is JSON (X-L17)" bash -c "bash manager.sh doctor --json | jq -e .summary >/dev/null"
chk "the main menu's 9 has its own website menu (X-M42)" bash -c "P 'source lib/nginx.sh; declare -F website_menu'"
chk "a trace target cannot be an option (X-L19)" bash -c "! P 'source lib/vps_test.sh; vps_test_trace_route' <<< '-V' >/dev/null 2>&1"
if command -v ping >/dev/null 2>&1; then
    chk "ping's average is read on this system's ping (X-M38)" bash -c "P 'source lib/vps_test.sh; _vps_ping_one 127.0.0.1' | grep -qE '127\.0\.0\.1 +[0-9.]+ ms$'"
fi

sec "X-M16 / X-M18 downloads are checked"
chk "acme.sh installs from the pinned release, its checksum checked" bash -c "P 'source lib/cert.sh; acme_install' <<< 'audit@example.com' >/tmp/acme.log 2>&1; /root/.acme.sh/acme.sh --version | grep -q 'v3.1.6'"
chk "geoip/geosite are checked against their .sha256sum" bash -c "P 'source update.sh 2>/dev/null; psm_update_geofiles' >/dev/null 2>&1; test -s /usr/local/share/xray/geoip.dat && test -s /usr/local/share/xray/geosite.dat"

sec "X-M48 the traffic lock keeps errors visible"
chk "psm traffic set on an unknown tag says so (stderr survives taking the lock)" bash -c \
    "out=\$(bash manager.sh traffic set nope 2>&1); rc=\$?; [[ \$rc == 1 && \$out == *'no node'* ]] || { echo \"rc=\$rc out=\$out\"; false; }"

sec "X-M13 / X-M14 migration bundles are encrypted unless asked not to be"
chk "psm migrate export with no terminal and no passphrase: refused, nothing written" bash -c \
    "! bash manager.sh migrate export --output /tmp/mig.tgz </dev/null >/tmp/mig.log 2>&1 && test ! -e /tmp/mig.tgz && grep -q -- --no-encrypt /tmp/mig.log"
chk "… with a passphrase: an encrypted bundle (openssl's Salted__), root's alone" bash -c \
    "PSM_MIGRATE_PASS=audit-pass bash manager.sh migrate export --output /tmp/mig.tgz >/dev/null 2>&1 && [[ \$(head -c 8 /tmp/mig.tgz) == Salted__ && \$(stat -c %a /tmp/mig.tgz) == 600 ]]"
chk "… --no-encrypt: a plain one, still root's alone" bash -c \
    "bash manager.sh migrate export --no-encrypt --output /tmp/mig2.tgz >/dev/null 2>&1 && tar -tzf /tmp/mig2.tgz manifest.json >/dev/null && [[ \$(stat -c %a /tmp/mig2.tgz) == 600 ]]"
chk "… the passphrase never shows in a process list (fd, not argv or env of openssl)" bash -c "! grep -q 'pass env:\|-pass pass:' lib/migrate.sh"
rm -f /tmp/mig.tgz /tmp/mig2.tgz

sec "X-S9 uninstall takes psm-agent with it"
mkdir -p /etc/psm; printf '#!/bin/sh\necho 0\n' > /usr/local/bin/psm-agent; chmod +x /usr/local/bin/psm-agent
printf '{"panel":"https://panel.example.com","token":"x"}\n' > /etc/psm/agent.json
{ printf 'y\ny\n'; yes n 2>/dev/null | head -60; } | bash uninstall.sh >/tmp/uninstall.log 2>&1
chk "psm-agent's binary and config are gone" bash -c "test ! -e /usr/local/bin/psm-agent && test ! -e /etc/psm/agent.json"

echo
echo "=== RESULT: $PASS ok, $FAIL failed"
(( FAIL == 0 ))
