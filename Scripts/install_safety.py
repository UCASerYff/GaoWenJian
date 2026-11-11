#!/usr/bin/python3
"""Install the signed app without copying user data or retaining old programs.

Only hashes are recorded. No application is launched, no rollback copy is made,
and an installation failure stops without restoring or modifying user data.
"""
import argparse
import contextlib
import datetime
import decimal
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
sys.dont_write_bytecode = True

BUNDLE = "com.gaoseries.GaoWenJian"
APP_NAME = "搞文件.app"
DEFAULT_TARGET = Path("/Applications") / APP_NAME
PROJECT = Path(__file__).resolve().parent.parent
DEFAULT_DATA = Path.home() / "Library/Application Support/GaoSeries/GaoWenJian"
DEFAULT_PREFS = Path.home() / "Library/Preferences" / (BUNDLE + ".plist")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def fail(message):
    raise RuntimeError(message)


def run(argv):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        fail("命令失败：" + argv[0] + "\n" + (result.stderr or result.stdout).strip()[:1800])
    return result.stdout


def atomic_json(path, content):
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    try:
        fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(content, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
    finally:
        if temporary.exists():
            temporary.unlink()


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                return digest.hexdigest()
            digest.update(block)


def inventory(path, permit_symlinks=False):
    """Read every file; unreadable or unsupported objects stop the install."""
    if not os.path.lexists(str(path)):
        return {"state": "missing", "entries": {}}
    entries = {}

    def visit(item, relative):
        details = item.lstat()
        mode = stat.S_IMODE(details.st_mode)
        if stat.S_ISLNK(details.st_mode):
            if not permit_symlinks:
                fail("资料含符号链接，须先逐项核验附件真实路径：" + str(item))
            entries[relative] = {"type": "symlink", "target": os.readlink(str(item)), "mode": mode}
        elif stat.S_ISDIR(details.st_mode):
            entries[relative] = {"type": "directory", "mode": mode}
            with os.scandir(str(item)) as children:
                names = sorted(entry.name for entry in children)
            for name in names:
                visit(item / name, (relative + "/" + name) if relative != "." else name)
        elif stat.S_ISREG(details.st_mode):
            entries[relative] = {"type": "file", "size": details.st_size, "sha256": digest_file(item), "mode": mode}
        else:
            fail("发现不能核验的特殊文件，安装已停止：" + str(item))

    visit(path, ".")
    return {"state": "present", "entries": entries}


def app_info(path):
    if path.is_symlink() or path.suffix != ".app" or not path.is_dir():
        fail("应用必须是实际的 .app 目录：" + str(path))
    with (path / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE:
        fail("Bundle ID 不匹配，禁止修改此应用：" + str(path))
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable:
        fail("应用缺少有效的可执行文件配置。")
    if not (path / "Contents/MacOS" / executable).is_file():
        fail("应用可执行文件不存在。")
    return info


def verify_signature(path, simulate):
    app_info(path)
    if not simulate:
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(path)])


def verify_candidate(path, simulate):
    verify_signature(path, simulate)
    if not simulate:
        run([sys.executable, str(Path(__file__).with_name("sign_bundle.py")), "verify", "--app", str(path)])


def registered_paths(dump):
    if "bundle id:" not in dump or "path:" not in dump:
        fail("系统应用登记无法完整读取，禁止按空白登记继续。")
    paths = set()
    for block in re.split(r"(?m)(?=^bundle id:)", dump):
        if not re.search(r"^identifier:\s+" + re.escape(BUNDLE) + r"\s*$", block, re.M):
            continue
        match = re.search(r"^path:\s+(.+?)\s+\(0x[0-9a-f]+\)\s*$", block, re.M)
        if match:
            paths.add(match.group(1))
    return paths


def register(path, simulate, remove=False):
    if not simulate:
        if remove and str(path) not in registered_paths(run([LSREGISTER, "-dump"])):
            return
        run([LSREGISTER, "-u" if remove else "-f", str(path)])


