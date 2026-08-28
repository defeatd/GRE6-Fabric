# 10×GRE6 + Linode + Shadowsocks-Rust：完整搭建教程

> 目标：用一台本地 Debian 小主机，与一台 Linode VPS 建立 10 条独立 IPv6 GRE 隧道。  
> 本地持续测量 10 条 GRE 的 RTT，自动选择最优路径；Linode 上用稳定 Loopback 地址运行 Shadowsocks-Rust，最终生成一个 `ss://` 链接，导入本地代理软件即可使用。
>
> 推荐优先测试的 Linode 区域：**Tokyo 2（TY2）** 和 **Singapore（SG）**。不同地区、不同运营商、不同时间段的国际路由差异很大，所以不要只看机房名，必须实测 RTT、丢包和单 TCP 吞吐。

---

## 1. 方案原理

拓扑：

```text
局域网设备
   │
   ▼
本地 Debian 小主机
   │
   ├── GRE6 #1 ──> Linode IPv6 ::1
   ├── GRE6 #2 ──> Linode IPv6 ::2
   ├── GRE6 #3 ──> Linode IPv6 ::3
   │       ...
   └── GRE6 #10 ─> Linode IPv6 ::a
                     │
                     ▼
              10.255.255.x/32
                     │
              Shadowsocks-Rust
                     │
                     ▼
                  Internet
```

为什么要做 10 条？

很多移动/国际网络存在 ECMP。即使是同一台 Linode，只要目标 IPv6 不同，运营商内部可能把流量放到不同路径上。10 条 GRE 的作用不是“把 10 条带宽叠加”，而是把 10 个候选路径固定下来，再从里面选最稳定/最快的一条。

---

## 2. 机器要求

### 本地 Debian 小主机

建议：

- Debian 12/13。
- 有可用公网 IPv6。
- 能直接访问 Linode 的 IPv6。
- root 权限。
- 如果作为旁路由/透明代理机，不需要改变 DHCP 和 LAN 默认网关。
- 防火墙不要拦截 IPv6 GRE（IP protocol 47）。

脚本默认启用一个“本机 IPv6 出口锁”：

- IPv4 完全不动；
- 保留 IPv6 loopback、link-local、multicast；
- 保留全部 ICMPv6（ND/RA/PMTUD 需要它）；
- 允许访问你的 Linode `/64`；
- 其余**本机发起的公网 IPv6**拒绝；
- **不修改 FORWARD**，因此不会贸然破坏局域网转发。

如果不希望启用，加：

```bash
--no-ipv6-lock
```

### Linode VPS

建议：

- Debian/Ubuntu。
- 申请/分配一个路由到本实例的 IPv6 `/64`。
- 推荐 TY2、Singapore 两个机房都测试。
- Linode Cloud Firewall / VPS 本机防火墙必须允许 GRE（IPv6 Next Header / IP Protocol 47）。
- SSH 保持可访问。

Shadowsocks-Rust 官方提供静态构建；脚本会自动下载 `*-unknown-linux-musl.tar.xz`，避免旧系统 GLIBC 兼容问题。

---

## 3. 地址规划

一套 SG 示例：

```text
Linode /64:
2600:3c0c:e001:56::/64

10 个外层 IPv6:
2600:3c0c:e001:56::1
2600:3c0c:e001:56::2
...
2600:3c0c:e001:56::a

GRE 内层:
sgg1:  VPS 10.34.1.1/30  <->  本地 10.34.1.2/30
sgg2:  VPS 10.34.2.1/30  <->  本地 10.34.2.2/30
...
sgg10: VPS 10.34.10.1/30 <->  本地 10.34.10.2/30

VPS Loopback:
10.255.255.2/32
```

TY2 可以使用：

```text
tag: ty2
inner-base: 10.33
loopback: 10.255.255.1
client-table-base: 260
vps-table-base: 360
```

SG 可以使用：

```text
tag: sg
inner-base: 10.34
loopback: 10.255.255.2
client-table-base: 270
vps-table-base: 380
```

这样 TY2 和 SG 可以同时存在于同一台本地 Debian 上，不冲突。

---

## 4. 下载脚本

把 `gre6-10-install.sh` 放到两台机器，例如：

```bash
chmod +x gre6-10-install.sh
```

脚本只有一个文件，通过 `server` / `client` 两个角色安装。

---

# 5. 第一步：安装 Linode 服务端

以 SG 为例：

```bash
bash gre6-10-install.sh server \
  --prefix 2600:3c0c:e001:56::/64 \
  --tag sg \
  --inner-base 10.34 \
  --loopback 10.255.255.2 \
  --client-table-base 270 \
  --vps-table-base 380 \
  --switch-delta 5
```

服务器脚本会自动完成：

