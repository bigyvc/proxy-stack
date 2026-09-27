#!/usr/bin/env bash
# psm relay between real machines, the way a user meets it:
#
#   tests/integration/relay.sh debian|ubuntu24|ubuntu22|alpine|rocky9|alma8
#
# Two servers of the family under test, each behind the firewall that family
# ships (ufw, firewalld, iptables default-deny) with only SSH let in: an entry
# and an exit, the exit also the landing machine (PSM with a sing-box SS2022
# node and a Hysteria2 node). Two plain targets (TCP and UDP echo naming
# themselves, and a bulk sender) stand for landing machines a relay spreads
# over. A client on its own machine reaches all of it only through the ports
# the relays open.
#
# realm and gost forwards (TCP and UDP, one target and several: round robin,
# client-IP hash, failover with health checks, a UDP session that keeps its
# port), gost's rate limit, the quota and the expiry of either engine, the
# tunnel over each transport with the exit's certificate pinned (a wrong pin,
# a wrong secret, an exit that is no open proxy), real proxy traffic through
# a forward and through a tunnel (SS2022 over TCP, Hysteria2 over UDP), ports
# picked in a range, a batch, moving a rule between engines, psm doctor, and
# nothing left behind when the rules go.
set -uo pipefail
os="${1:?usage: $0 debian|ubuntu24|ubuntu22|alpine|rocky9|alma8}"
source "$(dirname "${BASH_SOURCE[0]}")/container.sh"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
sec() { echo; echo "=== $1"; }
chk() { local n="$1"; shift; if "$@" >/tmp/relay-chk.$$ 2>&1; then ok "$n"; else bad "$n"; tail -8 /tmp/relay-chk.$$ | sed 's/^/       /'; fi; }
wait_for() {   # <seconds> <command…>: until it succeeds
    local end=$((SECONDS + $1)); shift
    until "$@" >/dev/null 2>&1; do (( SECONDS < end )) || return 1; sleep 2; done
}

NET="psm-rl-$$"; EN="psm-rl-entry-$$"; EX="psm-rl-exit-$$"; T1="psm-rl-t1-$$"; T2="psm-rl-t2-$$"; CL="psm-rl-cl-$$"
cleanup() { docker rm -f "$EN" "$EX" "$T1" "$T2" "$CL" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; rm -f /tmp/relay-chk.$$ /tmp/relay-exit.$$; true; }
trap cleanup EXIT
docker network create "$NET" >/dev/null
ipof() { docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$1"; }

# psm on a server; the output of --json commands on stdout, their errors on stderr
pe() { docker exec -i "$EN" bash /opt/psm/manager.sh "$@"; }
px() { docker exec -i "$EX" bash /opt/psm/manager.sh "$@"; }
# the client: which target answered through HOST:PORT. A target answers
# "<name>-<what the client sent>", so only a hop that carries the client's
# bytes as well as the answer reads as the target's name: a tunnel that lost
# them (gost's relay nodelay did) answers "t1-" and fails every check.
tcp() {
    local r; r=$(docker exec "$CL" sh -c "(echo hi; sleep 1) | timeout 6 socat -t1 - TCP:$1:$2 2>/dev/null" | tr -d '\n')
    [[ "$r" == *-hi ]] && r=${r%-hi}
    printf '%s' "$r"
}
udp() { docker exec "$CL" python3 /root/uclient.py "$1" "$2" "${3:-1}" "${4:-0.5}"; }
many() { local i out=""; for ((i = 0; i < $3; i++)); do out+="$(tcp "$1" "$2")."; done; printf '%s' "$out"; }

fw_name() { case "$1" in debian|ubuntu*) echo ufw ;; rocky9|alma8) echo firewalld ;; *) echo iptables ;; esac; }
fw_on() {   # <container>: SSH in, nothing else
    case "$(fw_name "$os")" in
        ufw) docker exec "$1" bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null && ufw default deny incoming && ufw allow 22/tcp && ufw --force enable' ;;
        firewalld) docker exec "$1" bash -c 'dnf -y -q install firewalld >/dev/null && systemctl enable --now firewalld && firewall-cmd --state' ;;
        iptables) docker exec "$1" sh -c 'apk add -q --no-cache iptables ip6tables >/dev/null && for t in iptables ip6tables; do $t -A INPUT -i lo -j ACCEPT && $t -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT && $t -P INPUT DROP || exit 1; done' ;;
    esac
}
allowed() {   # <container> <port> <tcp|udp>: PSM's own reading of the firewall
    docker exec "$1" bash -c "PSM_ROOT=/opt/psm LIB_DIR=/opt/psm/lib; source /opt/psm/lib/common.sh >/dev/null 2>&1; source /opt/psm/lib/system.sh; firewall_port_allowed $2 $3"
}
listening() {   # <container> <tcp|udp> <port>
    local hex; hex=$(printf '%04X' "$3")
    docker exec "$1" sh -c "cat /proc/net/${2} /proc/net/${2}6 2>/dev/null" \
        | awk -v p=":${hex}\$" -v t="$2" '(t == "udp" || $4 == "0A") && toupper($2) ~ p { f = 1 } END { exit !f }'
}