def ensure_not_running(target, simulate):
    if simulate or not target.exists():
        return
    executable = str(target / "Contents/MacOS" / app_info(target)["CFBundleExecutable"])
    for line in run(["/bin/ps", "-axo", "pid=,comm="]).splitlines():
        pieces = line.strip().split(None, 1)
        if len(pieces) == 2 and (pieces[1] == executable or pieces[1].startswith(str(target) + "/")):
            fail("搞文件仍在运行。请保存文件并退出，再安装；安装器不会强行结束编辑进程。")


def require_private_noindex(path):
    if path.is_symlink() or path.resolve() != path:
        fail("暂存路径不能经过符号链接。")
    containers = [p for p in path.parents if p.name.endswith(".noindex") and p.is_dir()]
    if not containers:
        fail("候选 App 必须在生成前位于真实 .noindex 容器中。")
    details = containers[0].stat()
    if details.st_uid != os.getuid() or stat.S_IMODE(details.st_mode) != 0o700:
        fail(".noindex 容器必须由当前用户拥有且权限为 0700。")


def check_simulation_paths(paths):
    roots = [Path("/private/tmp").resolve(), Path(tempfile.gettempdir()).resolve()]
    for path in paths:
        resolved = path.resolve()
        if not any(resolved == root or root in resolved.parents for root in roots):
            fail("--simulate 仅允许隔离系统临时目录：" + str(path))


def private_record_path(path):
    """Installation inventories contain private filenames; keep them temporary."""
    roots = [Path("/private/tmp").resolve(), Path(tempfile.gettempdir()).resolve()]
    if (path.is_symlink() or path.parent.resolve() != path.parent or PROJECT in path.parents
            or not any(root in path.parents for root in roots)):
        fail("私有安装摘要只能写入实际系统临时目录，禁止写入源码或 Release：" + str(path))


@contextlib.contextmanager
def installation_lock(target):
    # Per-app installation serialization is separate from the shared build lease.
    lock = target.parent / ".gaowenjian-install.lock"
    descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        details = os.fstat(descriptor)
        if details.st_uid != os.getuid() or not stat.S_ISREG(details.st_mode):
            fail("安装锁身份无效。")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def unchanged_data(manifest):
    for item in manifest["data_checks"].values():
        if inventory(Path(item["path"])) != item["inventory"]:
            fail("用户资料或设置摘要发生变化，停止；未回写、恢复或删除用户数据：" + item["path"])


def session_uniqueness(target):
    if os.stat("/dev/console").st_uid != os.getuid():
        fail("必须在实际用户会话核验安装入口。")
    registered = registered_paths(run([LSREGISTER, "-dump"]))
    spotlight = set(filter(None, run(["/usr/bin/mdfind", 'kMDItemCFBundleIdentifier == "' + BUNDLE + '"']).splitlines()))
    expected = {str(target)}
    result = {"checked_at": datetime.datetime.now().astimezone().isoformat(), "bundle_id": BUNDLE,
              "launch_services": sorted(registered), "spotlight": sorted(spotlight), "target_exists": target.is_dir()}
    if registered != expected or spotlight != expected or not target.is_dir():
        fail("唯一安装入口尚未核验通过；必须包含正式路径且不能有重复或空结果：" + json.dumps(result, ensure_ascii=False))
    return result


def load_manifest(path):
    private_record_path(path)
    if path.is_symlink():
        fail("安装摘要记录不能是符号链接。")
    with path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("bundle_id") != BUNDLE or manifest.get("format") != 2:
        fail("不是当前无备份安装记录；历史记录不可用于回滚或安装。")
    nonce = manifest.get("nonce")
    if not isinstance(nonce, str) or not re.fullmatch(r"[0-9a-f]{32}", nonce):
        fail("安装记录中的事务标识无效。")
    target = Path(manifest["target_app"])
    stage = Path(manifest["stage_dir"])
    if (target.name != APP_NAME or not target.is_absolute() or stage.parent != target.parent
            or stage.name != ".gaowenjian-install-" + nonce + ".noindex"
            or Path(manifest["manifest_path"]) != path.resolve() or stage.is_symlink() or target.is_symlink()):
        fail("安装摘要记录路径校验失败。")
    if manifest["simulate"]:
        check_simulation_paths([target, Path(manifest["data_root"]), Path(manifest["preferences"]), path])
    elif target != DEFAULT_TARGET:
        fail("正式安装只能使用唯一目标路径。")
    return manifest


