#!/usr/bin/python3
"""Verified local install transactions. Never migrates, deletes, or restores user data."""
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
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

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
                break
            digest.update(block)
    return digest.hexdigest()


def inventory(path, permit_symlinks=False):
    """lstat/open failures are fatal; a missing source is explicitly recorded."""
    if not os.path.lexists(str(path)):
        return {"state": "missing", "entries": {}}
    entries = {}

    def visit(item, relative):
        details = item.lstat()
        mode = stat.S_IMODE(details.st_mode)
        if stat.S_ISLNK(details.st_mode):
            if not permit_symlinks:
                fail("资料含符号链接，无法保证全部附件备份，请先核验：" + str(item))
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
            fail("不支持备份特殊文件，安装已停止：" + str(item))

    visit(path, ".")
    return {"state": "present", "entries": entries}


def app_info(path):
    if path.is_symlink() or not path.is_dir():
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
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)])


def register(path, simulate, remove=False):
    if not simulate:
        run([LSREGISTER, "-u" if remove else "-f", str(path)])


def ensure_not_running(target, simulate):
    if simulate or not target.exists():
        return
    info = app_info(target)
    executable = str(target / "Contents/MacOS" / info["CFBundleExecutable"])
    for line in run(["/bin/ps", "-axo", "pid=,comm="]).splitlines():
        pieces = line.strip().split(None, 1)
        if len(pieces) == 2 and pieces[1] == executable:
            fail("搞文件仍在运行。请保存文件并退出，再安装；安装脚本不会强行终止编辑进程。")


def copy_verified(source, destination, simulate, permit_symlinks=False):
    before = inventory(source, permit_symlinks=permit_symlinks)
    if before["state"] == "missing":
        return before
    if destination.exists():
        fail("备份目标已存在，禁止覆盖：" + str(destination))
    if simulate:
        if source.is_dir():
            shutil.copytree(str(source), str(destination), symlinks=True)
        else:
            shutil.copy2(str(source), str(destination))
    else:
        run(["/usr/bin/ditto", str(source), str(destination)])
    if inventory(destination, permit_symlinks=permit_symlinks) != before:
        fail("复制后逐文件校验失败：" + str(source))
    if inventory(source, permit_symlinks=permit_symlinks) != before:
        fail("备份期间原资料发生变化，安装已停止：" + str(source))
    return before


def check_simulation_paths(paths):
    roots = [Path("/private/tmp").resolve(), Path(tempfile.gettempdir()).resolve()]
    for path in paths:
        resolved = path.resolve()
        if not any(resolved == root or root in resolved.parents for root in roots):
            fail("--simulate 仅允许隔离的系统临时目录，不可操作实际安装或真实资料：" + str(path))


@contextlib.contextmanager
def installation_lock(backup_root):
    backup_root.mkdir(parents=True, exist_ok=True)
    with (backup_root / ".installation.lock").open("a") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        yield


def load_manifest(path):
    with path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("bundle_id") != BUNDLE or manifest.get("format") != 1:
        fail("不是搞文件的安装记录。")
    target = Path(manifest["target_app"])
    stage = Path(manifest["stage_dir"])
    if target.name != APP_NAME or stage.parent != target.parent or stage.name != ".gaowenjian-install-" + manifest["nonce"]:
        fail("安装记录中的路径校验失败。")
    if Path(manifest["manifest_path"]) != path.resolve():
        fail("安装记录已移位，禁止清理未核验路径。")
    if stage.is_symlink() or target.is_symlink():
        fail("安装路径不应为符号链接。")
    if manifest["simulate"]:
        check_simulation_paths([target, Path(manifest["data_root"]), Path(manifest["preferences"]), path])
    return manifest


def verify_backup(manifest):
    for key in ("data", "preferences"):
        item = manifest["backups"][key]
        if item["inventory"]["state"] == "present":
            if inventory(Path(item["backup_path"])) != item["inventory"]:
                fail("安全备份校验失败，禁止删除旧程序：" + key)