sec "$os: the machines"
it_start "$os" "$EN" && docker network connect "$NET" "$EN"
it_start "$os" "$EX" && docker network connect "$NET" "$EX"
for c in "$T1" "$T2"; do
    docker run -d --init --name "$c" --hostname "$c" --network "$NET" alpine:3.22 sleep infinity >/dev/null
    docker exec "$c" apk add -q --no-cache socat python3 >/dev/null
done
# the client: a Debian machine with its own sing-box, whatever the servers run
docker image inspect psm-rl-client:1 >/dev/null 2>&1 || docker build -q -t psm-rl-client:1 - >/dev/null <<'EOF'
FROM debian:13
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat python3 curl jq ca-certificates procps >/dev/null \
 && curl -fsSL --retry 3 https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-linux-amd64.tar.gz \
    | tar -xz -C /tmp && install -m 755 /tmp/sing-box-1.14.2-linux-amd64/sing-box /usr/local/bin/sing-box && rm -rf /tmp/sing-box-* \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
EOF
docker run -d --init --name "$CL" --hostname "$CL" --network "$NET" psm-rl-client:1 sleep infinity >/dev/null
cat > /tmp/relay-uecho.$$ <<'EOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 9000))
while True:
    d, a = s.recvfrom(65535)
    s.sendto(("%s %d\n" % (sys.argv[1], a[1])).encode(), a)
EOF
cat > /tmp/relay-uclient.$$ <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
host, port, n, gap = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
out = []
for i in range(n):
    s.sendto(b"x", (host, port))
    try: out.append(s.recvfrom(100)[0].decode().strip())
    except Exception: out.append("timeout")
    time.sleep(gap)
print("|".join(out))
EOF
t_start() {   # <container> <name>: the echoes and the bulk sender
    docker exec -d "$1" socat TCP-LISTEN:9000,fork,reuseaddr SYSTEM:"read l; echo $2-\$l"
    docker exec -d "$1" python3 /root/uecho.py "$2"
    docker exec -d "$1" socat TCP-LISTEN:9100,fork,reuseaddr SYSTEM:"head -c 5000000 /dev/zero"
}
for c in "$T1" "$T2"; do docker cp /tmp/relay-uecho.$$ "$c":/root/uecho.py; done
docker cp /tmp/relay-uclient.$$ "$CL":/root/uclient.py
rm -f /tmp/relay-uecho.$$ /tmp/relay-uclient.$$
t_start "$T1" t1; t_start "$T2" t2
IE=$(ipof "$EN"); IX=$(ipof "$EX"); I1=$(ipof "$T1"); I2=$(ipof "$T2")
sleep 1
chk "the targets answer directly with what they were sent (t1 $I1, t2 $I2)" bash -c "[[ \$(docker exec $CL sh -c '(echo hi; sleep 1) | timeout 5 socat -t1 - TCP:$I1:9000') == t1-hi ]]"

for c in "$EN" "$EX"; do
    it_copy_tree "$c"
    chk "PSM installed on $c" docker exec "$c" bash -c 'cd /opt/psm && printf "1\n0\n0\n0\n0\n" | timeout 900 bash install.sh >/root/install.log 2>&1; tail -2 /root/install.log; command -v jq'
    chk "$(fw_name "$os") on $c lets in SSH and nothing else" fw_on "$c"
done
chk "the firewall holds: the client cannot reach a closed port on the entry" bash -c "[[ -z \$(docker exec $CL sh -c '(echo hi; sleep 1) | timeout 5 socat -t1 - TCP:$IE:9000 2>/dev/null') ]]"

