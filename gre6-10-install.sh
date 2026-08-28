#!/usr/bin/env bash
set -Eeuo pipefail

# gre6-10-install.sh
# One script, two roles:
#   server: Linode VPS
#   client: local Debian mini host
#
# The design:
#   - 10 IPv6 endpoints from one routed /64
#   - 10 keyed IPv6 GRE tunnels
#   - dynamic home IPv6 learner on VPS
#   - per-source IPv6 policy routing + explicit /128 route on VPS
#   - RTT selector on client
#   - per-source IPv4 policy tables on client to keep existing SS flows on old GRE
#   - Shadowsocks-Rust server on VPS, tcp_and_udp
#   - optional client OUTPUT IPv6 lock: only Linode /64 + essential ICMPv6/link-local/multicast

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行"

ROLE="${1:-}"
case "$ROLE" in
  server|client) shift ;;
  -h|--help|"") ROLE="" ;;
  *) die "第一个参数必须是 server 或 client" ;;
esac

usage() {
cat <<'EOF'
用法：

  服务端（Linode）：
    bash gre6-10-install.sh server \
      --prefix 2600:3c0c:e001:56::/64 \
      --tag sg \
      --inner-base 10.34 \
      --loopback 10.255.255.2 \
      --client-table-base 270 \
      --vps-table-base 380 \
      --switch-delta 5

  客户端（本地 Debian）：
    bash gre6-10-install.sh client \
      --prefix 2600:3c0c:e001:56::/64 \
      --tag sg \
      --inner-base 10.34 \
      --loopback 10.255.255.2 \
      --client-table-base 270 \
      --vps-table-base 380 \
      --switch-delta 5 \
      --token-file /root/gre10-sg.token

常用参数：
  --prefix             Linode 路由到本实例的 IPv6 /64（必填）
  --tag                短标签，例如 ty2、sg（默认 gre）
  --inner-base         GRE 内层 IPv4 前两段，例如 10.33 或 10.34
  --loopback           VPS 稳定 Loopback IPv4，例如 10.255.255.1
  --ss-port            Shadowsocks 端口（默认 8388）
  --client-table-base  本地策略表基数；实际用 base+1 ... base+10
  --vps-table-base     VPS IPv6 策略表基数；实际用 base+1 ... base+10
  --switch-delta       selector 切换阈值，单位 ms（默认 5）
  --max-rtt            最大优先 RTT，单位 ms（默认 140）
  --confirm-count      连续确认次数（默认 2）
  --token-file         共享 GRE token 文件
  --wan-iface          VPS IPv6 出口网卡；默认自动检测
  --gateway6           VPS IPv6 网关；默认从 default route 自动检测
  --no-ipv6-lock       client 不启用“仅允许到 Linode /64 的本机公网 IPv6”限制
  --help               显示帮助

Token：
  server 若未提供 --token-file/GRE10_TOKEN，会自动生成：
      /root/gre10-<tag>.token
  然后用 scp 把这个文件复制到 client，再以 --token-file 指定。
  不要把 token 发到聊天或公开位置。

注意：
  1. 本脚本不会修改 IPv4/IPv6 默认路由。
  2. 不修改 DHCP、LAN 网关。
  3. client 的 IPv6 lock 只限制“本机 OUTPUT 的公网 IPv6”，不碰 FORWARD。
  4. ICMPv6、link-local、multicast 会保留，否则 IPv6 ND/RA/PMTUD 会坏。
EOF
}

if [[ -z "$ROLE" ]]; then
  usage
  exit 0
fi

PREFIX=""
TAG="gre"
INNER_BASE="10.34"
LOOPBACK="10.255.255.2"
SS_PORT="8388"
CLIENT_TABLE_BASE="270"
VPS_TABLE_BASE="380"
SWITCH_DELTA="5"
MAX_RTT="140"
CONFIRM_COUNT="2"
TOKEN_FILE=""
WAN_IF=""
GW6=""
LOCK_IPV6="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --inner-base) INNER_BASE="$2"; shift 2 ;;
    --loopback) LOOPBACK="$2"; shift 2 ;;
    --ss-port) SS_PORT="$2"; shift 2 ;;
    --client-table-base) CLIENT_TABLE_BASE="$2"; shift 2 ;;
    --vps-table-base) VPS_TABLE_BASE="$2"; shift 2 ;;
    --switch-delta) SWITCH_DELTA="$2"; shift 2 ;;
    --max-rtt) MAX_RTT="$2"; shift 2 ;;
    --confirm-count) CONFIRM_COUNT="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --wan-iface) WAN_IF="$2"; shift 2 ;;
    --gateway6) GW6="$2"; shift 2 ;;
    --no-ipv6-lock) LOCK_IPV6="0"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -n "$PREFIX" ]] || die "--prefix 必填"