def clear_stage(stage, candidate_inventory=None, partial=False):
    if not stage.exists():
        return
    require_private_noindex(stage / "candidate.app")
    for child in stage.iterdir():
        if child.name != "candidate.app" or child.is_symlink():
            fail("安装暂存存在未知对象，未自动删除：" + str(child))
        if not partial:
            app_info(child)
            if candidate_inventory is None or inventory(child, permit_symlinks=True) != candidate_inventory:
                fail("安装候选摘要不匹配，未删除未知对象。")
        shutil.rmtree(child)
    stage.rmdir()


def install(args):
    raw_source = Path(args.app).expanduser().absolute()
    if raw_source.is_symlink():
        fail("来源应用不能是符号链接。")
    source = raw_source.resolve()
    target = Path(args.target).expanduser().absolute()
    data_root = Path(args.data_root).expanduser().absolute()
    preferences = Path(args.preferences).expanduser().absolute()
    if target.name != APP_NAME or target == source or target.is_symlink() or target.parent.resolve() != target.parent:
        fail("安装目标必须是独立的实际 搞文件.app 路径。")
    if not args.simulate and target != DEFAULT_TARGET:
        fail("正式安装只能使用 /Applications/搞文件.app。")
    if data_root.is_symlink() or preferences.is_symlink():
        fail("资料根和设置路径不可使用符号链接。")
    data_root = data_root.resolve()
    preferences = preferences.resolve()
    for user_path in (data_root, preferences):
        if user_path == target or target in user_path.parents or user_path in target.parents:
            fail("应用与用户资料/设置路径不可互相包含。")
    if args.simulate:
        check_simulation_paths([source, target, data_root, preferences])
    require_private_noindex(source)
    info = app_info(source)
    version, build = str(info.get("CFBundleShortVersionString", "")), str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[0-9]+\.[0-9]{2}", version) or decimal.Decimal(version) < decimal.Decimal("1.00") or not build.isdigit():
        fail("版本配置无效。")
    verify_candidate(source, args.simulate)
    had_previous = target.exists()
    previous_inventory = None
    if had_previous:
        old = app_info(target)
        verify_signature(target, args.simulate)
        if decimal.Decimal(version) < decimal.Decimal(str(old.get("CFBundleShortVersionString", "0"))):
            fail("禁止用较旧版本覆盖当前程序。")
        previous_inventory = inventory(target, permit_symlinks=True)
    ensure_not_running(target, args.simulate)
    ensure_not_running(source, args.simulate)
    target.parent.mkdir(parents=True, exist_ok=True)
    with installation_lock(target):
        nonce = uuid.uuid4().hex
        path = Path(args.record).expanduser().absolute() if args.record else Path("/private/tmp") / ("gaowenjian-install-" + nonce + ".json")
        private_record_path(path)
        if os.path.lexists(path) or path.parent.resolve() != path.parent or not path.parent.is_dir():
            fail("安装摘要记录必须使用不存在的实际文件路径。")
        if args.simulate:
            check_simulation_paths([path])
        stage = target.parent / (".gaowenjian-install-" + nonce + ".noindex")
        stage.mkdir(mode=0o700)
        candidate = stage / "candidate.app"
        candidate_inventory = inventory(source, permit_symlinks=True)
        manifest = {"format": 2, "bundle_id": BUNDLE, "nonce": nonce, "state": "preparing",
                    "version": version, "build": build, "source_app": str(source), "target_app": str(target),
                    "stage_dir": str(stage), "manifest_path": str(path), "had_previous": had_previous,
                    "simulate": args.simulate, "data_root": str(data_root), "preferences": str(preferences),
                    "data_checks": {}, "candidate_inventory": candidate_inventory,
                    "created_at": datetime.datetime.now().astimezone().isoformat(), "no_backups": True}
        try:
            for key, original in (("data", data_root), ("preferences", preferences)):
                manifest["data_checks"][key] = {"path": str(original), "inventory": inventory(original)}
            atomic_json(path, manifest)
            if args.simulate:
                shutil.copytree(source, candidate, symlinks=True)
            else:
                run(["/usr/bin/ditto", str(source), str(candidate)])
            verify_candidate(candidate, args.simulate)
            if inventory(candidate, permit_symlinks=True) != candidate_inventory or inventory(source, permit_symlinks=True) != candidate_inventory:
                fail("安装候选逐文件校验失败。")
            unchanged_data(manifest)
            ensure_not_running(target, args.simulate)
            if had_previous:
                if inventory(target, permit_symlinks=True) != previous_inventory:
                    fail("安装前旧程序发生变化，停止替换。")
                register(target, args.simulate, remove=True)
                # The approved policy forbids retaining any old-program copy.
                shutil.rmtree(target)
            elif os.path.lexists(target):
                fail("正式目标已被其他操作占用，停止安装。")
            candidate.rename(target)
            verify_candidate(target, args.simulate)
            if inventory(target, permit_symlinks=True) != candidate_inventory:
                fail("正式安装程序逐文件校验失败。")
            unchanged_data(manifest)
            register(target, args.simulate)
            manifest["state"] = "installed_pending_verification"
            atomic_json(path, manifest)
            print("MANIFEST=" + str(path))
            print("已安装搞文件 V" + version + "；现用资料及设置逐文件摘要一致，未保留旧程序或资料备份，未启动应用。")
            print("继续核验：Scripts/finalize-install.sh --manifest '" + str(path) + "' --verified")
        except Exception as error:
            manifest["state"] = "failed"
            manifest["failure"] = str(error)
            atomic_json(path, manifest)
            raise
        finally:
            # This exact private stage was created by this invocation. Even a
            # failed partial copy is an intermediate candidate, never user data.
            clear_stage(stage, candidate_inventory, partial=True)


