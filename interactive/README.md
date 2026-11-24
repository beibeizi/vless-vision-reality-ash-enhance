# Xray REALITY 交互管理器

管理器内置 `reality_neighbor.sh` 的域名筛选代码，服务安装和维护由交互菜单处理。管理器操作的专用服务为 `xray-reality-managed.service`。本包未在服务器运行，暂未验证服务联机和客户端握手。

## 运行前

- Linux、正在运行的 systemd 247+、系统 Python 3.8+、`ss`（通常来自 iproute2）、有 sudo 权限的交互终端。不是 Windows 原生安装器。
- 可信的 Xray-core 二进制；建议使用与 [官方 REALITY 文档](https://xtls.github.io/en/config/transports/reality.html) 匹配的近期正式版。若核心太旧不支持 `network: raw` 或 `target`，内置配置检查应阻止安装，而不是兼容性试错覆盖现有实例。
- 自动筛选需要支持 HTTP/2 的 `curl`，并需要访问公网 IPv4 查询服务、bgp.he.net、RIPEstat、DNS 和候选域名的 HTTPS 服务。筛选会检查证书、TLS 1.3、ALPN h2 和 HTTP/2 200，并按握手延迟排序。安装前请确认可使用所选 TLS 目标，未通过 REALITY 鉴权的连接可能被转发到该目标。
- [官方 Xray 发布页](https://github.com/XTLS/Xray-core/releases)。可以复用已经装好的可信 Xray，或手动取得适合机器架构的官方包，先通过可信的官方材料验证下载包，再解包并计算二进制自身 SHA-256：`sha256sum /绝对路径/xray`，安装时选择来源 2。管理器校验的摘要是二进制本身，不是 ZIP。只有本地哈希、没有可信对照来源，不足以证明下载真实。脚本从不下载或执行网络安装脚本。

## 启动

在交互终端运行下面命令即可打开菜单。端口在菜单中填写，TLS 域名默认自动获取。

```bash
curl -fsSL https://raw.githubusercontent.com/beibeizi/vless-vision-reality-ash-enhance/main/interactive/reality_manager.sh | sudo bash
```

也可以先保存脚本，再启动菜单。

```bash
curl -fsSLo reality_manager.sh https://raw.githubusercontent.com/beibeizi/vless-vision-reality-ash-enhance/main/interactive/reality_manager.sh && sudo bash reality_manager.sh
```

如果当前网络无法访问 GitHub Raw，可从 GitHub API 下载同一个文件。

```bash
curl -fsSLo reality_manager.sh -H 'Accept: application/vnd.github.raw+json' https://api.github.com/repos/beibeizi/vless-vision-reality-ash-enhance/contents/interactive/reality_manager.sh && sudo bash reality_manager.sh
```

## 菜单

1. **安装专用实例**时，默认监听 TCP 8443。到了 TLS 域名来源提示，按回车使用自动筛选和 GreatFire 查询，或选 `2` 手动填写。找不到合格域名时返回菜单，可以重试或改用手动域名。确认屏幕上的端口和目标后输入 `INSTALL`，管理器会先用 Xray 校验配置再写入。可选的 Xray 私有副本位于 `/opt/xray-reality-managed/`。
2. **状态**：显示两套服务状态和本工具的端口；不打印密钥。旧服务状态只是线索，不能证明来源。
3. **改端口**：保留原密钥与 UUID，输入 `APPLY` 后切换，本来在运行的实例会短暂重启；失败尝试恢复上一工作配置。如果 systemd 本身故障，不保证自动恢复，请在主机终端查看日志。
4. **回滚**：重用上一份专用配置；同样需要确认，并先验证配置及端口。
5. **连接信息**：输入客户端连接的 IP/域名及外部端口，再输入 `SHOW` 才打印含凭据的链接。不要发到公共频道。仅支持这种链接中的域名或 IPv4，服务监听 IPv4，不自动配置 IPv6。
6. **卸载**：输入 `REMOVE` 后只卸载该独立实例，并删除它的配置与已由本工具复制的 Xray。共享 Xray、旧版 `xray.service`、原配置不动。若旧版已经安装，不应盲删：先核对 `systemctl cat xray.service`、配置、drop-in 与其他使用者。两个实例允许不同端口并行；如果要复用旧端口，必须先审计并人工安排切换。

内网端口、NLB 对外 TCP 端口、TLS 目标的 443 是不同概念。公网入口也不一定等于服务器公网 IP。工具不改 UFW、firewalld、云安全规则/NLB、BBR 或 sysctl。启用外部访问前仅按需配置规则；验证内网监听后仍需从真正的入口与客户端做一次握手测试。查看本机服务日志可运行 `sudo journalctl -u xray-reality-managed.service -n 40 --no-pager`，分享前先脱敏。

## GreatFire 大陆访问记录

自动筛选按原版握手延迟排序，先向 GreatFire 查询前 5 个候选的 HTTPS 根网址。如果接口有正常响应、首批没有可优先使用的结果，再查下一批最多 5 个候选。GreatFire 的判定基于其测试窗口，管理器只采用有有效测试、记录未过期且最近一次测试在七天内的明确判定。[GreatFire 数据与 API](https://zh.greatfire.org/data)

- **被阻断**的候选会跳过。查询的候选全部被判定阻断时，返回菜单。
- **未阻断**的候选优先选用，其中握手延迟最低的排在首位。
- 查不到、记录太旧、判定不明确或接口无法连接时，会标为**待确认**。如果没有未阻断的候选，管理器会显示延迟最低的待确认域名，再等你输入 `INSTALL`。
- 菜单会区分无测试记录、请求超时、DNS 解析错误、HTTP 拒绝等情况。首批接口全部失败时，会提示本轮大陆访问记录未核验。

GreatFire 提供的是候选网站的历史 HTTPS 测量。部署后，从实际客户端验证 VPS 入口的 REALITY 握手。

## 维护内置筛选代码

更新原版的 Python 筛选代码后，在仓库根目录运行 `python3 tools/sync_neighbor_scanner.py`。可以加 `--check` 检查两个脚本的筛选代码是否一致。
