# Xray REALITY 交互管理器

这是独立重写的管理器，不会调用或执行旧 `reality_neighbor.sh`。它只管理自己创建的 `xray-reality-managed.service`。本包未在服务器运行，暂未验证服务联机和客户端握手。

## 运行前

- Linux、正在运行的 systemd 247+、系统 Python 3.8+、`ss`（通常来自 iproute2）、有 sudo 权限的交互终端。不是 Windows 原生安装器。
- 可信的 Xray-core 二进制；建议使用与 [官方 REALITY 文档](https://xtls.github.io/en/config/transports/reality.html) 匹配的近期正式版。若核心太旧不支持 `network: raw` 或 `target`，内置配置检查应阻止安装，而不是兼容性试错覆盖现有实例。
- 原样保留这两个脚本，核对来源后再运行。请选择自己控制或已获授权的 TLS 域名，确认目标 :443 的证书与 SNI 匹配，支持 TLS 1.3、HTTP/2；本工具不探测第三方站点。未通过 REALITY 鉴权的连接可能被转发到配置目标，不要将它指向未经授权的网站。
- [官方 Xray 发布页](https://github.com/XTLS/Xray-core/releases)。可以复用已经装好的可信 Xray，或手动取得适合机器架构的官方包，先通过可信的官方材料验证下载包，再解包并计算二进制自身 SHA-256：`sha256sum /绝对路径/xray`，安装时选择来源 2。管理器校验的摘要是二进制本身，不是 ZIP。只有本地哈希、没有可信对照来源，不足以证明下载真实。脚本从不下载或执行网络安装脚本。

```bash
sudo bash reality_manager.sh
```

## 菜单

1. **安装**：默认 TCP 8443，也可输入其他端口。端口被占用就中止，绝不杀进程或停别的服务。明确输入 `INSTALL` 后写入；写入前由 Xray 校验配置。可选的 Xray 私有副本位于 `/opt/xray-reality-managed/`。
2. **状态**：显示两套服务状态和本工具的端口；不打印密钥。旧服务状态只是线索，不能证明来源。
3. **改端口**：保留原密钥与 UUID，输入 `APPLY` 后切换，本来在运行的实例会短暂重启；失败尝试恢复上一工作配置。如果 systemd 本身故障，不保证自动恢复，请在主机终端查看日志。
4. **回滚**：重用上一份专用配置；同样需要确认，并先验证配置及端口。
5. **连接信息**：输入客户端连接的 IP/域名及外部端口，再输入 `SHOW` 才打印含凭据的链接。不要发到公共频道。仅支持这种链接中的域名或 IPv4，服务监听 IPv4，不自动配置 IPv6。
6. **卸载**：输入 `REMOVE` 后只卸载该独立实例，并删除它的配置与已由本工具复制的 Xray。共享 Xray、旧版 `xray.service`、原配置不动。若旧版已经安装，不应盲删：先核对 `systemctl cat xray.service`、配置、drop-in 与其他使用者。两个实例允许不同端口并行；如果要复用旧端口，必须先审计并人工安排切换。

内网端口、NLB 对外 TCP 端口、TLS 目标的 443 是不同概念。公网入口也不一定等于服务器公网 IP。工具不改 UFW、firewalld、云安全规则/NLB、BBR 或 sysctl，不自动扫描同 ASN 第三方域名。启用外部访问前仅按需配置规则；验证内网监听后仍需从真正的入口与客户端做一次握手测试。查看本机服务日志可运行 `sudo journalctl -u xray-reality-managed.service -n 40 --no-pager`，分享前先脱敏。