sec "$os: the landing (on the exit machine): sing-box SS2022 and Hysteria2 nodes"
chk "sing-box" px core install sing-box --if-missing --json
chk "an SS2022 node on 30010 (TCP + UDP)" px node add sing-box ss2022 --tag land-ss --port 30010 --json
chk "a Hysteria2 node on 30011 (UDP)" px node add sing-box hysteria2 --tag land-hy --port 30011 --json
chk "sing-box on the client" docker exec "$CL" sing-box version
# through <node tag> <host> <port>: the client reaches the internet with that node, dialled at host:port
through() {
    local ob; ob=$(px node export "$1" --format singbox --server "$2" 2>/dev/null) || { echo "no export for $1"; return 1; }
    ob=$(jq -c --argjson p "$3" '.server_port = $p | .tag = "proxy"' <<<"$ob")
    docker exec -i "$CL" sh -c 'cat > /root/sb.json' < <(jq -n --argjson o "$ob" '{log: {level: "warn"},
        inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: 18080}], outbounds: [$o], route: {final: "proxy"}}')
    docker exec "$CL" sh -c 'sing-box run -c /root/sb.json > /root/sb.log 2>&1 & pid=$!; sleep 3; code=000
        for i in 1 2 3; do code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -x socks5h://127.0.0.1:18080 https://www.gstatic.com/generate_204); [ "$code" = 204 ] && break; sleep 2; done
        kill $pid; [ "$code" = 204 ] || { echo "HTTP $code"; tail -5 /root/sb.log; exit 1; }'
}
chk "the client reaches the internet through the SS2022 node itself" through land-ss "$IX" 30010

sec "$os: realm forwards"
chk "realm: one target, TCP and UDP" pe relay add --tag r1 --listen-port 21001 --target "$I1:9000" --udp --json
chk "… the client gets t1 over TCP" test "$(tcp "$IE" 21001)" = t1
chk "… and over UDP" bash -c "[[ \$(docker exec $CL python3 /root/uclient.py $IE 21001 1 0) == t1\ * ]]"
chk "… 21001 open in $(fw_name "$os") for TCP and UDP" bash -c "$(declare -f allowed); os=$os; allowed $EN 21001 tcp && allowed $EN 21001 udp"
chk "realm: two targets, round robin" pe relay add --tag r2 --listen-port 21002 --target "$I1:9000" --target "$I2:9000" --json
chk "… connections alternate between t1 and t2" bash -c "o=\$($(declare -f tcp many); CL=$CL; many $IE 21002 4); [[ \$o == t1.t2.t1.t2. || \$o == t2.t1.t2.t1. ]] || { echo \$o; false; }"
chk "realm: client-IP hash keeps one client on one target" pe relay update r2 --strategy hash --json
chk "… four connections, one target" bash -c "o=\$($(declare -f tcp many); CL=$CL; many $IE 21002 4); [[ \$o == t1.t1.t1.t1. || \$o == t2.t2.t2.t2. ]] || { echo \$o; false; }"
chk "realm has no failover: --strategy fifo is refused (exit 2) with the reason" bash -c "out=\$(docker exec $EN bash /opt/psm/manager.sh relay update r2 --strategy fifo --json 2>&1); rc=\$?; [[ \$rc == 2 && \$out == *'--engine gost'* ]] || { echo \"\$rc \$out\"; false; }"
chk "realm has no rate limit: --speed is refused" bash -c "! docker exec $EN bash /opt/psm/manager.sh relay update r2 --speed 5 --json 2>/dev/null"
chk "a realm forward to the SS2022 node" pe relay add --tag r-ss --listen-port 21010 --target "$IX:30010" --json
chk "… the client reaches the internet through it (TCP)" through land-ss "$IE" 21010
chk "a realm forward to the Hysteria2 node, UDP" pe relay add --tag r-hy --listen-port 21011 --target "$IX:30011" --udp --json
chk "… the client reaches the internet through it (QUIC over UDP)" through land-hy "$IE" 21011
nofw_shut() { listening "$EN" tcp 21099 && [[ -z "$(tcp "$IE" 21099)" ]]; }
chk "a relay made with --no-firewall" pe relay add --tag nf --listen-port 21099 --target "$I1:9000" --no-firewall --json
chk "… listens, and the firewall keeps the client out" nofw_shut
pe relay delete nf --yes --json >/dev/null