[[ "$TAG" =~ ^[A-Za-z0-9_]{1,8}$ ]] || die "--tag 只能是 1-8 位字母/数字/下划线"
[[ "$INNER_BASE" =~ ^10\.[0-9]{1,3}$ ]] || die "--inner-base 格式应类似 10.34"
[[ "$CLIENT_TABLE_BASE" =~ ^[0-9]+$ ]] || die "--client-table-base 必须是整数"
[[ "$VPS_TABLE_BASE" =~ ^[0-9]+$ ]] || die "--vps-table-base 必须是整数"
[[ "$SS_PORT" =~ ^[0-9]+$ ]] || die "--ss-port 必须是整数"

PREFIX_TAG="$(echo "$TAG" | tr '[:upper:]' '[:lower:]')"
IF_PREFIX="${PREFIX_TAG}g"
ETC_DIR="/etc/gre10-${PREFIX_TAG}"
RUN_DIR="/run/gre10-${PREFIX_TAG}"
CONF="${ETC_DIR}/gre.conf"
REMOTE_DIR="${ETC_DIR}/remotes"
TOKEN_DEFAULT="/root/gre10-${PREFIX_TAG}.token"
LOOPBACK_SAFE="${LOOPBACK//\//_}"

export DEBIAN_FRONTEND=noninteractive
log "安装依赖"
apt-get update -y
apt-get install -y iproute2 iputils-ping python3 curl xz-utils ca-certificates util-linux nftables

mkdir -p "$ETC_DIR" "$RUN_DIR" "$REMOTE_DIR"
chmod 700 "$ETC_DIR" "$REMOTE_DIR"

# Token handling
if [[ -n "$TOKEN_FILE" ]]; then
  [[ -s "$TOKEN_FILE" ]] || die "token 文件不存在或为空: $TOKEN_FILE"
  GRE_TOKEN="$(cat "$TOKEN_FILE")"
elif [[ -n "${GRE10_TOKEN:-}" ]]; then
  GRE_TOKEN="$GRE10_TOKEN"
elif [[ "$ROLE" == "server" ]]; then
  if [[ ! -s "$TOKEN_DEFAULT" ]]; then
    python3 - <<PY >"$TOKEN_DEFAULT"
import secrets
print(secrets.token_hex(32))
PY
    chmod 600 "$TOKEN_DEFAULT"
  fi
  GRE_TOKEN="$(cat "$TOKEN_DEFAULT")"
  TOKEN_FILE="$TOKEN_DEFAULT"
else
  die "client 需要 --token-file，或设置 GRE10_TOKEN 环境变量"
fi

# Generate endpoint/key config deterministically from prefix + token.
python3 - "$PREFIX" "$GRE_TOKEN" "$CONF" <<'PY'
import hashlib, ipaddress, sys, pathlib
prefix, token, path = sys.argv[1:]
net = ipaddress.IPv6Network(prefix, strict=False)
if net.prefixlen != 64:
    raise SystemExit("目前脚本要求 /64")
rows = []
for i in range(1, 11):
    ip = ipaddress.IPv6Address(int(net.network_address) + i)
    key = int.from_bytes(hashlib.sha256(f"{token}:{i}".encode()).digest()[:4], "big")
    if key == 0:
        key = i
    rows.append(f"{i}|{ip}|{key}")
pathlib.Path(path).write_text("\n".join(rows) + "\n")
PY
chmod 600 "$CONF"

