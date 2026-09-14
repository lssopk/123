# Official Hysteria2 + Mieru/Mita One-Click

一键安装并管理两个官方协议实现：

- Hysteria2：使用官方 `https://get.hy2.sh/` 安装器
- Mieru/Mita：直接安装 `enfein/mieru` 官方 Release 中的 `mita` `.deb/.rpm` 包
- Hysteria2 使用 UDP
- Mieru 使用 TCP（官方文档也推荐大多数场景优先使用 TCP）
- 输入一个基础端口：HY2 使用该端口，Mieru 自动使用 `基础端口 + 1`
- 自动生成 OpenClash/Mihomo 两个节点配置
- 安装后使用 `proxy2` 打开统一快捷菜单

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lssopk/123/main/hy2-mieru-official/install.sh)
```

例如基础端口输入 `18611`：

- Hysteria2: `18611/UDP`
- Mieru: `18612/TCP`

## 快捷管理

```bash
proxy2
```

也支持：

```bash
proxy2 start
proxy2 stop
proxy2 restart
proxy2 status
proxy2 nodes
proxy2 logs
proxy2 ports
proxy2 auth
proxy2 upgrade
proxy2 uninstall
```

`proxy2 nodes` 会直接输出可复制到 OpenClash/Mihomo 的两个节点。

## Hysteria2 TLS

安装时需要提供证书和私钥。默认沿用：

```text
/usr/local/etc/xray/certs/_.s13.cc.pem
/usr/local/etc/xray/certs/_.s13.cc.key
```

如果证书由其他程序管理，脚本让 Hysteria2 systemd 服务以 root 用户运行，以避免证书读取权限问题。

## Mieru

服务端使用官方 `mita`。脚本配置：

- transport: TCP
- DNS dual stack policy: `PREFER_IPv4`
- Mihomo multiplexing: `MULTIPLEXING_OFF`
- Mihomo handshake mode: `HANDSHAKE_NO_WAIT`
- Mihomo `udp: true` 保留，用于允许 UDP Associate；底层 Mieru 传输仍然是 TCP

如果检测到以前通过 `ike-sh/mieru-OneClick` 安装的管理层，会先尝试卸载其 wrapper，再切换到官方 Mita，避免 `/usr/local/bin/mita` 覆盖官方 `/usr/bin/mita`。

## 支持系统

主要支持：

- Debian / Ubuntu
- RHEL / Rocky / CentOS / Fedora
- amd64 / arm64

官方 Hysteria2 Linux 安装脚本本身不支持 OpenWrt；本项目定位是 VPS/普通 Linux 服务端安装。OpenWrt 作为客户端时可直接使用 OpenClash/Mihomo 节点。
