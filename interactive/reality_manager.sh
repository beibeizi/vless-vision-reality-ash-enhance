#!/usr/bin/env bash
set -euo pipefail

run_manager() {
    # A pipe carries the script on stdin. Read menu choices from the terminal.
    local menu_input=0
    if [[ $# -eq 0 && ! -t 0 ]]; then
        if ! { exec {menu_input}</dev/tty; } 2>/dev/null; then
            printf '%s\n' '须在交互终端运行。' >&2
            return 1
        fi
    fi

    exec /usr/bin/python3 -I /dev/fd/3 "$@" <&"$menu_input" 3<<'PYTHON' 4<<'NEIGHBOR_SCANNER'
#!/usr/bin/env python3
"""Interactive management of a dedicated Xray REALITY instance on Linux/systemd."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import hashlib
import shutil
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import secrets
from urllib.parse import urlencode

NAME = "xray-reality-managed.service"
UNIT = Path("/etc/systemd/system") / NAME
BASE = Path("/etc/xray-reality-managed")
XDIR = Path("/opt/xray-reality-managed")
XBIN = XDIR / "xray"
CFG = BASE / "config.json"
BACK = BASE / "config.previous.json"
MARK = BASE / ".owned"
SIGN = "reality-manager/v1\n"
HDR = "# Managed by reality-manager/v1\n"
PORT_RE = re.compile(r"[0-9]{1,5}\Z")
HOST_RE = re.compile(r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
BIN_RE = re.compile(r"/[A-Za-z0-9_./-]+\Z")
KEY_RE = re.compile(r"[A-Za-z0-9_-]{43}\Z")
GREATFIRE_URL = "https://zh.greatfire.org/api/url/https/"
GREATFIRE_CANDIDATES = 5
GREATFIRE_MAX_AGE = timedelta(days=7)
os.environ["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
os.umask(0o077)


def cmd(*argv, check=True):
    r = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=35)
    if check and r.returncode:
        raise RuntimeError(f"{Path(argv[0]).name} {argv[1] if len(argv)>1 else ''} 失败（{r.returncode}）")
    return r


def sc(*argv, check=True):
    return cmd("systemctl", *argv, check=check)


def owned(path, directory=False, private=True):
    try:
        s = path.lstat()
        kind = stat.S_ISDIR if directory else stat.S_ISREG
        return kind(s.st_mode) and s.st_uid == 0 and not s.st_mode & (0o077 if private else 0o022)
    except FileNotFoundError:
        return False


def managed():
    return owned(BASE, True) and owned(MARK) and MARK.read_text() == SIGN and owned(CFG) and owned(UNIT, private=False) and UNIT.read_text().startswith(HDR)


def load_cfg(path=CFG):
    if not owned(path):
        raise RuntimeError("配置不是受保护的常规文件")
    return json.loads(path.read_text())


def atomic(path, content, mode=0o600):
    fd, raw = tempfile.mkstemp(prefix=".reality-manager-", dir=path.parent)
    tmp = Path(raw)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fchmod(f.fileno(), mode)
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def js(data):
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def choice(label, default=""):
    return (input(f"{label}" + (f" [{default}]" if default else "") + "：").strip() or default)


def port_query(default="8443"):
    p = choice("监听 TCP 端口", default)
    if not PORT_RE.fullmatch(p) or not 1 <= int(p) <= 65535:
        raise ValueError("端口须在 1–65535")
    return int(p)


def busy(p):
    return bool(cmd("ss", "-H", "-ltn", f"sport = :{p}").stdout.strip())


def greatfire_status(domain):
    try:
        reply = cmd(
            "curl", "--disable", "--fail", "--silent", "--max-time", "5",
            "--max-filesize", "65536", "--header", "Accept: application/json",
            GREATFIRE_URL + domain, check=False,
        )
        if reply.returncode:
            return None, "待确认（GreatFire 接口请求失败）"
        data = json.loads(reply.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None, "待确认（GreatFire 接口请求或解析失败）"

    expected_url = f"https://{domain}"
    if not isinstance(data, dict) or data.get("url") not in (expected_url, expected_url + "/"):
        return None, "待确认（GreatFire 返回的网址不匹配）"
    count = data.get("conclusions")
    if data.get("found") is not True or type(count) is not int or count < 1:
        return None, "待确认（无有效测试记录）"

    last_tested = data.get("last_tested")
    if data.get("stale") is not False or not isinstance(last_tested, str):
        return None, "待确认（测试记录过期或缺少时间）"
    try:
        age = datetime.now(timezone.utc) - datetime.fromisoformat(last_tested.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None, "待确认（测试时间无效）"
    if not timedelta(0) <= age <= GREATFIRE_MAX_AGE:
        return None, "待确认（最近测试不在七天内）"

    verdict = data.get("verdict")
    if verdict == "blocked":
        return verdict, "跳过（GreatFire 判定被阻断）"
    if verdict == "not blocked":
        return verdict, "优先（GreatFire 判定未阻断）"
    return None, "待确认（GreatFire 无明确可访问结论）"


def choose_greatfire_domain(domains):
    print(f"正在查询前 {len(domains)} 个候选的 GreatFire 大陆访问记录…")
    with ThreadPoolExecutor(max_workers=len(domains)) as workers:
        results = list(workers.map(greatfire_status, domains))

    available, pending = [], []
    for domain, (verdict, detail) in zip(domains, results):
        print(f"  {domain}  {detail}")
        if verdict == "not blocked":
            available.append(domain)
        elif verdict != "blocked":
            pending.append(domain)

    if available:
        return available[0]
    if pending:
        print(f"按原版延迟顺序选出待确认域名 {pending[0]}，请核对后再确认安装。")
        return pending[0]
    raise RuntimeError("本次查询的候选均被 GreatFire 判定阻断，可重新筛选或手动填写")


def automatic_domain(scanner):
    if not shutil.which("curl") or not re.search(r"^Features:.*\bHTTP2\b", cmd("curl", "--version").stdout, re.M):
        raise RuntimeError("自动筛选需要支持 HTTP/2 的 curl")

    with tempfile.TemporaryDirectory(prefix="reality-neighbor-") as stage:
        result = Path(stage) / "result.json"
        try:
            scan = subprocess.run(
                [sys.executable, "-I", "-u", "-", "80", str(result)],
                input=scanner, encoding="utf-8", timeout=180,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("自动筛选超时，可重新尝试或手动填写 TLS 域名") from None
        if scan.returncode in (2, 3):
            raise RuntimeError("未找到合格的 TLS 域名，可重新筛选或手动填写")
        if scan.returncode:
            raise RuntimeError("自动筛选未完成，请检查服务器的公网与 DNS 连通性")
        ranked = json.loads(result.read_text(encoding="utf-8"))["all_valid"]

    domains = [item["domain"] for item in ranked if HOST_RE.fullmatch(item["domain"])]
    if not domains:
        raise RuntimeError("自动筛选未返回格式有效的 TLS 域名")
    return choose_greatfire_domain(domains[:GREATFIRE_CANDIDATES])


def domain_query(scanner):
    source = choice("TLS 域名来源（1 自动筛选并查询 GreatFire，2 手动填写）", "1")
    if source == "1":
        return automatic_domain(scanner)
    if source != "2":
        raise ValueError("无效的 TLS 域名来源选项")
    domain = choice("你控制或已获授权使用的 TLS 域名（不含协议、端口）").lower()
    if not HOST_RE.fullmatch(domain):
        raise ValueError("请输入域名，例如 tls.example.org；国际域名请用 Punycode")
    return domain


def binary(raw):
    if not BIN_RE.fullmatch(raw):
        raise ValueError("Xray 路径须是绝对路径，且不含空格")
    path = Path(raw).resolve(strict=True)
    if not BIN_RE.fullmatch(str(path)) or not owned(path, private=False) or not os.access(path, os.X_OK):
        raise ValueError("Xray 必须是 root 所有、不可被组或其他用户写入的可执行文件")
    if any(not owned(parent, True, private=False) for parent in path.parents):
        raise ValueError("Xray 路径的每级目录必须由 root 所有且不可被组或其他用户写入")
    return str(path)


def registered_binary():
    matches = re.findall(r"^ExecStart=(\S+) run -config %d/config\.json$", UNIT.read_text(), re.M)
    if len(matches) != 1:
        raise RuntimeError("服务启动项与本脚本预期不符")
    return binary(matches[0])


def key(label, vals):
    for line in vals.splitlines():
        name, _, value = line.partition(":")
        if name.lower().replace(" ", "") in label and KEY_RE.fullmatch(value.strip()):
            return value.strip()
    raise RuntimeError("无法解析 Xray 密钥输出；未显示原始密钥")


def validate(exe, data):
    with tempfile.TemporaryDirectory(prefix="reality-config-") as d:
        path = Path(d) / "config.json"
        atomic(path, js(data))
        cmd(exe, "run", "-test", "-config", str(path))


def activated(port):
    for _ in range(8):
        time.sleep(.35)
        if not sc("is-active", "--quiet", NAME, check=False).returncode:
            time.sleep(.55)
            if not sc("is-active", "--quiet", NAME, check=False).returncode and busy(port):
                return
    raise RuntimeError("专用实例未稳定进入 active 或未看到监听端口；请在本机检查服务日志")


def unit(exe):
    return HDR + f"""[Unit]
Description=Dedicated Xray REALITY instance
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
LoadCredential=config.json:{CFG}
ExecStart={exe} run -config %d/config.json
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
"""


def existing_paths():
    return any(os.path.lexists(p) for p in (BASE, UNIT, XDIR))


def stage_binary(directory):
    src = Path(choice("已解压的官方 Xray 二进制文件绝对路径"))
    want = choice("你独立验证过的该二进制文件 SHA-256（不是 ZIP 的哈希）").lower()
    if not src.is_absolute() or not re.fullmatch(r"[a-f0-9]{64}", want):
        raise ValueError("需要二进制绝对路径和 64 位十六进制 SHA-256")
    dest = Path(directory) / "xray"
    fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream, dest.open("xb") as output:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 100 * 1024 * 1024:
            raise ValueError("Xray 文件必须是 100 MiB 以内的常规文件")
        digest, total = hashlib.sha256(), 0
        while (part := stream.read(65536)):
            total += len(part)
            if total > 100 * 1024 * 1024:
                raise ValueError("Xray 文件超过 100 MiB")
            digest.update(part)
            output.write(part)
    if not secrets.compare_digest(digest.hexdigest(), want):
        raise ValueError("二进制 SHA-256 不一致；未执行或安装该文件")
    dest.chmod(0o700)
    return str(dest)


def add(scanner):
    with tempfile.TemporaryDirectory(prefix="reality-install-") as stage:
        provision(stage, scanner)


def provision(stage, scanner):
    if existing_paths() or sc("show", "-p", "LoadState", "--value", NAME, check=False).stdout.strip() != "not-found":
        raise RuntimeError("专用路径或同名服务已经存在；不会覆盖或接管")
    ver = cmd("systemctl", "--version").stdout.splitlines()[0]
    m = re.match(r"systemd (\d+)", ver)
    if not m or int(m[1]) < 247:
        raise RuntimeError("需要 systemd 247+（LoadCredential）")
    option = choice("二进制来源：1 复用已安装可信 Xray；2 安装手动验真的官方文件", "1")
    if option not in {"1", "2"}:
        raise ValueError("无效来源选项")
    exe = binary(choice("已安装、可信的 Xray 可执行文件", "/usr/local/bin/xray")) if option == "1" else stage_binary(stage)
    p = port_query()
    if busy(p):
        raise RuntimeError(f"TCP {p} 已被占用")
    target = domain_query(scanner)
    print(f"将创建专用服务 {NAME}，监听 0.0.0.0:{p}，TLS 目标 {target}:443。")
    if choice("输入 INSTALL 确认") != "INSTALL":
        print("已取消"); return
    vals = cmd(exe, "x25519").stdout
    private = key({"privatekey"}, vals)
    public = key({"publickey", "password", "password(publickey)"}, vals)
    ident, sid = str(uuid.uuid4()), secrets.token_hex(8)
    cfg = {"log":{"loglevel":"warning"},"inbounds":[{"listen":"0.0.0.0","port":p,"protocol":"vless",
        "settings":{"clients":[{"id":ident,"flow":"xtls-rprx-vision"}],"decryption":"none"},
        "streamSettings":{"network":"raw","security":"reality","realitySettings":{
            "show":False,"target":target+":443","xver":0,"serverNames":[target],
            "privateKey":private,"shortIds":[sid]}}}],"outbounds":[{"protocol":"freedom"}]}
    validate(exe, cfg)
    if busy(p):
        raise RuntimeError(f"TCP {p} 在确认期间被占用")
    BASE.mkdir(mode=0o700)
    copied = False
    try:
        if option == "2":
            if not owned(XDIR.parent, True, private=False):
                raise RuntimeError("/opt 不是受保护的目录")
            XDIR.mkdir(mode=0o755)
            XDIR.chmod(0o755)
            copied = True
            shutil.copyfile(exe, XBIN)
            XBIN.chmod(0o755)
            exe = str(XBIN)
        atomic(MARK, SIGN)
        atomic(CFG, js(cfg))
        atomic(BASE / "client-public.key", public + "\n")
        atomic(UNIT, unit(exe), 0o644)
        sc("daemon-reload")
        sc("enable", "--now", NAME)
        activated(p)
    except BaseException:
        # Never erase files if systemd cannot confirm it released the unit.
        if not UNIT.exists() or sc("disable", "--now", NAME, check=False).returncode == 0:
            UNIT.unlink(missing_ok=True)
            for path in (CFG, MARK, BASE / "client-public.key"):
                path.unlink(missing_ok=True)
            BASE.rmdir()
            if copied:
                XBIN.unlink(missing_ok=True)
                XDIR.rmdir()
            sc("daemon-reload", check=False)
        else:
            print("自动清理未完成；保留配置，请先检查该专用服务。", file=sys.stderr)
        raise
    print("已启用专用实例。用菜单第 5 项显示客户端配置。")


def inbound(data):
    entries = data["inbounds"]
    if len(entries) != 1 or entries[0].get("protocol") != "vless":
        raise ValueError("配置已偏离单入站结构，停止管理")
    return entries[0]


def update(restore=False):
    exe = registered_binary()
    old = load_cfg()
    old_port = inbound(old)["port"]
    if restore:
        new = load_cfg(BACK)
    else:
        new = load_cfg()
        port = port_query(str(old_port))
        if port == old_port:
            print("端口未变"); return
        inbound(new)["port"] = port
    port = inbound(new)["port"]
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("目标端口无效")
    if port != old_port and busy(port):
        raise RuntimeError(f"TCP {port} 已被占用")
    print(f"TCP {old_port} → {port}；操作会短暂重启专用实例。")
    if choice("输入 APPLY 确认") != "APPLY":
        print("已取消"); return
    was_active = not sc("is-active", "--quiet", NAME, check=False).returncode
    validate(exe, new)
    if port != old_port and busy(port):
        raise RuntimeError(f"TCP {port} 在确认期间被占用")
    prior = BACK.read_text() if owned(BACK) else None
    if os.path.lexists(BACK) and prior is None:
        raise RuntimeError("备份路径异常")
    atomic(BACK, js(old))
    try:
        atomic(CFG, js(new))
        if was_active:
            sc("restart", NAME)
            activated(port)
    except BaseException:
        atomic(CFG, js(old))
        if prior is None:
            BACK.unlink(missing_ok=True)
        else:
            atomic(BACK, prior)
        if was_active:
            sc("restart", NAME)
            activated(old_port)
        raise
    print("新配置已保存。" if not was_active else "新配置已保存，专用实例 active。")


def uninstall():
    known = {CFG.name, BACK.name, MARK.name, "client-public.key"}
    unknown = {p.name for p in BASE.iterdir()} - known
    if unknown:
        raise RuntimeError("配置目录含未知文件；先人工检查，不递归删除")
    private_bin = registered_binary() == str(XBIN) if os.path.lexists(XDIR) else False
    if os.path.lexists(XDIR) and (
        not private_bin or not owned(XDIR, True, private=False) or
        {p.name for p in XDIR.iterdir()} != {XBIN.name}
    ):
        raise RuntimeError("专用二进制目录异常，不自动删除")
    print("只移除专用服务、专用配置和专用 Xray 副本；不删除共享 Xray、旧服务和防火墙规则。")
    if choice("输入 REMOVE 确认") != "REMOVE":
        print("已取消"); return
    sc("disable", "--now", NAME)
    UNIT.unlink()
    for name in known:
        (BASE / name).unlink(missing_ok=True)
    BASE.rmdir()
    if private_bin:
        XBIN.unlink()
        XDIR.rmdir()
    sc("daemon-reload")
    print("专用实例已卸载。")


def client():
    target = choice("客户端连接的服务器域名或 IPv4（NLB 场景填入口）")
    if not HOST_RE.fullmatch(target.lower()):
        raise ValueError("请输入域名或 IPv4")
    p = BASE / "client-public.key"
    if not owned(p) or not KEY_RE.fullmatch(p.read_text().strip()):
        raise RuntimeError("找不到有效的公钥")
    i = inbound(load_cfg())
    s = i["streamSettings"]["realitySettings"]
    q = urlencode(dict(encryption="none",flow="xtls-rprx-vision",security="reality",
                     sni=s["serverNames"][0],fp="chrome",pbk=p.read_text().strip(),sid=s["shortIds"][0],type="tcp"))
    ext = choice("客户端连接端口（可与本机端口不同）", str(i["port"]))
    if not PORT_RE.fullmatch(ext) or not 1 <= int(ext) <= 65535:
        raise ValueError("入口端口须在 1–65535")
    if choice("分享链接包含访问凭据；输入 SHOW 显示") == "SHOW":
        print(f"vless://{i['settings']['clients'][0]['id']}@{target}:{int(ext)}?{q}#reality-managed")


def status():
    for name in (NAME, "xray.service"):
        r = sc("show", "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState", "--", name, check=False)
        print(name + ":", " ".join(r.stdout.splitlines()) or "无法读取")
    if managed():
        print("管理器监听 TCP：", inbound(load_cfg())["port"])
    elif existing_paths():
        print("专用文件不完整或不匹配；不会接管。")
    legacy_config = Path("/usr/local/etc/xray/config.json")
    if os.path.lexists(legacy_config):
        print("发现传统配置路径 /usr/local/etc/xray/config.json（未读取内容，来源未确认）。")
    print("旧版 xray.service 只读查看，不关停、不卸载。")


def main():
    if sys.argv[1:] in (["-h"], ["--help"]):
        print("用法：sudo bash reality_manager.sh（Linux + systemd 247+ / Python 3.8+；需可信 Xray 文件）")
        return
    if sys.argv[1:] or not sys.stdin.isatty():
        raise RuntimeError("须在交互终端运行，不接受自动安装参数")
    if os.geteuid() != 0 or not Path("/run/systemd/system").is_dir():
        raise RuntimeError("须在使用 systemd 的 Linux 中以 root 运行")
    for path in (UNIT.parent, BASE.parent, Path("/run")):
        if not owned(path, True, private=False):
            raise RuntimeError(f"管理路径父目录不安全：{path}")
    fd = os.open("/run/xray-reality-manager.lock", os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_RDWR, 0o600)
    with os.fdopen(fd, "r+") as lock:
        fd_info = os.fstat(lock.fileno())
        if not stat.S_ISREG(fd_info.st_mode) or fd_info.st_uid != 0 or fd_info.st_mode & 0o077:
            raise RuntimeError("锁文件不是受保护的常规文件")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with os.fdopen(4, encoding="utf-8") as scanner_file:
            scanner = scanner_file.read()
        while True:
            print("\n1 安装专用实例  2 查看状态  3 更改端口  4 回滚配置\n5 显示连接信息  6 卸载专用实例  0 退出")
            try:
                n = choice("请选择", "0")
                if n == "0": return
                if n == "1": add(scanner)
                elif n == "2": status()
                elif n in {"3","4","5","6"}:
                    if not managed():
                        raise RuntimeError("没有完整的本脚本管理实例；不会操作旧服务")
                    {"3":update,"4":lambda:update(True),"5":client,"6":uninstall}[n]()
                else: print("无效选项")
            except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
                # Do not print tracebacks, subprocess stdout or stderr; may contain secrets.
                print(f"操作未完成：{e}", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        print("\n已退出")
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:
        print(f"无法运行：{e}", file=sys.stderr)
        sys.exit(1)
PYTHON
# Generated from reality_neighbor.sh by tools/sync_neighbor_scanner.py.
import sys
import re
import json
import time
import socket
import ssl
import ipaddress
import urllib.request
import urllib.parse
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed

MAX_CANDIDATES = int(sys.argv[1]) if len(sys.argv) > 1 else 80
RESULT_FILE = sys.argv[2] if len(sys.argv) > 2 else "/tmp/reality_best_domain.json"

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# 常见 Cloudflare IPv4 网段 (双重防套 CF 检测)
CF_NETS = [ipaddress.ip_network(cidr) for cidr in [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"
]]

def http_get(url, timeout=10):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json, text/html, */*"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="ignore")

def get_public_ipv4():
    endpoints = [
        "https://api.ipify.org",
        "https://ipv4.icanhazip.com",
        "https://v4.ident.me",
        "https://ifconfig.me/ip"
    ]
    for url in endpoints:
        try:
            ip_str = http_get(url, timeout=5).strip()
            ip_obj = ipaddress.ip_address(ip_str)
            if isinstance(ip_obj, ipaddress.IPv4Address):
                return ip_str
        except Exception:
            continue
    raise RuntimeError("无法获取当前 Linux 主机的公网 IPv4 地址")

def get_asn_and_prefixes(ip_str):
    """
    通过 bgp.he.net 和 RIPEstat 获取当前 IP 的所属 ASN、机构名称以及所在号段 (BGP Prefix)
    """
    asns = []
    prefixes = []
    asn_descs = {}

    # 1. 从 bgp.he.net/ip/<IP> 提取 (与文章步骤完全一致)
    try:
        html = http_get(f"https://bgp.he.net/ip/{ip_str}", timeout=10)
        # 匹配形如: <td><a href="/AS35916">AS35916</a></td><td class="nowrap"><a href="/net/142.171.0.0/16">142.171.0.0/16</a>...</td><td>MULTACOM CORPORATION</td>
        row_pattern = re.compile(
            r'href="/AS(\d+)"[^>]*>AS\d+</a>.*?href="/net/([0-9\./]+)"[^>]*>[0-9\./]+</a>.*?</td>\s*<td>([^<]+)</td>',
            re.S
        )
        for m in row_pattern.finditer(html):
            asn, pfx, desc = m.group(1), m.group(2).strip(), m.group(3).strip()
            if asn not in asns:
                asns.append(asn)
            if pfx not in prefixes:
                prefixes.append(pfx)
            asn_descs[asn] = desc
    except Exception as e:
        pass

    # 2. 补充从 RIPEstat BGP API 获取精确 ASN 与 Prefix (防止 bgp.he.net 偶发拦截)
    try:
        ripe_json = json.loads(http_get(f"https://stat.ripe.net/data/network-info/data.json?resource={ip_str}", timeout=8))
        data = ripe_json.get("data", {})
        for a in data.get("asns", []):
            if str(a) not in asns:
                asns.append(str(a))
        pfx = data.get("prefix")
        if pfx and pfx not in prefixes:
            prefixes.append(pfx)
    except Exception:
        pass

    # 构造同 /24 网段
    ip_obj = ipaddress.ip_address(ip_str)
    net24 = str(ipaddress.ip_network(f"{ip_str}/24", strict=False))
    if net24 not in prefixes:
        prefixes.insert(0, net24)
    else:
        # 确保更精确的网段排在前面优先扫，同时保留大网段补充
        prefixes.sort(key=lambda x: ipaddress.ip_network(x, strict=False).prefixlen, reverse=True)

    return asns, asn_descs, prefixes

def fetch_neighbor_domains_from_bgphe(prefixes):
    """
    调用 bgp.he.net 的 Certs 接口 (/certs/api/ip-search?ip=<prefix>) 获取同网段邻居证书中的所有域名
    同时补充 /net/<prefix> 页面中的反向 DNS (A/PTR) 记录
    """
    domain_to_bgp_ips = {}

    for pfx in prefixes:
        # 避免扫超过 /16 的超大段导致超时；如果前缀小于 /18，将其收敛到包含本机的 /20 或 /18
        try:
            net_obj = ipaddress.ip_network(pfx, strict=False)
            if net_obj.prefixlen < 18:
                continue
        except Exception:
            continue

        try:
            api_url = f"https://bgp.he.net/certs/api/ip-search?ip={urllib.parse.quote(pfx)}"
            raw = http_get(api_url, timeout=12)
            data = json.loads(raw)
            entries = data.get("entries", [])
            for entry in entries:
                entry_ip = entry.get("ip", "")
                for h in entry.get("hostnames", []):
                    h = h.strip().lower().lstrip("*.")
                    if not h or "." not in h:
                        continue
                    domain_to_bgp_ips.setdefault(h, set()).add(entry_ip)
        except Exception:
            pass

        # 如果从小段 (/24) 拿到的候选域名已经超过 150 个，就不必继续拉取更大的段；否则继续拉取上级 BGP 段
        if len(domain_to_bgp_ips) >= 150:
            break

    return domain_to_bgp_ips

def is_good_domain_format(domain):
    """
    过滤掉不合格的域名格式，并按文章要求给短的、靓的 com/net 域名打高分
    """
    if not re.match(r'^[a-z0-9][a-z0-9\.\-]{1,61}[a-z0-9]\.[a-z]{2,}$', domain):
        return False
    # 排除纯数字或含 IP 地址格式的自动域名 / nip.io / sslip.io / traefik / 面板或邮件逆向域名
    bad_keywords = [
        "nip.io", "sslip.io", "xip.io", "local", "localhost", "arpa",
        "cpanel", "webmail", "whm.", "autodiscover", "autoconfig",
        "mail.", "smtp.", "pop.", "imap.", "mx.", "ns1.", "ns2."
    ]
    for kw in bad_keywords:
        if kw in domain:
            return False
    # 排除包含连续 3 段以上 IP 数字的生成式主机名
    if re.search(r'\d{1,3}[\-\.]\d{1,3}[\-\.]\d{1,3}', domain):
        return False
    return True

def domain_priority_key(domain):
    """
    文章要求：首选短的、靓的 com、net 域名
    返回值越小优先级越高
    """
    tld_rank = 2
    if domain.endswith(".com"):
        tld_rank = 0
    elif domain.endswith(".net"):
        tld_rank = 1
    elif domain.endswith(".org"):
        tld_rank = 2
    else:
        tld_rank = 3
    parts = domain.split(".")
    return (tld_rank, len(parts), len(domain))

def is_cloudflare_ip(ip_str):
    try:
        ip_obj = ipaddress.ip_address(ip_str)
        return any(ip_obj in net for net in CF_NETS)
    except Exception:
        return False

def check_candidate_domain(domain, allowed_networks, my_ip):
    """
    严格按文章第 二 节执行校验：
    1. DNS 解析校验 (相当于 ping 目标域名)：
       - 解析出的 IPv4 不能是 Cloudflare CDN IP
       - 解析出的 IPv4 必须落在我们从 bgp.he.net 查到的同机房 BGP 网段内
    2. 协议与状态校验 (执行文章同款 curl 命令 + Python OpenSSL 底层握手校验)：
       curl -I -v --tlsv1.3 --http2 https://目标域名
       - 必须支持 TLSv1.3 (SSL connection using TLSv1.3)
       - ALPN 必须协商为 h2 (ALPN: server accepted h2 / using HTTP/2)
       - 状态码必须是 HTTP/2 200 (直接返回网页内容，非 301/302 跳转)
       - 证书必须有效 (未过期且主机名匹配)
    3. 测量真实 TCP + TLS 1.3 握手延迟 (ms)
    """
    # Step 1: DNS 解析
    try:
        infos = socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
        resolved_ips = list({info[4][0] for info in infos})
    except Exception:
        return None

    if not resolved_ips:
        return None

    # 取第一个 IPv4 进行网段归属与非 CF 校验
    target_ip = resolved_ips[0]
    if target_ip == my_ip:
        return None
    if is_cloudflare_ip(target_ip):
        return None

    try:
        ip_obj = ipaddress.ip_address(target_ip)
        in_same_net = any(ip_obj in net for net in allowed_networks)
        if not in_same_net:
            return None
    except Exception:
        return None

    # Step 2a: 使用 Python ssl 模块直接进行底层 TLSv1.3 + ALPN(h2) + 证书有效性校验与毫秒级握手测速
    try:
        ctx = ssl.create_default_context()
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.set_alpn_protocols(["h2", "http/1.1"])

        t_start = time.monotonic()
        with socket.create_connection((target_ip, 443), timeout=3.5) as raw_sock:
            with ctx.wrap_socket(raw_sock, server_hostname=domain) as ssl_sock:
                handshake_ms = (time.monotonic() - t_start) * 1000.0
                tls_ver = ssl_sock.version()
                alpn_proto = ssl_sock.selected_alpn_protocol()
                cipher_info = ssl_sock.cipher()
                cipher_name = cipher_info[0] if cipher_info else "TLS_AES_256_GCM_SHA384"

        if tls_ver != "TLSv1.3" or alpn_proto != "h2":
            return None
    except Exception:
        return None

    # Step 2b: 调用文章同款 curl 命令验证 HTTP/2 状态码必须是 200 (非 301/302 跳转)
    import os
    env = os.environ.copy()
    # 兼容 macOS SecureTransport
    if sys.platform == "darwin":
        env["CURL_SSL_BACKEND"] = "libressl"

    cmd = [
        "curl", "-I", "-v", "--tlsv1.3", "--http2",
        "--connect-timeout", "4", "--max-time", "6",
        "-A", UA,
        f"https://{domain}"
    ]
    try:
        t0 = time.monotonic()
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=7, env=env)
        elapsed_ms = (time.monotonic() - t0) * 1000.0
        output = proc.stdout or ""
    except Exception:
        return None

    if proc.returncode != 0:
        return None

    # 校验状态码必须是 HTTP/2 200 (非 301/302 跳转)
    if not re.search(r"<\s*HTTP/2\s+200\b", output, re.I):
        return None

    # 二次确认响应头中不含 Server: cloudflare
    if re.search(r"<\s*server:\s*cloudflare", output, re.I):
        return None

    tls_line = f"SSL connection using {tls_ver} / {cipher_name}"
    alpn_line = "ALPN: server accepted h2"

    return {
        "domain": domain,
        "ip": target_ip,
        "latency_ms": round(handshake_ms, 2),
        "total_ms": round(elapsed_ms, 2),
        "tls_info": tls_line,
        "alpn_info": alpn_line,
        "http_status": "HTTP/2 200",
        "is_com_net": domain.endswith(".com") or domain.endswith(".net")
    }

def main():
    print("\033[0;36m[1/4] 正在查询当前 Linux 主机的公网 IP 与所属 ASN / BGP 号段...\033[0m")
    my_ip = get_public_ipv4()
    asns, asn_descs, prefixes = get_asn_and_prefixes(my_ip)

    asn_str = ", ".join([f"AS{a} ({asn_descs.get(a, 'Unknown')})" for a in asns]) if asns else "Unknown ASN"
    print(f"  ├─ 本机公网 IP  : \033[1;32m{my_ip}\033[0m")
    print(f"  ├─ 所属 ASN     : \033[1;32m{asn_str}\033[0m")
    print(f"  └─ 关联 BGP 号段: \033[1;33m{', '.join(prefixes)}\033[0m")

    print("\n\033[0;36m[2/4] 正在从 bgp.he.net (Certs 证书透明度数据库) 检索同网段邻居域名...\033[0m")
    domain_map = fetch_neighbor_domains_from_bgphe(prefixes)
    all_raw_domains = list(domain_map.keys())
    print(f"  ├─ 共检索到原始邻居证书域名: \033[1m{len(all_raw_domains)}\033[0m 个")

    # 过滤掉不合格格式并按 (.com/.net 优先、短域名优先) 排序
    filtered_domains = [d for d in all_raw_domains if is_good_domain_format(d)]
    filtered_domains.sort(key=domain_priority_key)
    candidates = filtered_domains[:MAX_CANDIDATES]
    print(f"  └─ 格式初筛后保留优质候选域名: \033[1m{len(candidates)}\033[0m 个 (优先短 com/net 域名)")

    if not candidates:
        print("\033[0;31m[!] 当前网段在 bgp.he.net Certs 中未找到合适候选域名。\033[0m")
        sys.exit(2)

    # 允许的同机房网段列表 (用于验证 ping/DNS 解析出的 IP 确实在同网段，未套 CF CDN)
    allowed_networks = []
    for p in prefixes:
        try:
            allowed_networks.append(ipaddress.ip_network(p, strict=False))
        except Exception:
            pass

    print(f"\n\033[0;36m[3/4] 正在并发校验候选域名 (TLSv1.3 + ALPN h2 + HTTP/2 200 + 同网段非CDN + 握手延迟测速)...\033[0m")
    valid_results = []
    with ThreadPoolExecutor(max_workers=16) as executor:
        future_to_dom = {
            executor.submit(check_candidate_domain, dom, allowed_networks, my_ip): dom
            for dom in candidates
        }
        done_cnt = 0
        total_cnt = len(candidates)
        for future in as_completed(future_to_dom):
            done_cnt += 1
            res = future.result()
            if res:
                valid_results.append(res)
                print(
                    f"  \033[0;32m✓ [合格]\033[0m {res['domain']:<32} "
                    f"IP: {res['ip']:<15} TLS握手延迟: \033[1;32m{res['latency_ms']} ms\033[0m "
                    f"({res['http_status']}, h2, TLSv1.3)"
                )

    if not valid_results:
        print("\033[0;31m[!] 未能在当前网段筛选出同时满足 TLSv1.3 + H2 + HTTP 200 + 未套 CDN 的域名。\033[0m")
        sys.exit(3)

    # 按延迟从低到高排序 (满足用户“另外还要延迟最低的那个”要求)
    valid_results.sort(key=lambda x: (x["latency_ms"], 0 if x["is_com_net"] else 1, len(x["domain"])))
    best = valid_results[0]

    print(f"\n\033[0;36m[4/4] 筛选完成！共找到 {len(valid_results)} 个完全符合规范的邻居域名 (按延迟从低到高 Top 10)：\033[0m")
    print("  " + "-" * 86)
    print(f"  {'排名':<4} {'域名 (SNI / Target)':<32} {'解析 IP (同网段)':<16} {'TLS握手延迟':<12} {'协议验证'}")
    print("  " + "-" * 86)
    for idx, item in enumerate(valid_results[:10], 1):
        star = "★ 最优" if idx == 1 else f"#{idx}"
        color = "\033[1;32m" if idx == 1 else ""
        endc = "\033[0m" if idx == 1 else ""
        print(
            f"  {color}{star:<6} {item['domain']:<32} {item['ip']:<16} "
            f"{str(item['latency_ms']) + ' ms':<12} TLSv1.3 | ALPN: h2 | HTTP/2 200{endc}"
        )
    print("  " + "-" * 86)

    output_payload = {
        "my_ip": my_ip,
        "asns": asns,
        "asn_descs": asn_descs,
        "prefixes": prefixes,
        "best": best,
        "all_valid": valid_results
    }
    with open(RESULT_FILE, "w", encoding="utf-8") as f:
        json.dump(output_payload, f, ensure_ascii=False, indent=2)

if __name__ == "__main__":
    main()
NEIGHBOR_SCANNER
}

run_manager "$@"