install_ssrust() {
  local want="${1:-server}"
  local tmp arch match url

  if [[ "$(uname -m)" == "x86_64" ]]; then
    arch="x86_64"
  elif [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
    arch="aarch64"
  else
    die "暂不支持架构: $(uname -m)"
  fi

  match="${arch}-unknown-linux-musl.tar.xz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
    -o "$tmp/release.json"

  url="$(python3 - "$tmp/release.json" "$match" <<'PY'
import json,sys
p, match = sys.argv[1:]
d=json.load(open(p))
for a in d.get("assets", []):
    n=a.get("name","")
    if n.endswith(match):
        print(a["browser_download_url"])
        break
PY
)"
  [[ -n "$url" ]] || die "找不到官方 Shadowsocks-Rust musl 构建: $match"

  curl -fL "$url" -o "$tmp/ss.tar.xz"
  tar -xJf "$tmp/ss.tar.xz" -C "$tmp"

  if [[ "$want" == "server" ]]; then
    [[ -x "$tmp/ssserver" ]] || die "压缩包里没有 ssserver"
    install -m 0755 "$tmp/ssserver" /usr/local/bin/ssserver
  else
    [[ -x "$tmp/sslocal" ]] || die "压缩包里没有 sslocal"
    install -m 0755 "$tmp/sslocal" /usr/local/bin/sslocal
  fi
}