def rollback(manifest, path):
    target = Path(manifest["target_app"])
    stage = Path(manifest["stage_dir"])
    previous = stage / "previous.app"
    simulate = manifest["simulate"]
    ensure_not_running(target, simulate)
    if target.exists():
        app_info(target)
        register(target, simulate, remove=True)
        failed = stage / "failed-candidate.app"
        if failed.exists():
            fail("已有待检查的失败程序，禁止覆盖：" + str(failed))
        target.rename(failed)
    if manifest["had_previous"]:
        if not previous.exists():
            fail("旧程序未找到，已保留现有资料与备份，请人工核验安装记录。")
        verify_signature(previous, simulate)
        previous.rename(target)
        register(target, simulate)
    if (stage / "failed-candidate.app").exists():
        app_info(stage / "failed-candidate.app")
        shutil.rmtree(str(stage / "failed-candidate.app"))
    if stage.exists() and not any(stage.iterdir()):
        stage.rmdir()
    manifest["state"] = "rolled_back"
    manifest["rolled_back_at"] = datetime.datetime.now().astimezone().isoformat()
    atomic_json(path, manifest)
    print("已恢复旧程序。用户资料与安全备份均保留。" if manifest["had_previous"] else "已撤回首次安装。用户资料与安全备份均保留。")


def install(args):
    source = Path(args.app).expanduser().resolve()
    target = Path(args.target).expanduser().absolute()
    data_root = Path(args.data_root).expanduser().absolute()
    preferences = Path(args.preferences).expanduser().absolute()
    backup_root = Path(args.backup_root).expanduser().absolute()
    if target.name != APP_NAME or target == source:
        fail("安装目标必须是独立的 搞文件.app，且不能与来源相同。")
    if target.is_symlink() or data_root.is_symlink() or preferences.is_symlink():
        fail("应用、资料根和设置路径不可使用符号链接。")
    target = target.parent.resolve() / target.name
    data_root = data_root.resolve()
    preferences = preferences.resolve()
    backup_root = backup_root.resolve()
    if data_root == target or target in data_root.parents or data_root in target.parents:
        fail("应用与资料路径不可互相包含。")
    if data_root == backup_root or data_root in backup_root.parents or backup_root in data_root.parents:
        fail("安全备份目录必须与用户资料目录分开。")
    if args.simulate:
        check_simulation_paths([source, target, data_root, preferences, backup_root])
    info = app_info(source)
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if len(version.split(".")) != 2 or len(version.split(".")[1]) != 2 or decimal.Decimal(version) < decimal.Decimal("1.00") or not build.isdigit():
        fail("版本配置无效，应从 1.00 / build 1 开始。")
    verify_signature(source, args.simulate)
    had_previous = target.exists()
    if had_previous:
        old = app_info(target)
        verify_signature(target, args.simulate)
        if decimal.Decimal(version) < decimal.Decimal(str(old.get("CFBundleShortVersionString", "0"))):
            fail("禁止用较旧版本覆盖当前程序。")
    ensure_not_running(target, args.simulate)
    ensure_not_running(source, args.simulate)
    target.parent.mkdir(parents=True, exist_ok=True)
    with installation_lock(backup_root):
        nonce = uuid.uuid4().hex
        stamp = datetime.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
        transaction = backup_root / ("安装-" + stamp + "-" + nonce[:8])
        transaction.mkdir(mode=0o700)
        path = transaction / "manifest.json"
        stage = target.parent / (".gaowenjian-install-" + nonce)
        stage.mkdir(mode=0o700)
        candidate = stage / "candidate.app"
        previous = stage / "previous.app"
        manifest = {
            "format": 1, "bundle_id": BUNDLE, "nonce": nonce, "state": "preparing",
            "version": version, "build": build, "source_app": str(source), "target_app": str(target),
            "stage_dir": str(stage), "manifest_path": str(path.resolve()), "had_previous": had_previous,
            "simulate": args.simulate, "data_root": str(data_root), "preferences": str(preferences),
            "backup_root": str(backup_root), "backups": {}, "created_at": datetime.datetime.now().astimezone().isoformat(),
            "defer_cleanup": bool(args.defer_cleanup)
        }
        atomic_json(path, manifest)
        changed_target = False
        unregistered_previous = False
        try:
            for key, original in (("data", data_root), ("preferences", preferences)):
                destination = transaction / ("用户资料" if key == "data" else "preferences.plist")
                copied = copy_verified(original, destination, args.simulate)
                manifest["backups"][key] = {"original_path": str(original), "backup_path": str(destination), "inventory": copied}
                atomic_json(path, manifest)
            copy_verified(source, candidate, args.simulate, permit_symlinks=True)
            if not args.simulate:
                run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", str(candidate)])
            verify_signature(candidate, args.simulate)
            manifest["candidate_inventory"] = inventory(candidate, permit_symlinks=True)
            if had_previous:
                manifest["previous_inventory"] = inventory(target, permit_symlinks=True)
            manifest["state"] = "prepared"
            atomic_json(path, manifest)
            if had_previous:
                register(target, args.simulate, remove=True)
                unregistered_previous = True
                target.rename(previous)
                changed_target = True
            candidate.rename(target)
            changed_target = True
            verify_signature(target, args.simulate)
            if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
                fail("安装后的程序逐文件校验失败。")
            for item in manifest["backups"].values():
                if inventory(Path(item["original_path"])) != item["inventory"]:
                    fail("安装期间用户资料或设置发生变化，停止安装并恢复旧程序。")
            register(target, args.simulate)
            manifest["state"] = "installed_pending_verification"
            atomic_json(path, manifest)
            print("MANIFEST=" + str(path))
            print("已安装搞文件 V" + version + "，等待 GUI 验收。旧程序、资料和设置备份均保留。")
            print("验收后：Scripts/finalize-install.sh --manifest '" + str(path) + "' --verified")
            print("验收失败：Scripts/finalize-install.sh --manifest '" + str(path) + "' --rollback")
        except Exception as error:
            manifest["failure"] = str(error)
            atomic_json(path, manifest)
            if changed_target:
                try:
                    rollback(manifest, path)
                except Exception as rollback_error:
                    manifest["rollback_failure"] = str(rollback_error)
                    atomic_json(path, manifest)
                    fail(str(error) + "\n自动恢复未完成：" + str(rollback_error) + "\n请保留安装记录：" + str(path))
            else:
                if unregistered_previous and target.exists():
                    register(target, args.simulate)
                manifest["state"] = "preparation_failed"
                atomic_json(path, manifest)
            raise