sec "$os: gost forwards"
chk "gost: two targets, failover (the first that answers) with health checks" pe relay add --tag g1 --engine gost --listen-port 22001 --target "$I1:9000" --target "$I2:9000" --strategy fifo --udp --json
chk "… psm-gost installed and running" docker exec "$EN" sh -c 'test -x /usr/local/bin/psm-gost && /usr/local/bin/psm-gost -V | grep -q "gost v3"'
chk "… every connection goes to t1 while it answers" bash -c "o=\$($(declare -f tcp many); CL=$CL; many $IE 22001 3); [[ \$o == t1.t1.t1. ]] || { echo \$o; false; }"
docker exec "$T1" sh -c 'pkill -f "TCP-LISTEN:9000"'
sleep 20   # the next probe (every 15 s) marks t1 down
chk "… t1 down: every connection goes to t2, none fails" bash -c "o=\$($(declare -f tcp many); CL=$CL; many $IE 22001 4); [[ \$o == t2.t2.t2.t2. ]] || { echo \$o; false; }"
docker exec -d "$T1" socat TCP-LISTEN:9000,fork,reuseaddr SYSTEM:"read l; echo t1-\$l"
chk "… t1 back: connections return to it" wait_for 40 bash -c "[[ \$($(declare -f tcp); CL=$CL; tcp $IE 22001) == t1 ]]"
chk "… probe reports each target" bash -c "pe() { docker exec -i $EN bash /opt/psm/manager.sh \"\$@\"; }; pe relay probe g1 --json | jq -e '.items[0].targets | length == 2 and all(.[]; .rtt_ms != null)'"
chk "gost: round robin" pe relay update g1 --strategy round --json
chk "… connections alternate" bash -c "o=\$($(declare -f tcp many); CL=$CL; many $IE 22001 4); [[ \$o == t1.t2.t1.t2. || \$o == t2.t1.t2.t1. ]] || { echo \$o; false; }"
chk "gost UDP: one client session keeps one source port at the target (QUIC needs it)" bash -c "o=\$(docker exec $CL python3 /root/uclient.py $IE 22001 4 1.5); a=\$(tr '|' '\n' <<<\"\$o\" | sort -u | wc -l); [[ \$a == 1 && \$o != *timeout* ]] || { echo \$o; false; }"
chk "gost: a 8 Mbit/s limit" pe relay add --tag g-speed --engine gost --listen-port 22002 --target "$I1:9100" --speed 8 --json
speed_secs() {   # seconds for the 5 MB from the bulk sender through PORT
    local s e; s=$(date +%s.%N); docker exec "$CL" sh -c "timeout 60 socat -u TCP:$IE:$1 - | wc -c" >/dev/null; e=$(date +%s.%N)
    awk -v s="$s" -v e="$e" 'BEGIN { printf "%.0f", e - s }'
}
t=$(speed_secs 22002)
[[ "$t" -ge 4 ]] && ok "… 5 MB take ${t} s (8 Mbit/s = 1 MB/s)" || bad "… 5 MB took ${t} s at 8 Mbit/s"
pe relay update g-speed --speed 0 --json >/dev/null
t=$(speed_secs 22002)
[[ "$t" -le 2 ]] && ok "… without the limit ${t} s" || bad "… without the limit ${t} s"