if [[ "$ROLE" == "server" ]]; then
  log "配置 Linode server"

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(ip -6 route show default | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  fi
  [[ -n "$WAN_IF" ]] || die "无法自动识别 IPv6 出口网卡，请指定 --wan-iface"

  if [[ -z "$GW6" ]]; then
    GW6="$(ip -6 route show default | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  fi
  [[ -n "$GW6" ]] || die "无法自动识别 IPv6 网关，请指定 --gateway6"

  cat >"${ETC_DIR}/server.env" <<EOF
TAG='$PREFIX_TAG'
IF_PREFIX='$IF_PREFIX'
PREFIX='$PREFIX'
INNER_BASE='$INNER_BASE'
LOOPBACK='$LOOPBACK'
SS_PORT='$SS_PORT'
VPS_TABLE_BASE='$VPS_TABLE_BASE'
WAN_IF='$WAN_IF'
GW6='$GW6'
EOF
  chmod 600 "${ETC_DIR}/server.env"

  IPV6_SETUP="/usr/local/sbin/gre10-${PREFIX_TAG}-vps-ipv6-setup"
  cat >"$IPV6_SETUP" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
while IFS='|' read -r N IP KEY; do
  ip -6 addr replace "\${IP}/128" dev "$WAN_IF"
done <"$CONF"
ip addr replace "$LOOPBACK/32" dev lo
EOF
  chmod +x "$IPV6_SETUP"

  ROUTE_ONE="/usr/local/sbin/gre10-${PREFIX_TAG}-route-one"
  cat >"$ROUTE_ONE" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N="\$1"
REMOTE="\$2"
LINE=\$(awk -F'|' -v n="\$N" '\$1==n {print; exit}' "$CONF")
IFS='|' read -r N LOCAL KEY <<<"\$LINE"
[[ -n "\$LOCAL" ]] || exit 1

TABLE=\$(( $VPS_TABLE_BASE + N ))
PRIO=\$(( 18000 + TABLE ))

while ip -6 rule del priority "\$PRIO" 2>/dev/null; do :; done
ip -6 rule add priority "\$PRIO" from "\$LOCAL/128" lookup "\$TABLE"

ip -6 route flush table "\$TABLE" 2>/dev/null || true
ip -6 route add table "\$TABLE" "\$REMOTE/128" \
  via "$GW6" dev "$WAN_IF" src "\$LOCAL" metric 1
ip -6 route add table "\$TABLE" default \
  via "$GW6" dev "$WAN_IF" src "\$LOCAL" metric 100
EOF
  chmod +x "$ROUTE_ONE"

  REBUILD_ONE="/usr/local/sbin/gre10-${PREFIX_TAG}-rebuild-one"
  cat >"$REBUILD_ONE" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
N="\$1"
REMOTE="\$2"
LINE=\$(awk -F'|' -v n="\$N" '\$1==n {print; exit}' "$CONF")
IFS='|' read -r N LOCAL KEY <<<"\$LINE"
[[ -n "\$LOCAL" ]] || exit 1
NAME="${IF_PREFIX}\${N}"

"$ROUTE_ONE" "\$N" "\$REMOTE"

ip link del "\$NAME" 2>/dev/null || true
ip -6 tunnel add "\$NAME" \
  mode ip6gre \
  local "\$LOCAL" \
  remote "\$REMOTE" \
  key "\$KEY" \
  encaplimit none \
  dev "$WAN_IF"
ip link set "\$NAME" mtu 1444 up
ip addr replace "$INNER_BASE.\${N}.1/30" dev "\$NAME"

printf '%s\n' "\$REMOTE" >"$REMOTE_DIR/\$NAME"
chmod 600 "$REMOTE_DIR/\$NAME"
EOF
  chmod +x "$REBUILD_ONE"

  SERVER_SETUP="/usr/local/sbin/gre10-${PREFIX_TAG}-vps-setup"
  cat >"$SERVER_SETUP" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p "$RUN_DIR" "$REMOTE_DIR"
"$IPV6_SETUP"

while IFS='|' read -r N LOCAL KEY; do
  NAME="${IF_PREFIX}\${N}"
  RF="$REMOTE_DIR/\$NAME"
  if [[ -s "\$RF" ]]; then
    REMOTE=\$(cat "\$RF")
    "$REBUILD_ONE" "\$N" "\$REMOTE"
  else
    ip link del "\$NAME" 2>/dev/null || true
    ip -6 tunnel add "\$NAME" \
      mode ip6gre \
      local "\$LOCAL" \
      remote any \
      key "\$KEY" \
      encaplimit none \
      dev "$WAN_IF"
    ip link set "\$NAME" mtu 1444 up
    ip addr replace "$INNER_BASE.\${N}.1/30" dev "\$NAME"
  fi
done <"$CONF"
EOF
  chmod +x "$SERVER_SETUP"

  LEARNER="/usr/local/sbin/gre10-${PREFIX_TAG}-learner.py"
  cat >"$LEARNER" <<EOF
#!/usr/bin/env python3
import socket, struct, subprocess, os, time

CONF = "$CONF"
REMOTE_DIR = "$REMOTE_DIR"
REBUILD = "$REBUILD_ONE"
IF_PREFIX = "$IF_PREFIX"

os.makedirs(REMOTE_DIR, exist_ok=True)
mapping = {}

with open(CONF) as f:
    for line in f:
        line=line.strip()
        if not line:
            continue
        n, local, key = line.split("|")
        mapping[(socket.inet_pton(socket.AF_INET6, local), int(key))] = int(n)

def current_remote(n):
    p=os.path.join(REMOTE_DIR, f"{IF_PREFIX}{n}")
    try:
        return open(p).read().strip()
    except Exception:
        return ""

def rebuild(n, remote):
    if current_remote(n) == remote:
        return
    print(f"{IF_PREFIX}{n}: remote -> {remote}", flush=True)
    subprocess.run([REBUILD, str(n), remote], check=True)

def parse(pkt):
    if len(pkt) < 14:
        return
    off=14
    et=struct.unpack("!H", pkt[12:14])[0]
    while et in (0x8100,0x88a8):
        if len(pkt) < off+4:
            return
        et=struct.unpack("!H", pkt[off+2:off+4])[0]
        off += 4
    if et != 0x86DD or len(pkt) < off+40:
        return

    ipoff=off
    nh=pkt[ipoff+6]
    src=pkt[ipoff+8:ipoff+24]
    dst=pkt[ipoff+24:ipoff+40]
    off=ipoff+40

    # IPv6 extension headers
    while nh in (0,43,44,51,60):
        if nh == 44:
            if len(pkt) < off+8:
                return
            newnh=pkt[off]
            frag=struct.unpack("!H",pkt[off+2:off+4])[0]
            if ((frag >> 3) & 0x1fff) != 0:
                return
            nh=newnh
            off += 8
            continue
        if nh == 51:
            if len(pkt) < off+2:
                return
            newnh=pkt[off]
            hlen=(pkt[off+1]+2)*4
            nh=newnh
            off += hlen
            continue
        if len(pkt) < off+2:
            return
        newnh=pkt[off]
        hlen=(pkt[off+1]+1)*8
        nh=newnh
        off += hlen

    if nh != 47 or len(pkt) < off+8:
        return

    flags=struct.unpack("!H",pkt[off:off+2])[0]
    if not (flags & 0x2000):
        return
    pos=off+4
    if flags & 0xC000:
        pos += 4
    if len(pkt) < pos+4:
        return
    key=struct.unpack("!I",pkt[pos:pos+4])[0]

    n=mapping.get((dst,key))
    if not n:
        return
    remote=socket.inet_ntop(socket.AF_INET6,src)
    rebuild(n,remote)

sock=socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(0x0003))
print("GRE10 learner started", flush=True)
while True:
    try:
        parse(sock.recv(65535))
    except Exception as e:
        print("learner error:",repr(e),flush=True)
        time.sleep(1)