1. 安装依赖；
2. 从 `/64` 生成 `::1` 到 `::a` 10 个 IPv6；
3. 自动识别 Linode IPv6 出口网卡和 link-local gateway；
4. 给 10 个 IPv6 建立持久化 systemd 配置；
5. 自动生成 10 个 GRE key；
6. 创建 10 个 `ip6gre` 接口；
7. 启动动态家庭 IPv6 learner；
8. 配置每个 GRE 源 IPv6 的独立 IPv6 policy-routing table；
9. 对家庭 IPv6 endpoint 写显式 `/128` 路由；
10. 创建 Loopback；
11. 安装 Shadowsocks-Rust musl 静态版；
12. 开启 `tcp_and_udp`；
13. 自动生成 SS 密码；
14. 生成 `ss://` 链接。

### 为什么服务端必须使用显式 `/128` route？

这是整套方案最容易踩的坑。

当 Linode 同一个网卡上挂了多个 IPv6：

```text
::1
::2
...
::a
```

Linux `ip6gre` 的外层发送可能没有按 tunnel 的 `local` 地址正确选 source/dst cache。

典型症状：

```text
GRE RX 正常
GRE TX packets = 0
TX errors / dropped / carrier 不断增加
```

普通：

```bash
ping -6 -I <某个IPv6> <家庭IPv6>
```

却完全正常。

正确做法是给每个 GRE source 建独立表：

```text
from ::1 -> table N
```

并在这个表里显式写：

```text
家庭IPv6/128 via Linode-link-local-gateway dev eth0 src ::1
```

然后重建 tunnel 清理旧 `ip6gre dst cache`。

**本教程的一键脚本已经内置了这个修复。**

---

## 6. Token 不需要手工复制内容

Server 第一次运行会生成：

```text
/root/gre10-sg.token
```

不要把 token 发到聊天、论坛或截图里。

直接通过 SSH/SCP 把文件复制到本地 Debian：

```bash
scp root@<LINODE_IP>:/root/gre10-sg.token /root/gre10-sg.token
chmod 600 /root/gre10-sg.token
```

GRE key 由同一个 token 确定性生成，因此两端会自动得到完全相同的 10 个 key。

---

# 7. 第二步：安装本地 Debian

还是 SG 示例：

```bash
bash gre6-10-install.sh client \
  --prefix 2600:3c0c:e001:56::/64 \
  --tag sg \
  --inner-base 10.34 \
  --loopback 10.255.255.2 \
  --client-table-base 270 \
  --vps-table-base 380 \
  --switch-delta 5 \
  --token-file /root/gre10-sg.token
```

客户端脚本会自动：

1. 根据 `ip -6 route get` 找到访问每个 Linode IPv6 时真正使用的本地 IPv6；
2. 创建 10 条 `ip6gre`；
3. 设置 `encaplimit none`；
4. 设置 MTU 1444；
5. 配置 `10.34.N.2/30`；
6. 每 30 秒检查一次家庭 IPv6 是否变化；
7. 家庭 IPv6 变化时自动重建对应 tunnel；
8. 创建 10 个 per-source IPv4 policy table；
9. 每 10 秒并行测量 10 条 GRE；
10. 自动把 `10.255.255.2/32` 指向最佳 GRE；
11. 可选限制本机 IPv6 只允许访问 Linode `/64`。

---

## 8. 第一次为什么可能会丢几个包？

这是正常的。

第一次流程是：

```text
本地创建 GRE
   ↓
发第一个 GRE 包
   ↓
Linode learner 从原始 IPv6/GRE 包读出家庭 IPv6
   ↓
Linode 建立：
  - remote = 当前家庭 IPv6
  - 对该家庭 IPv6 的 /128 policy route
   ↓
重建 server GRE
   ↓
双向打通
```

所以第一次 `ping` 可能前几个包超时。

---

# 9. 检查 10 条 GRE

本地：

```bash
for i in $(seq 1 10); do
    echo "===== sgg$i ====="
    ping -I "sgg$i" -c 5 -W 2 "10.34.${i}.1"
done
```

快速看 RTT：

```bash
for i in $(seq 1 10); do
    printf "sgg%-2s  " "$i"

    ping -I "sgg$i" -c 5 -W 2 "10.34.${i}.1" \
    | awk -F'/' '/rtt|round-trip/ {
        printf "avg=%s ms\n",$5
    }'
done
```

状态命令：

```bash
gre10-sg-status
```

示例：

```text
=== GRE10 RTT ===
sgg1 rtt_ms=93.4
sgg2 rtt_ms=87.5
sgg3 rtt_ms=87.8
...
best=sgg2 best_rtt=87.5
current=sgg2

10.255.255.2 via 10.34.2.1 dev sgg2 src 10.34.2.2
```