def finalize(args):
    path = Path(args.manifest).expanduser().absolute()
    manifest = load_manifest(path)
    target = Path(manifest["target_app"])
    with installation_lock(target):
        if manifest["state"] not in ("installed_pending_verification", "verified"):
            fail("此安装事务未处于待核验状态，禁止清理或覆盖。")
        ensure_not_running(target, manifest["simulate"])
        verify_candidate(target, manifest["simulate"])
        if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
            fail("程序在安装后发生变化，停止核验。")
        unchanged_data(manifest)
        if not manifest["simulate"]:
            manifest["uniqueness"] = session_uniqueness(target)
        else:
            manifest["uniqueness"] = {"simulated": True, "not_a_real_uniqueness_verification": True}
        clear_stage(Path(manifest["stage_dir"]), manifest["candidate_inventory"])
        manifest["state"] = "verified"
        manifest["verified_at"] = datetime.datetime.now().astimezone().isoformat()
        manifest["verification_note"] = args.verification_note
        manifest["unchanged_data_verified"] = True
        atomic_json(path, manifest)
        print("安装文件及现用数据摘要核验完成；" + ("隔离模拟未执行系统登记核验。" if manifest["simulate"] else "实际用户会话唯一入口核验通过。") + "未启动应用或执行冒烟测试。")


def main():
    parser = argparse.ArgumentParser(description="搞文件无备份安装及只读核验；失败停止，无回滚副本")
    commands = parser.add_subparsers(dest="command", required=True)
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--app", required=True)
    install_parser.add_argument("--target", default=str(DEFAULT_TARGET))
    install_parser.add_argument("--data-root", default=str(DEFAULT_DATA))
    install_parser.add_argument("--preferences", default=str(DEFAULT_PREFS))
    install_parser.add_argument("--record", help="仅系统临时目录中的私有摘要路径；默认 /private/tmp，不含文件内容")
    install_parser.add_argument("--simulate", action="store_true", help="仅隔离临时目录，不调用签名/系统登记或启动应用")
    final_parser = commands.add_parser("finalize")
    final_parser.add_argument("--manifest", required=True)
    final_parser.add_argument("--verified", required=True, action="store_true")
    final_parser.add_argument("--verification-note", default="", help="如实记录验证方式；不自动运行 GUI")
    args = parser.parse_args()
    try:
        install(args) if args.command == "install" else finalize(args)
    except Exception as error:
        print("安装操作已停止：" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