EOF
  chmod +x "$LEARNER"

  cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-vps.service" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG VPS IPv6 and GRE setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SERVER_SETUP
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-learner.service" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG dynamic home IPv6 learner
After=gre10-${PREFIX_TAG}-vps.service
Requires=gre10-${PREFIX_TAG}-vps.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u $LEARNER
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  log "部署 VPS GRE"
  "$SERVER_SETUP"

  log "安装 Shadowsocks-Rust server"
  install_ssrust server

  SS_PASS_FILE="${ETC_DIR}/ss.password"
  if [[ ! -s "$SS_PASS_FILE" ]]; then
    python3 - <<PY >"$SS_PASS_FILE"
import secrets
print(secrets.token_hex(16))
PY
    chmod 600 "$SS_PASS_FILE"
  fi

  SS_CONF="${ETC_DIR}/ssserver.json"
  python3 - "$SS_PASS_FILE" "$SS_CONF" "$LOOPBACK" "$SS_PORT" <<'PY'
import json,sys
pwf,out,host,port=sys.argv[1:]
pw=open(pwf).read().strip()
cfg={
  "server":host,
  "server_port":int(port),
  "method":"aes-128-gcm",
  "password":pw,
  "mode":"tcp_and_udp"
}
with open(out,"w") as f:
    json.dump(cfg,f,indent=2)
    f.write("\n")
PY
  chmod 600 "$SS_CONF"

  cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-ssserver.service" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG Shadowsocks-Rust Server
After=gre10-${PREFIX_TAG}-vps.service
Requires=gre10-${PREFIX_TAG}-vps.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c $SS_CONF
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "gre10-${PREFIX_TAG}-vps.service"
  systemctl enable --now "gre10-${PREFIX_TAG}-learner.service"
  systemctl enable --now "gre10-${PREFIX_TAG}-ssserver.service"

  SS_LINK_FILE="/root/gre10-${PREFIX_TAG}-ss-link.txt"
  python3 - "$SS_PASS_FILE" "$LOOPBACK" "$SS_PORT" "$PREFIX_TAG" >"$SS_LINK_FILE" <<'PY'
import base64,sys
pwf,host,port,tag=sys.argv[1:]
pw=open(pwf).read().strip()
u=base64.urlsafe_b64encode(f"aes-128-gcm:{pw}".encode()).decode().rstrip("=")
print(f"ss://{u}@{host}:{port}#{tag}_gre10")
PY
  chmod 600 "$SS_LINK_FILE"

  STATUS="/usr/local/bin/gre10-${PREFIX_TAG}-vps-status"
  cat >"$STATUS" <<EOF
#!/usr/bin/env bash
echo "=== IPv6 endpoints ==="
ip -6 addr show dev "$WAN_IF" | grep -F "$(python3 - "$PREFIX" <<'PY'
import ipaddress,sys
n=ipaddress.IPv6Network(sys.argv[1],strict=False)
print(str(n.network_address).split("::")[0])
PY
)" || true
echo
echo "=== GRE ==="
for i in \$(seq 1 10); do
  ip -d link show "${IF_PREFIX}\$i" 2>/dev/null | grep -E '^[0-9]+:|ip6gre' || true