sec "$os: quota and expiry"
chk "a realm forward with a 300 kB quota" pe relay add --tag q1 --listen-port 23001 --target "$I1:9100" --limit-bytes 300000 --reset-day 1 --json
chk "… the traffic timer is on" docker exec "$EN" sh -c 'systemctl is-active --quiet psm-traffic.timer 2>/dev/null || test -f /etc/cron.d/psm-traffic'
docker exec "$CL" sh -c "timeout 20 socat -u TCP:$IE:23001 - | wc -c" >/dev/null
docker exec "$EN" bash /opt/psm/manager.sh --traffic-check >/dev/null 2>&1
chk "… over quota: the periodic check pauses it" bash -c "docker exec $EN bash /opt/psm/manager.sh relay show q1 --json | jq -e '.item.paused == true and .item.pause_reason == \"quota\" and .item.used_bytes >= 300000'"
chk "… the client is refused" bash -c "[[ -z \$(docker exec $CL sh -c 'timeout 5 socat -u TCP:$IE:23001 - 2>/dev/null | head -c 10') ]]"
chk "… raising the quota lifts the pause" pe relay update q1 --limit-gb 1 --json
chk "… the client gets through again" bash -c "[[ \$(docker exec $CL sh -c 'timeout 10 socat -u TCP:$IE:23001 - | wc -c') -gt 1000 ]]"
chk "a gost forward that has already expired is paused at once" pe relay add --tag x1 --engine gost --listen-port 23002 --target "$I1:9000" --expires 2020-01-01 --json
chk "… expired, the client is refused" bash -c "docker exec $EN bash /opt/psm/manager.sh relay show x1 --json | jq -e '.item.paused and .item.pause_reason == \"expired\"' && [[ -z \$($(declare -f tcp); CL=$CL; tcp $IE 23002) ]]"
chk "… a new date lets it through" bash -c "docker exec $EN bash /opt/psm/manager.sh relay update x1 --expires 2099-12-31 --json >/dev/null && [[ \$($(declare -f tcp); CL=$CL; tcp $IE 23002) == t1 ]]"
soon=$(date -u -d '+50 seconds' +%Y-%m-%dT%H:%M:%SZ)
chk "an expiry 50 s ahead" pe relay update x1 --expires "$soon" --json
chk "… works until then" test "$(tcp "$IE" 23002)" = t1
sleep 55
docker exec "$EN" bash /opt/psm/manager.sh --traffic-check >/dev/null 2>&1
chk "… after it, the periodic check pauses it" bash -c "docker exec $EN bash /opt/psm/manager.sh relay show x1 --json | jq -e '.item.paused and .item.pause_reason == \"expired\"' && [[ -z \$($(declare -f tcp); CL=$CL; tcp $IE 23002) ]]"
chk "… never lifts it" bash -c "docker exec $EN bash /opt/psm/manager.sh relay update x1 --expires never --json >/dev/null && [[ \$($(declare -f tcp); CL=$CL; tcp $IE 23002) == t1 ]]"