def finalize(args):
    path = Path(args.manifest).expanduser().resolve()
    manifest = load_manifest(path)
    with installation_lock(Path(manifest["backup_root"])):
        if manifest["state"] in ("verified", "rolled_back"):
            print("安装事务已完成：" + manifest["state"])
            return
        if manifest["state"] != "installed_pending_verification":
            fail("此安装事务未处于待验收状态，禁止清理或覆盖。")
        if args.rollback:
            rollback(manifest, path)
            return
        verify_backup(manifest)
        target = Path(manifest["target_app"])
        stage = Path(manifest["stage_dir"])
        verify_signature(target, manifest["simulate"])
        if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
            fail("程序在安装后发生变化，不能删除旧程序，请核验或回滚。")
        if (stage / "previous.app").exists():
            app_info(stage / "previous.app")
            if inventory(stage / "previous.app", permit_symlinks=True) != manifest["previous_inventory"]:
                fail("旧程序备份发生变化，禁止清理。")
        if stage.exists():
            allowed = {"previous.app", "candidate.app"}
            if any(child.name not in allowed for child in stage.iterdir()):
                fail("暂存目录包含未知文件，禁止自动清理。")
            for child in stage.iterdir():
                app_info(child)
            shutil.rmtree(str(stage))
        manifest["state"] = "verified"
        manifest["verified_at"] = datetime.datetime.now().astimezone().isoformat()
        atomic_json(path, manifest)
        print("GUI 验收已确认，旧程序和本次安装暂存已删除。用户资料与安全备份保留。")


def main():
    parser = argparse.ArgumentParser(description="搞文件本地安装与安全回滚")
    commands = parser.add_subparsers(dest="command", required=True)
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--app", required=True)
    install_parser.add_argument("--target", default=str(DEFAULT_TARGET))
    install_parser.add_argument("--data-root", default=str(DEFAULT_DATA))
    install_parser.add_argument("--preferences", default=str(DEFAULT_PREFS))
    install_parser.add_argument("--backup-root", default=str(PROJECT / "安全备份"))
    install_parser.add_argument("--defer-cleanup", action="store_true", help="保留旧程序等待 GUI 验收；所有安装均要求显式 finalize")
    install_parser.add_argument("--simulate", action="store_true", help="仅临时目录模拟，不调用签名或系统登记")
    final_parser = commands.add_parser("finalize")
    final_parser.add_argument("--manifest", required=True)
    actions = final_parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--verified", action="store_true")
    actions.add_argument("--rollback", action="store_true")
    args = parser.parse_args()
    try:
        install(args) if args.command == "install" else finalize(args)
    except Exception as error:
        print("安装操作已停止：" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