done
echo
echo "=== learner ==="
systemctl is-active "gre10-${PREFIX_TAG}-learner.service" || true
echo "=== ssserver ==="
systemctl is-active "gre10-${PREFIX_TAG}-ssserver.service" || true
ss -lntup | grep ":$SS_PORT" || true
EOF
  chmod +x "$STATUS"

  echo
  echo "============================================================"
  echo "SERVER 完成"
  echo "Tag            : $PREFIX_TAG"
  echo "WAN            : $WAN_IF"
  echo "IPv6 gateway   : $GW6"
  echo "Loopback       : $LOOPBACK"
  echo "GRE token file : ${TOKEN_FILE:-$TOKEN_DEFAULT}"
  echo "SS link file   : $SS_LINK_FILE"
  echo
  echo "下一步：把 token 文件通过 scp 安全复制到本地 Debian："
  echo "  scp root@<LINODE_IP>:${TOKEN_FILE:-$TOKEN_DEFAULT} /root/gre10-${PREFIX_TAG}.token"
  echo
  echo "然后在本地运行 client 角色。"
  echo
  echo "代理链接（仅在本地 GRE 建通后可用）："
  cat "$SS_LINK_FILE"
  echo "============================================================"
  exit 0
fi

# ========================= CLIENT =========================

log "配置本地 Debian client"

cat >"${ETC_DIR}/client.env" <<EOF
TAG='$PREFIX_TAG'
IF_PREFIX='$IF_PREFIX'
PREFIX='$PREFIX'
INNER_BASE='$INNER_BASE'
LOOPBACK='$LOOPBACK'
CLIENT_TABLE_BASE='$CLIENT_TABLE_BASE'
SWITCH_DELTA='$SWITCH_DELTA'
MAX_RTT='$MAX_RTT'
CONFIRM_COUNT='$CONFIRM_COUNT'
EOF
chmod 600 "${ETC_DIR}/client.env"

REFRESH="/usr/local/sbin/gre10-${PREFIX_TAG}-refresh"
cat >"$REFRESH" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p "$RUN_DIR"
exec 9>"$RUN_DIR/refresh.lock"
flock -n 9 || exit 0

while IFS='|' read -r N DST KEY; do
  NAME="${IF_PREFIX}\${N}"
  LOCAL4="$INNER_BASE.\${N}.2/30"

  ROUTE=\$(ip -6 route get "\$DST" 2>/dev/null | head -1 || true)
  SRC=\$(awk '{for(i=1;i<=NF;i++) if(\$i=="src"){print \$(i+1);exit}}' <<<"\$ROUTE")
  DEV=\$(awk '{for(i=1;i<=NF;i++) if(\$i=="dev"){print \$(i+1);exit}}' <<<"\$ROUTE")

  if [[ -z "\$SRC" || -z "\$DEV" ]]; then
    echo "\$NAME: 无法确定到 \$DST 的 IPv6 source/dev"
    continue
  fi

  STATE="$RUN_DIR/\${NAME}.underlay"
  OLD=""
  [[ -s "\$STATE" ]] && OLD=\$(cat "\$STATE")

  WANT="\$SRC|\$DEV"
  if ! ip link show "\$NAME" >/dev/null 2>&1 || [[ "\$OLD" != "\$WANT" ]]; then
    ip link del "\$NAME" 2>/dev/null || true
    ip -6 tunnel add "\$NAME" \
      mode ip6gre \
      local "\$SRC" \
      remote "\$DST" \
      key "\$KEY" \
      encaplimit none \
      dev "\$DEV"
    ip link set "\$NAME" mtu 1444 up
    ip addr replace "\$LOCAL4" dev "\$NAME"
    printf '%s\n' "\$WANT" >"\$STATE"
  else
    ip link set "\$NAME" mtu 1444 up
    ip addr replace "\$LOCAL4" dev "\$NAME"
  fi
done <"$CONF"
EOF
chmod +x "$REFRESH"

POLICY="/usr/local/sbin/gre10-${PREFIX_TAG}-policy"
cat >"$POLICY" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
for i in \$(seq 1 10); do
  TABLE=\$(( $CLIENT_TABLE_BASE + i ))
  PRIO=\$(( 20000 + TABLE ))

  while ip rule del priority "\$PRIO" 2>/dev/null; do :; done
  ip route flush table "\$TABLE" 2>/dev/null || true

  ip route add table "\$TABLE" "$LOOPBACK/32" \
    via "$INNER_BASE.\${i}.1" \
    dev "${IF_PREFIX}\${i}" \
    src "$INNER_BASE.\${i}.2" \
    onlink

  ip rule add priority "\$PRIO" \
    from "$INNER_BASE.\${i}.2/32" \
    to "$LOOPBACK/32" \
    lookup "\$TABLE"
done
EOF
chmod +x "$POLICY"

