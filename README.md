# hopctl · 双栈端口跳跃面板

为本机运行的服务创建端口跳跃规则。公网端口或端口范围可手动填写，目标是本机的单一服务端口。支持 IPv4、IPv6、UDP、TCP 和两种协议同时使用。默认协议为 UDP，适合 Hysteria 2。整个项目独立运行，不修改 Xboard 或 V2bX 代码。

## 一键安装

主要适配 **Debian + systemd**。在 Debian 服务器终端复制下面整行执行，安装完成后会自动打开面板：

```bash
curl -fsSLo /tmp/install-hopctl.sh https://raw.githubusercontent.com/zzx327317-creator/hopctl/main/install.sh && bash /tmp/install-hopctl.sh
```

安装脚本会自动请求所需权限，检查并安装 `iptables` / `ip6tables` / `flock`，安装 `hopctl` 命令，创建 systemd 服务与复核定时器。执行完毕会打开交互面板。也可下载仓库后在目录内运行 `bash install.sh`。

以后随时输入 `hopctl` 调出面板。非 root 用户会自动请求 sudo 授权；也可直接执行 `sudo hopctl`。

## 用法

菜单可添加、查看、按编号删除、立即校验并修复规则。例如公网 UDP `2000–2999` 转发到本机 UDP `4443`：

```text
协议：udp
公网端口或范围：2000-2999
本机服务端口：4443
```

也支持非交互命令：

```bash
sudo hopctl add udp 2000-2999 4443
sudo hopctl add tcp 10000 443
sudo hopctl add both 3000-3999 4443
sudo hopctl list
sudo hopctl delete 2
sudo hopctl apply
```

`both` 在同一编号下生成 TCP 和 UDP 两条规则；删除该编号会同时移除这两条。相同协议的端口范围不允许重叠，不同协议可复用端口。重复添加完全相同的规则只会复核现有配置，不会产生重复规则。

## 持久化与恢复

- 配置保存在 `/etc/hopctl/rules.tsv`，权限为 root 专用。`hopctl.service` 在开机后检查并应用配置；`hopctl.timer` 每 5 分钟再次核对。检查为幂等操作，规则正确时不会重建。
- 规则放在独立的 IPv4 和 IPv6 `HOPCTL` NAT 链中。若其他管理脚本清空 NAT 规则，运行 `sudo hopctl apply` 可立即恢复；定时器也会在下一次复核时恢复。
- 删除时先用 `sudo hopctl list` 取得编号，再在面板中选择编号，或执行 `sudo hopctl delete 编号`。**不会自动清理历史规则**。
- 如 IPv6 NAT 不可用，添加命令会报错，且不会保存新配置；不会把仅 IPv4 成功报告成双栈成功。

## 使用前核对

1. 目标服务确实监听所选的 TCP/UDP 服务端口。Hysteria 2 使用 UDP，所以通常选择 `udp`。`both` 不会把 UDP 服务变成 TCP 服务。
2. 云厂商安全组和服务器防火墙允许公网端口范围；主机防火墙也应允许转发后的服务端口。
3. 要让用户走 IPv6，服务器须有可用的 IPv6 地址、DNS AAAA 记录，目标服务也要在 IPv6 上监听。安装脚本验证 IPv6 NAT 能否设置，但不能代替这些网络条件。
4. 此脚本用于**服务与转发规则位于同一主机**的情形，不用于把流量转发到另一台服务器。Docker 容器中的服务需要正确发布服务端口，或使用 host 网络。
5. 客户端需要支持端口跳跃配置，且跳跃范围与本脚本一致。V2bX 节点的服务端口仍填实际监听端口，例如 `4443`。

## 排查

```bash
sudo hopctl list
sudo systemctl status hopctl.service hopctl.timer
sudo journalctl -u hopctl.service -n 50 --no-pager
sudo iptables -t nat -S HOPCTL
sudo ip6tables -t nat -S HOPCTL
```

`hopctl list` 中显示“缺失”时，先运行 `sudo hopctl apply`。若提示 `ip6tables` NAT 不支持，检查系统内核、IPv6 启用状态及 iptables 后端。脚本不会修改已有防火墙默认策略或自动开放云安全组。