---

# 10. selector 的逻辑

默认：

```text
MAX_RTT        = 140 ms
SWITCH_DELTA   = 5 ms
CONFIRM_COUNT  = 2
```

不是看到另一条快 1ms 就立即切换。

例如：

```text
当前：88ms
候选：86ms
```

不切。

如果：

```text
当前：96ms
候选：88ms
```

并连续两次确认，才切换。

当前 tunnel 完全失效则立即切。

TY2 如果 RTT 差异比较大，可以把：

```bash
--switch-delta 10
```

SG 如果 10 条比较接近，建议：

```bash
--switch-delta 5
```

---

# 11. 为什么还要做 client per-source policy routing？

selector 只修改：

```text
10.255.255.2/32 -> 当前最佳 sggN
```

假设一条正在运行的 Shadowsocks TCP 会话原来走：

```text
src 10.34.2.2
```

selector 后来切成 `sgg8`。

如果没有 per-source policy，旧连接也可能跟着主 route 换路。

脚本给每个源地址做独立表：

```text
from 10.34.1.2 -> 只走 sgg1
from 10.34.2.2 -> 只走 sgg2
...
from 10.34.10.2 -> 只走 sgg10
```

结果：

- 旧连接保持原 GRE；
- 新连接使用 selector 当前最佳 GRE。

---

# 12. 检查 VPS learner

Linode：

```bash
journalctl -u gre10-sg-learner -n 100 --no-pager
```

正常会看到：

```text
sgg1: remote -> 2409:...
sgg2: remote -> 2409:...
...
```

检查：

```bash
ip -d link show sgg1
```

应该是：

```text
local  <Linode ::1>
remote <家庭 IPv6>
encaplimit none
```

`ip -d` 有时会把 GRE key 显示成点分十进制，例如：

```text
ikey 182.13.201.157
```

这不代表 key 错了，只是同一个 32-bit key 的另一种显示形式。

---

# 13. `state UNKNOWN` 正常吗？

正常。

GRE 是 point-to-point 虚拟接口：

```text
sgg1@eth0 UNKNOWN
```

并不代表线路掉线。

是否工作应看：

```bash
ping -I sgg1 10.34.1.1
ip -s link show sgg1
```

---

# 14. 测试纯 GRE 性能

Linode：

```bash
apt install -y iperf3
iperf3 -s -B 10.255.255.2
```

本地下载方向：

```bash
iperf3 -c 10.255.255.2 -P 1 -t 120 -O 3 -R
```

上传方向：

```bash
iperf3 -c 10.255.255.2 -P 1 -t 120 -O 3
```

测试完在 VPS：

```bash
pkill -x iperf3
```

确认：

```bash
ss -lntp | grep ':5201' || echo "iperf3 已停止"
```

---

# 15. Shadowsocks 服务

Server 脚本默认创建：

```json
{
  "server": "10.255.255.2",
  "server_port": 8388,
  "method": "aes-128-gcm",
  "mode": "tcp_and_udp"
}
```

密码不会写进教程。

VPS 检查：

```bash
ss -lntup | grep ':8388'
```

应同时看到 TCP 和 UDP。

---

# 16. 获取 SS 代理链接

Linode：

```bash
cat /root/gre10-sg-ss-link.txt
```

会输出类似：

```text
ss://BASE64_USERINFO@10.255.255.2:8388#sg_gre10
```

**把这个链接导入运行在本地 Debian 上的 dae / sing-box / Clash-compatible 管理层或其它支持 Shadowsocks SIP002 的客户端即可使用。**

注意：

这个 SS server 地址是：

```text
10.255.255.2
```

它是 GRE 内部的私网 Loopback，不是公网 IP。

因此：

- 如果代理程序运行在**本地 Debian 本机**，可直接使用；
- 如果你的 Debian 本身就是透明代理/旁路由，LAN 设备通过 Debian 使用即可；
- 如果你把这个链接直接导入另一台普通 LAN 主机，那台主机必须有路由：

```text
10.255.255.2/32 -> 本地 Debian
```

否则它无法直接访问这个私网地址。

---

# 17. TY2 示例

假设你的 TY2 `/64` 是：

```text
2400:8902:e001:432::/64
```

Server：

```bash
bash gre6-10-install.sh server \
  --prefix 2400:8902:e001:432::/64 \
  --tag ty2 \
  --inner-base 10.33 \
  --loopback 10.255.255.1 \
  --client-table-base 260 \
  --vps-table-base 360 \
  --switch-delta 10
```

复制 token：

```bash
scp root@<TY2_IP>:/root/gre10-ty2.token /root/gre10-ty2.token
```

Client：