SELECTOR="/usr/local/sbin/gre10-${PREFIX_TAG}-selector.py"
cat >"$SELECTOR" <<EOF
#!/usr/bin/env python3
import concurrent.futures, json, os, re, subprocess

IF_PREFIX="$IF_PREFIX"
INNER_BASE="$INNER_BASE"
LOOPBACK="$LOOPBACK"
MAX_RTT=float("$MAX_RTT")
SWITCH_DELTA=float("$SWITCH_DELTA")
CONFIRM_COUNT=int("$CONFIRM_COUNT")
STATE="$RUN_DIR/select-state.json"
STATUS="$RUN_DIR/status"

os.makedirs("$RUN_DIR",exist_ok=True)

def test(i):
    try:
        p=subprocess.run(
            ["ping","-I",f"{IF_PREFIX}{i}","-c","3","-W","1",f"{INNER_BASE}.{i}.1"],
            stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=5
        )
        m=re.search(r'(?:rtt|round-trip)[^=]*=\s*[\d.]+/([\d.]+)/',p.stdout)
        return i,(float(m.group(1)) if m else None)
    except Exception:
        return i,None

with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
    result=dict(ex.map(test,range(1,11)))

reachable={i:r for i,r in result.items() if r is not None}
if not reachable:
    open(STATUS+".tmp","w").write("ERROR: no GRE reachable\n")
    os.replace(STATUS+".tmp",STATUS)
    raise SystemExit(1)

good={i:r for i,r in reachable.items() if r <= MAX_RTT}
pool=good if good else reachable
best=min(pool,key=pool.get)
best_rtt=pool[best]

try:
    state=json.load(open(STATE))
except Exception:
    state={}

current=state.get("current")
pending=state.get("pending")
count=int(state.get("count",0))
switch=False
reason=""

if current not in reachable:
    switch=True
    reason="current-dead"
elif current == best:
    pending=None
    count=0
else:
    current_rtt=reachable[current]
    if (current_rtt-best_rtt >= SWITCH_DELTA) or (current_rtt>MAX_RTT and best_rtt<=MAX_RTT):
        if pending == best:
            count += 1
        else:
            pending=best
            count=1
        if count >= CONFIRM_COUNT:
            switch=True
            reason="better-path"
    else:
        pending=None
        count=0

if switch:
    old=current
    subprocess.run([
        "ip","route","replace",f"{LOOPBACK}/32",
        "via",f"{INNER_BASE}.{best}.1",
        "dev",f"{IF_PREFIX}{best}",
        "src",f"{INNER_BASE}.{best}.2",
        "metric","10","onlink"
    ],check=True)
    current=best
    pending=None
    count=0
    subprocess.run(["logger","-t",f"gre10-{IF_PREFIX}",f"switch {old} -> {IF_PREFIX}{best} rtt={best_rtt:.3f} reason={reason}"])

with open(STATE+".tmp","w") as f:
    json.dump({"current":current,"pending":pending,"count":count},f)
os.replace(STATE+".tmp",STATE)

lines=["=== GRE10 RTT ==="]
for i in range(1,11):
    r=result.get(i)
    lines.append(f"{IF_PREFIX}{i} rtt_ms={'DOWN' if r is None else f'{r:.3f}'}")
lines.append(f"best={IF_PREFIX}{best} best_rtt={best_rtt:.3f}")
lines.append(f"current={IF_PREFIX+str(current) if current else 'none'}")
route=subprocess.run(["ip","route","show","exact",f"{LOOPBACK}/32"],stdout=subprocess.PIPE,text=True).stdout.strip()
lines.extend(["",route])
with open(STATUS+".tmp","w") as f:
    f.write("\n".join(lines)+"\n")
os.replace(STATUS+".tmp",STATUS)
EOF
chmod +x "$SELECTOR"

cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-refresh.service" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG refresh client IPv6 endpoints
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$REFRESH
EOF

cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-refresh.timer" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG refresh timer

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=2s

[Install]
WantedBy=timers.target
EOF

cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-policy.service" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG per-source IPv4 policy
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=$REFRESH
ExecStart=$POLICY
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-selector.service" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG RTT selector
After=gre10-${PREFIX_TAG}-policy.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $SELECTOR
EOF

cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-selector.timer" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG selector timer

[Timer]
OnBootSec=20s
OnUnitActiveSec=10s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

