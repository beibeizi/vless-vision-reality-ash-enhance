#!/usr/bin/env python3
"""Interactive management of a dedicated Xray REALITY instance on Linux/systemd."""
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


def domain_query():
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


def add():
    with tempfile.TemporaryDirectory(prefix="reality-install-") as stage:
        provision(stage)


def provision(stage):
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
    target = domain_query()
    if busy(p):
        raise RuntimeError(f"TCP {p} 已被占用")
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
        while True:
            print("\n1 安装专用实例  2 查看状态  3 更改端口  4 回滚配置\n5 显示连接信息  6 卸载专用实例  0 退出")
            try:
                n = choice("请选择", "0")
                if n == "0": return
                if n == "1": add()
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