```bash
bash gre6-10-install.sh client \
  --prefix 2400:8902:e001:432::/64 \
  --tag ty2 \
  --inner-base 10.33 \
  --loopback 10.255.255.1 \
  --client-table-base 260 \
  --vps-table-base 360 \
  --switch-delta 10 \
  --token-file /root/gre10-ty2.token
```

---

# 18. Singapore 示例

Server：

```bash
bash gre6-10-install.sh server \
  --prefix 2600:3c0c:e001:56::/64 \
  --tag sg \
  --inner-base 10.34 \
  --loopback 10.255.255.2 \
  --client-table-base 270 \
  --vps-table-base 380 \
  --switch-delta 5
```

Client：

```bash
bash gre6-10-install.sh client \
  --prefix 2600:3c0c:e001:56::/64 \
  --tag sg \
  --inner-base 10.34 \
  --loopback 10.255.255.2 \
  --client-table-base 270 \
  --vps-table-base 380 \
  --switch-delta 5 \
  --token-file /root/gre10-sg.token
```

---

# 19. TY2 和 SG 同时装

两套参数必须不同：

| 项目 | TY2 | SG |
|---|---|---|
| tag | `ty2` | `sg` |
| GRE | `ty2g1..10` | `sgg1..10` |
| inner | `10.33.N.*` | `10.34.N.*` |
| Loopback | `10.255.255.1` | `10.255.255.2` |
| client table | `261..270` | `271..280` |
| VPS table | `361..370` | `381..390` |

这样可以同时运行。

---

# 20. 常见故障

## A. 本地能发 GRE，Linode 完全看不到

Linode：

```bash
tcpdump -ni any 'ip6 proto 47'
```

本地：

```bash
ping -I sgg1 -c 5 10.34.1.1
```

如果 Linode 一包都没有：

- 检查本地 IPv6；
- 检查运营商/光猫；
- 检查 Linode Cloud Firewall；
- 检查 VPS 防火墙是否允许 GRE47。

---

## B. Linode eth0 能看到 GRE，但 `sgg1` 看不到

检查：

```bash
tcpdump -ni sgg1 icmp
ip -d link show sgg1
```

确认：

- local/remote 对称；
- key 一致；
- `encaplimit none`；
- destination IPv6 正确。

---

## C. Linode sgg1 能收到 request，也生成 reply，但 FNOS 收不到

看：

```bash
ip -s link show sgg1
```

如果：

```text
RX 正常
TX packets 0
TX errors/dropped/carrier 持续增长
```

这是 Linux 多 IPv6 + `ip6gre` 外层 route/dst-cache 的典型问题。

**本教程脚本已经通过 source-policy + 显式 remote `/128` route + tunnel rebuild 处理。**

---

## D. 家庭 IPv6 变化

不需要手工改 Linode。

本地 refresh 会自动使用新的 source IPv6 发 GRE。

Linode learner 看到新 source 后自动：

1. 更新 `/128` route；
2. 更新 source-policy；
3. 重建对应 GRE；
4. 保存新的 remote。

---

## E. Shadowsocks 有 TCP 没 UDP

Linode：

```bash
cat /etc/gre10-sg/ssserver.json
```

必须有：

```text
"mode": "tcp_and_udp"
```

再：

```bash
ss -lntup | grep ':8388'
```

应同时有 TCP/UDP。

---

# 21. 安全建议

1. GRE token 只用于生成 tunnel key，不要公开。
2. SS link 等价于代理凭据，不要公开。
3. SS link 泄露后立即更换密码。
4. 不要为了“禁止 IPv6”直接关闭 ICMPv6；这样会破坏 ND、RA、PMTUD。
5. 本教程默认 IPv6 lock 只约束本地 Debian 自己发起的 IPv6，不修改 LAN FORWARD。
6. Linode 仍应限制 SSH 来源、禁用密码登录或使用密钥。
7. 如果使用 Linode Cloud Firewall，确认 GRE protocol 47 没有被默认 Drop。

---

# 22. 推荐怎么选 TY2 和 SG？

不要根据地区名猜。

至少测试：

```text
10 条 RTT
10 条丢包
jitter
iperf3 -P 1 -R
晚高峰 1~2 分钟稳定性
```

可能出现：

```text
TY2：RTT 更低、单 TCP 更快
SG：速度低一点但晚高峰更稳
```

也可能反过来。

最终应选择：

> **低丢包 + 低 jitter + 单 TCP 稳定 + RTT 合理**

而不是只看一次 Speedtest 峰值。

---

## 官方参考

- Shadowsocks-Rust: https://github.com/shadowsocks/shadowsocks-rust
- Linode / Akamai Cloud Compute: https://www.linode.com/
- Linux `iproute2`: https://wiki.linuxfoundation.org/networking/iproute2