if [[ "$LOCK_IPV6" == "1" ]]; then
  SAFE_TAG="$(echo "$PREFIX_TAG" | tr -c 'A-Za-z0-9_' '_')"
  NFT_TABLE="gre10_${SAFE_TAG}_guard"
  NFT_FILE="${ETC_DIR}/ipv6-lock.nft"
  FW_APPLY="/usr/local/sbin/gre10-${PREFIX_TAG}-ipv6-lock"

  cat >"$NFT_FILE" <<EOF
table inet $NFT_TABLE {
  chain output {
    type filter hook output priority filter; policy accept;

    # 只限制 IPv6；IPv4 完全不动。
    meta nfproto ipv6 ip6 daddr ::1 accept
    meta nfproto ipv6 ip6 daddr fe80::/10 accept
    meta nfproto ipv6 ip6 daddr ff00::/8 accept

    # ICMPv6 对 ND/RA/PMTUD 必不可少。
    meta nfproto ipv6 meta l4proto ipv6-icmp accept

    # 允许访问 Linode 的整个 /64。
    meta nfproto ipv6 ip6 daddr $PREFIX accept

    # 其余本机发起的公网 IPv6 拒绝。
    meta nfproto ipv6 reject with icmpv6 type admin-prohibited
  }
}
EOF

  cat >"$FW_APPLY" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" || true
nft -f "$NFT_FILE"
EOF
  chmod +x "$FW_APPLY"

  cat >"/etc/systemd/system/gre10-${PREFIX_TAG}-ipv6-lock.service" <<EOF
[Unit]
Description=GRE10 $PREFIX_TAG local IPv6 output lock
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$FW_APPLY
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
fi

STATUS="/usr/local/bin/gre10-${PREFIX_TAG}-status"
cat >"$STATUS" <<EOF
#!/usr/bin/env bash
echo "=== RTT / selector ==="
cat "$RUN_DIR/status" 2>/dev/null || echo "no selector status yet"
echo
echo "=== loopback route ==="
ip route show exact "$LOOPBACK/32"
echo
echo "=== GRE interfaces ==="
ip -br addr show | grep '^${IF_PREFIX}' || true
echo
echo "=== timers ==="
systemctl is-active "gre10-${PREFIX_TAG}-refresh.timer" 2>/dev/null || true
systemctl is-active "gre10-${PREFIX_TAG}-selector.timer" 2>/dev/null || true
EOF
chmod +x "$STATUS"

log "创建本地 GRE"
"$REFRESH"
"$POLICY"

systemctl daemon-reload
systemctl enable --now "gre10-${PREFIX_TAG}-refresh.timer"
systemctl enable --now "gre10-${PREFIX_TAG}-policy.service"
systemctl enable --now "gre10-${PREFIX_TAG}-selector.timer"

if [[ "$LOCK_IPV6" == "1" ]]; then
  systemctl enable --now "gre10-${PREFIX_TAG}-ipv6-lock.service"
fi

# Bootstrap packets: trigger VPS learner. First round may fail by design.
log "发送 bootstrap GRE 包，触发 VPS learner"
for round in 1 2 3; do
  for i in $(seq 1 10); do
    ping -I "${IF_PREFIX}${i}" -c 1 -W 1 "$INNER_BASE.${i}.1" >/dev/null 2>&1 || true
  done
  sleep 2
done

systemctl start "gre10-${PREFIX_TAG}-selector.service" || true

echo
echo "============================================================"
echo "CLIENT 完成"
echo "Tag          : $PREFIX_TAG"
echo "Linode /64   : $PREFIX"
echo "Loopback     : $LOOPBACK"
echo "Status       : gre10-${PREFIX_TAG}-status"
echo
echo "查看 10 条 GRE："
echo "  for i in \$(seq 1 10); do ping -I ${IF_PREFIX}\$i -c 3 -W 1 $INNER_BASE.\$i.1; done"
echo
echo "查看 selector："
echo "  gre10-${PREFIX_TAG}-status"
echo
echo "如果最初 10 条都不通，请在 VPS 查看："
echo "  journalctl -u gre10-${PREFIX_TAG}-learner -n 100 --no-pager"
echo
echo "本机 IPv6 lock: $LOCK_IPV6"
echo "============================================================"