sec "$os: tunnels, entry → exit → landing"
tport=24000; n=0
for tr in tls mtls wss mwss; do
    n=$((n + 1)); tport=$((24000 + n)); eport=$((25000 + n))
    extra=(); xpath=()
    [[ "$tr" == *ws* ]] && { extra=(--ws-path "/cdn$n" --ws-host "cdn$n.example.com"); xpath=(--ws-path "/cdn$n"); }
    out=$(px relay add --tag "tun-$tr" --mode tunnel-exit --listen-port "$tport" --transport "$tr" --tls-sni "www.example.com" \
        --target "$I1:9000" "${xpath[@]}" --json 2>/tmp/relay-exit.$$)
    secret=$(jq -r '.item.secret // empty' <<<"$out" 2>/dev/null); pin=$(jq -r '.item.cert_sha256 // empty' <<<"$out" 2>/dev/null)
    [[ -n "$secret" && ${#pin} == 64 ]] && ok "$tr: the exit ($tport) with its secret and certificate" \
        || { bad "$tr: the exit: $out $(tail -3 /tmp/relay-exit.$$)"; continue; }
    chk "$tr: … its port open (TCP only: UDP travels in the tunnel)" bash -c "$(declare -f allowed); allowed $EX $tport tcp"
    chk "$tr: the entry pins the exit's certificate (fetched and checked against the SHA-256)" \
        pe relay add --tag "tun-$tr" --mode tunnel-entry --listen-port "$eport" --exit "$IX:$tport" --transport "$tr" \
            --tls-sni www.example.com --secret "$secret" --exit-pin "$pin" --udp "${extra[@]}" --json
    chk "$tr: TCP through the tunnel reaches the landing" wait_for 20 bash -c "[[ \$($(declare -f tcp); CL=$CL; tcp $IE $eport) == t1 ]]"
    chk "$tr: UDP through the tunnel, one session" bash -c "o=\$(docker exec $CL python3 /root/uclient.py $IE $eport 3 1); [[ \$o == t1* && \$o != *timeout* && \$(tr '|' '\n' <<<\"\$o\" | sort -u | wc -l) == 1 ]] || { echo \$o; false; }"
done
chk "a wrong pin is refused before anything is written (exit 1)" bash -c "out=\$(docker exec $EN bash /opt/psm/manager.sh relay add --tag tun-bad --mode tunnel-entry --listen-port 25101 --exit $IX:24001 --secret ${secret:-x} --exit-pin $(printf '0%.0s' {1..64}) --json 2>&1); rc=\$?; [[ \$rc == 1 && \$out == *'not 0000'* ]] && ! docker exec $EN bash /opt/psm/manager.sh relay show tun-bad >/dev/null 2>&1 || { echo \"\$rc \$out\"; false; }"
xs=$(px relay show tun-tls --json | jq -r '.item.secret'); xpin=$(px relay show tun-tls --json | jq -r '.item.cert_sha256')
chk "an entry with the wrong secret gets nothing through" bash -c "docker exec -i $EN bash /opt/psm/manager.sh relay add --tag tun-sec --mode tunnel-entry --listen-port 25102 --exit $IX:24001 --secret wrong-secret-123 --exit-pin $xpin --json >/dev/null && [[ -z \$($(declare -f tcp); CL=$CL; tcp $IE 25102) ]]"
# a relay client of its own on the entry machine, answered through bash's
# /dev/tcp (the servers have neither nc nor socat)
open_relay() {
    docker exec -d "$EN" /usr/local/bin/psm-gost -L "tcp://127.0.0.1:39999/$I2:9000" -F "relay+tls://tun-tls:$xs@$IX:24001?secure=false"
    sleep 2
    [[ "$(docker exec "$EN" bash -c 'exec 3<>/dev/tcp/127.0.0.1/39999; echo hi >&3; timeout 3 cat <&3')" == t1-hi ]]
}
chk "the exit is no open proxy: a relay client asking it for t2 gets the exit's own target, t1 (both ways)" open_relay
docker exec "$EN" pkill -f 'tcp://127.0.0.1:3999[9]' 2>/dev/null
chk "the client reaches the internet: SS2022 through a TLS tunnel (exit → its own node on 127.0.0.1)" bash -c "
    set -e; o=\$(docker exec -i $EX bash /opt/psm/manager.sh relay add --tag tun-ss --mode tunnel-exit --listen-port 24010 --target 127.0.0.1:30010 --json 2>/dev/null)
    s=\$(jq -r .item.secret <<<\"\$o\"); p=\$(jq -r .item.cert_sha256 <<<\"\$o\")
    docker exec -i $EN bash /opt/psm/manager.sh relay add --tag tun-ss --mode tunnel-entry --listen-port 25010 --exit $IX:24010 --secret \$s --exit-pin \$p --json >/dev/null
    $(declare -f through px); EX=$EX CL=$CL; through land-ss $IE 25010"
chk "… and Hysteria2 (QUIC) over UDP through an mWSS tunnel" bash -c "
    set -e; o=\$(docker exec -i $EX bash /opt/psm/manager.sh relay add --tag tun-hy --mode tunnel-exit --listen-port 24011 --transport mwss --target 127.0.0.1:30011 --json 2>/dev/null)
    s=\$(jq -r .item.secret <<<\"\$o\"); p=\$(jq -r .item.cert_sha256 <<<\"\$o\")
    docker exec -i $EN bash /opt/psm/manager.sh relay add --tag tun-hy --mode tunnel-entry --listen-port 25011 --transport mwss --exit $IX:24011 --secret \$s --exit-pin \$p --udp --json >/dev/null
    $(declare -f through px); EX=$EX CL=$CL; through land-hy $IE 25011"

sec "$os: ports, batches, engines"
chk "--listen-port auto picks a free port in --port-range" bash -c "p=\$(docker exec -i $EN bash /opt/psm/manager.sh relay add --tag a1 --listen-port auto --port-range 26000-26010 --target $I1:9000 --json | jq -r .item.listen_port); (( p >= 26000 && p <= 26010 )) && [[ \$($(declare -f tcp); CL=$CL; tcp $IE \$p) == t1 ]]"
docker exec -d "$EN" /usr/local/bin/psm-gost -L tcp://:26020/127.0.0.1:1   # something else on 26020
sleep 1
chk "… a port something else holds is passed over (the hint 26020 is taken)" bash -c "p=\$(docker exec -i $EN bash /opt/psm/manager.sh relay add --tag a2 --listen-port auto --port-range 26020-26021 --target $I1:9000 --json | jq -r .item.listen_port); [[ \$p == 26021 ]] || { echo \$p; false; }"
printf 'b1 27001 %s:9000\nb2 auto %s:9000,%s:9000\n# a comment\nb3 70000 %s:9000\n' "$I1" "$I1" "$I2" "$I1" > /tmp/relay-batch.$$
docker cp /tmp/relay-batch.$$ "$EN":/root/batch.txt; rm -f /tmp/relay-batch.$$
out=$(pe relay add --batch /root/batch.txt --engine gost --json 2>/dev/null); rc=$?
chk "a batch: two made, the bad line reported by number (exit 1)" bash -c "[[ $rc == 1 ]] && jq -e '(.items | map(.tag)) == [\"b1\", \"b2\"] and (.failed | length == 1 and .[0].line == 4)' <<<'$out'"
chk "… both answer" bash -c "b2=\$(docker exec $EN bash /opt/psm/manager.sh relay show b2 --json | jq -r .item.listen_port); [[ \$($(declare -f tcp); CL=$CL; tcp $IE 27001) == t1 && -n \$($(declare -f tcp); CL=$CL; tcp $IE \$b2) ]]"
chk "a realm rule moves to gost on its own port" pe relay update r1 --engine gost --json
chk "… and still answers (TCP and UDP)" bash -c "[[ \$($(declare -f tcp); CL=$CL; tcp $IE 21001) == t1 ]] && [[ \$(docker exec $CL python3 /root/uclient.py $IE 21001 1 0) == t1\ * ]]"
chk "psm relay list shows both engines and the tunnels" bash -c "docker exec $EN bash /opt/psm/manager.sh relay list | grep -q 'tunnel-entry' && docker exec $EN bash /opt/psm/manager.sh relay list | grep -qE '^r2 +realm'"

sec "$os: psm doctor"
chk "every relay listening: ok" bash -c "docker exec $EN bash /opt/psm/manager.sh doctor --json | jq -e '.checks[] | select(.id == \"relay.listen\") | .status == \"ok\"'"
docker exec "$EN" sh -c 'if command -v systemctl >/dev/null && [ -d /run/systemd/system ]; then systemctl stop psm-gost; else rc-service psm-gost stop; fi' >/dev/null 2>&1
chk "gost stopped: a warning naming the relays" bash -c "docker exec $EN bash /opt/psm/manager.sh doctor --json | jq -e '.checks[] | select(.id == \"relay.listen\") | .status == \"warning\"'"
chk "… psm doctor --fix starts it again" bash -c "docker exec $EN bash /opt/psm/manager.sh doctor --fix --json >/dev/null 2>&1; docker exec $EN bash /opt/psm/manager.sh doctor --json | jq -e '.checks[] | select(.id == \"relay.listen\") | .status == \"ok\"'"

sec "$os: taking it all away"
for c in "$EN" "$EX"; do
    for t in $(docker exec "$c" bash /opt/psm/manager.sh relay list --json | jq -r '.items[].tag'); do
        docker exec "$c" bash /opt/psm/manager.sh relay delete "$t" --yes --json >/dev/null 2>&1 || bad "delete $t on $c"
    done
done
chk "no rules left on either machine" bash -c "for c in $EN $EX; do [[ \$(docker exec \$c bash /opt/psm/manager.sh relay list --json | jq .count) == 0 ]] || exit 1; done"
docker exec "$EN" pkill -f 'tcp://:2602[0]' 2>/dev/null
chk "realm and psm-gost stopped" bash -c "for c in $EN $EX; do docker exec \$c sh -c '! pgrep -x realm && ! pgrep -f /usr/local/bin/psm-gos[t]' || exit 1; done"
chk "the ports PSM opened are closed again (21001, 22001, 24001)" bash -c "$(declare -f allowed); ! allowed $EN 21001 tcp && ! allowed $EN 22001 tcp && ! allowed $EX 24001 tcp"
chk "no counting or pause rules left for a relay" bash -c "for c in $EN $EX; do docker exec \$c sh -c 'iptables -t mangle -S 2>/dev/null; iptables -S 2>/dev/null' | grep -E 'psm-(in|out)-relay-|dport 2(1|2|3)0' && exit 1; done; true"
chk "the SS2022 node on the exit is untouched" bash -c "$(declare -f listening); listening $EX tcp 30010"

echo
echo "=== RESULT ($os): $pass ok, $fail failed"
(( fail == 0 ))
