#!/usr/bin/python3
"""Verified local install transactions. Never migrates, deletes, or restores user data."""
import argparse
import contextlib
import ctypes
import datetime
import decimal
import fcntl
import hashlib
import importlib.util
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
_NATIVE = None


def native_state():
    global _NATIVE
    if _NATIVE is None:
        spec = importlib.util.spec_from_file_location("gaowenjian_receiver_native", Path(__file__).with_name("receiver_native_state.py"))
        _NATIVE = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_NATIVE)
    return _NATIVE


def exclusive_private(path, data):
    with Path(path).open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data); stream.flush(); os.fsync(stream.fileno())
    with native_state().directory_fd(Path(path).parent, read=True) as fd:
        os.fsync(fd)


def native_program_evidence(app):
    info = app_info(app)
    state = native_state().no_materialization(lambda: native_state().full_state(Path(app)))()
    root = state["metadata"][""]["stat"]
    return {"identity": {"path": str(app), "identity": ":".join(map(str, (root[0], root[1], root[3]))),
                         "bundleID": BUNDLE, "exe": info["CFBundleExecutable"],
                         "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion")},
            "fullNativeOriginalState": state}


def program_binding(manifest):
    keys = ("format", "bundle_id", "nonce", "version", "build", "target_app", "stage_dir", "manifest_path", "had_previous", "simulate", "data_root", "preferences", "backup_root", "backups", "candidate_inventory", "previous_inventory")
    return {key: manifest.get(key) for key in keys}


def program_signature_evidence(app, simulate):
    verify_signature(app, simulate)
    if simulate:
        return {"simulated": True, "notARealSignatureVerification": True}
    result = {}
    for label, args in (("details", ["-d", "--verbose=4"]), ("requirements", ["-d", "-r-"]), ("entitlements", ["-d", "--entitlements", "-", "--xml"])):
        p = subprocess.run(["/usr/bin/codesign", *args, str(app)], capture_output=True)
        if p.returncode:
            fail("无法记录旧接收方原签名，未保留为已核验备份。")
        result[label] = {"stdout": p.stdout.decode("utf-8", errors="strict"), "stderr": p.stderr.decode("utf-8", errors="strict")}
    return result


def retention_paths(path):
    root = path.parent / "ProgramRecovery.noindex"
    return root, root / "retention.json"


def verify_program_retention(manifest, path, require_pointer=True, require_formal_anchor=True, program_location=None):
    native = native_state()
    root, receipt_path = retention_paths(path)
    rs = native.safe_lstat(root)
    if not stat.S_ISDIR(rs.st_mode) or rs.st_uid != os.getuid() or stat.S_IMODE(rs.st_mode) != 0o700:
        fail("旧接收方程序恢复记录容器不安全。")
    receipt_bytes = native.read_regular(receipt_path, 64 * 1024 * 1024)
    receipt = json.loads(receipt_bytes)
    previous = Path(manifest["stage_dir"]) / "previous.app"
    if (receipt.get("schemaVersion") != 1 or receipt.get("kind") != "GaoWenJianRetainedReceiverProgram"
            or receipt.get("binding") != program_binding(manifest) or receipt.get("programPath") != str(previous)):
        fail("旧接收方程序恢复记录与本安装事务不匹配。")
    source_bytes = native.read_regular(root / "manifest.before.json", 64 * 1024 * 1024)
    if hashlib.sha256(source_bytes).hexdigest() != receipt.get("sourceManifestSHA256") or program_binding(json.loads(source_bytes)) != program_binding(manifest):
        fail("原安装记录快照摘要或身份不匹配。")
    before_bytes = native.read_regular(root / "native-before.json", 64 * 1024 * 1024)
    if hashlib.sha256(before_bytes).hexdigest() != receipt.get("nativeBeforeSHA256"):
        fail("原程序完整安全元数据依据变化。")
    before = json.loads(before_bytes)
    location = Path(program_location) if program_location is not None else previous
    if location not in (previous, Path(manifest["target_app"])):
        fail("恢复原件不在本事务的两个精确位置。")
    current = native_program_evidence(location)
    if location == previous:
        if current["fullNativeOriginalState"] != receipt.get("retainedNativeState"):
            fail("持久旧程序原件的完整原生元数据或内容变化。")
    else:
        native.moved_equal(receipt["retainedNativeState"], current["fullNativeOriginalState"])
    native.moved_equal(before["fullNativeOriginalState"], current["fullNativeOriginalState"])
    if before.get("identity", {}).get("bundleID") != BUNDLE or before["identity"].get("path") != manifest["target_app"] or before["identity"].get("identity") != current["identity"]["identity"]:
        fail("保留的不是原同inode接收方程序。")
    for name, checksum in receipt.get("restoreTools", {}).items():
        if name not in ("install_safety.py", "receiver_native_state.py") or digest_file(root / "Tools" / name) != checksum:
            fail("独立恢复工具摘要不匹配。")
    if set(receipt.get("restoreTools", {})) != {"install_safety.py", "receiver_native_state.py"}:
        fail("独立程序恢复工具不完整。")
    if require_pointer:
        pointer = manifest.get("retained_previous_program", {})
        if (pointer.get("receipt_path") != str(receipt_path) or pointer.get("receipt_sha256") != hashlib.sha256(receipt_bytes).hexdigest()
                or pointer.get("program_path") != str(previous) or pointer.get("original_identity") != current["identity"]["identity"]):
            fail("安装记录中的旧程序恢复指针不匹配。")
    program_signature_evidence(location, manifest["simulate"])
    if not manifest["simulate"] and require_formal_anchor:
        paths = registered_paths(run([LSREGISTER, "-dump"]))
        if str(Path(manifest["target_app"])) not in paths or str(previous) in paths:
            fail("需要正式程序正向登记及旧原件精确缺席；未自动注销或按空视图放行。")
    return receipt


def retain_previous_program(manifest, path, before_path):
    native = native_state()
    previous = Path(manifest["stage_dir"]) / "previous.app"
    ensure_not_running(previous, manifest["simulate"])
    stage = Path(manifest["stage_dir"])
    ss = native.safe_lstat(stage)
    if not stage.name.endswith(".noindex") or ss.st_uid != os.getuid() or stat.S_IMODE(ss.st_mode) != 0o700:
        fail("原旧程序只允许持久保留在本次真实私有.noindex暂存。")
    root, receipt_path = retention_paths(path)
    if not manifest.get("retained_previous_program") and not receipt_path.exists():
        if before_path is None:
            fail("缺少安装前完整旧接收方程序元数据依据；原件保留，禁止清理。")
        before_bytes = native.read_regular(Path(before_path), 64 * 1024 * 1024)
        before = json.loads(before_bytes)
        current = native_program_evidence(previous)
        if before.get("identity", {}).get("bundleID") != BUNDLE or before["identity"].get("path") != manifest["target_app"] or before["identity"].get("identity") != current["identity"]["identity"]:
            fail("安装前依据与同inode旧接收方程序不匹配。")
        native.moved_equal(before["fullNativeOriginalState"], current["fullNativeOriginalState"])
        signature = program_signature_evidence(previous, manifest["simulate"])
        source_manifest = native.read_regular(path, 64 * 1024 * 1024)
        root.mkdir(mode=0o700, exist_ok=False)
        exclusive_private(root / "manifest.before.json", source_manifest)
        exclusive_private(root / "native-before.json", before_bytes)
        tools = root / "Tools"; tools.mkdir(mode=0o700)
        hashes = {}
        for name in ("install_safety.py", "receiver_native_state.py"):
            data = Path(__file__).with_name(name).read_bytes()
            exclusive_private(tools / name, data); hashes[name] = hashlib.sha256(data).hexdigest()
        receipt = {"schemaVersion": 1, "kind": "GaoWenJianRetainedReceiverProgram", "binding": program_binding(manifest),
                   "programPath": str(previous), "originalIdentity": current["identity"]["identity"],
                   "sourceManifestSHA256": hashlib.sha256(source_manifest).hexdigest(), "nativeBeforeSHA256": hashlib.sha256(before_bytes).hexdigest(),
                   "retainedNativeState": current["fullNativeOriginalState"], "originalSignature": signature, "restoreTools": hashes,
                   "noArchiveOrCopyReplacesOriginal": True, "receiverBackupMustRemain": True}
        exclusive_private(receipt_path, json.dumps(receipt, ensure_ascii=False, sort_keys=True, indent=2).encode() + b"\n")
    receipt = verify_program_retention(manifest, path, require_pointer=False)
    manifest["retained_previous_program"] = {"receipt_path": str(receipt_path), "receipt_sha256": digest_file(receipt_path),
        "program_path": str(previous), "original_identity": receipt["originalIdentity"],
        "restore_command": ["/usr/bin/python3", str(root / "Tools/install_safety.py"), "finalize", "--manifest", str(path), "--rollback"]}
    atomic_json(path, manifest)
    verify_program_retention(manifest, path)


def rename_program_exclusive(source, target, expected_state):
    native = native_state()
    expected = expected_state["metadata"][""]["stat"]
    with native.directory_fd(source.parent, read=True) as left, native.directory_fd(target.parent, read=True) as right:
        current = native.checked_stat(source.name, left)
        if (current.st_dev, current.st_ino, current.st_uid) != (expected[0], expected[1], expected[3]) or os.fstat(left).st_dev != os.fstat(right).st_dev:
            fail("原程序移动身份或同卷条件变化，保留原件。")
        lib = native._app_libc()
        if lib.renameatx_np(left, os.fsencode(source.name), right, os.fsencode(target.name), 0x4) != 0:
            raise OSError(ctypes.get_errno(), "排他原程序移动失败；未覆盖任何目标")
        os.fsync(left);os.fsync(right)


def rollback_retained_program(manifest, path):
    """Durable exact-program recovery; no data restoration or automatic launch."""
    native = native_state()
    target = Path(manifest["target_app"]);stage = Path(manifest["stage_dir"])
    previous = stage / "previous.app";failed = stage / "failed-candidate.app"
    ensure_not_running(previous, manifest["simulate"])
    ensure_not_running(failed, manifest["simulate"])
    root, _ = retention_paths(path);intent_path = root / "restore-intent.json"
    if not intent_path.exists():
        receipt = verify_program_retention(manifest, path, require_formal_anchor=False)
        if os.path.lexists(failed):
            fail("已有未知失败程序，未创建恢复意图或覆盖。")
        candidate = None
        if target.exists():
            if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
                fail("当前正式程序已不是此事务安装版本，禁止历史回滚覆盖。")
            candidate = native_program_evidence(target)
        intent = {"schemaVersion": 1, "kind": "GaoWenJianExactReceiverProgramRestore", "nonce": manifest["nonce"],
                  "retentionReceiptSHA256": manifest["retained_previous_program"]["receipt_sha256"],
                  "previous": str(previous), "target": str(target), "failed": str(failed),
                  "originalIdentity": receipt["originalIdentity"], "candidateBefore": candidate}
        exclusive_private(intent_path, json.dumps(intent, ensure_ascii=False, sort_keys=True).encode() + b"\n")
    intent = json.loads(native.read_regular(intent_path, 64 * 1024 * 1024))
    if (intent.get("schemaVersion") != 1 or intent.get("kind") != "GaoWenJianExactReceiverProgramRestore"
            or intent.get("nonce") != manifest["nonce"] or intent.get("retentionReceiptSHA256") != manifest["retained_previous_program"]["receipt_sha256"]
            or [intent.get(key) for key in ("previous", "target", "failed")] != list(map(str, (previous, target, failed)))):
        fail("原程序恢复意图不属于本事务，保留现场。")
    if previous.exists():
        receipt = verify_program_retention(manifest, path, require_formal_anchor=False)
        if intent.get("originalIdentity") != receipt["originalIdentity"]:
            fail("恢复意图的原件身份变化。")
        if target.exists():
            if failed.exists() or intent.get("candidateBefore") is None or native_program_evidence(target)["fullNativeOriginalState"] != intent["candidateBefore"]["fullNativeOriginalState"]:
                fail("恢复前正式候选或失败位置变化，禁止覆盖。")
            register(target, manifest["simulate"], remove=True)
            rename_program_exclusive(target, failed, intent["candidateBefore"]["fullNativeOriginalState"])
        if intent.get("candidateBefore") is not None:
            if not failed.exists():
                fail("原当前候选不在正式或失败位置，保留现场。")
            native.moved_equal(intent["candidateBefore"]["fullNativeOriginalState"], native_program_evidence(failed)["fullNativeOriginalState"])
        elif os.path.lexists(failed):
            fail("恢复期间出现未知失败程序，未覆盖。")
        verify_signature(previous, manifest["simulate"])
        register(previous, manifest["simulate"], remove=True)
        rename_program_exclusive(previous, target, receipt["retainedNativeState"])
    receipt = verify_program_retention(manifest, path, require_formal_anchor=False, program_location=target)
    if receipt["originalIdentity"] != intent.get("originalIdentity"):
        fail("正式路径不是本次原程序，未接管。")
    if intent.get("candidateBefore") is not None:
        if not failed.exists():
            fail("被换下的本次候选缺失；原程序已回正式，保留恢复意图。")
        native.moved_equal(intent["candidateBefore"]["fullNativeOriginalState"], native_program_evidence(failed)["fullNativeOriginalState"])
    elif os.path.lexists(failed):
        fail("中断恢复后出现未知失败程序，未接管或注销。")
    register(target, manifest["simulate"])
    if failed.exists():
        register(failed, manifest["simulate"], remove=True)
    restored = native_program_evidence(target)
    native.moved_equal(receipt["retainedNativeState"], restored["fullNativeOriginalState"])
    restored_path = root / "restored.json"
    if not restored_path.exists():
        exclusive_private(restored_path, json.dumps({"schemaVersion": 1, "programPath": str(target),
            "originalIdentity": restored["identity"]["identity"], "retentionReceiptSHA256": manifest["retained_previous_program"]["receipt_sha256"],
            "nativeRestoredState": restored["fullNativeOriginalState"], "displacedCandidatePath": str(failed) if failed.exists() else None,
            "noUserDataRestored": True}, ensure_ascii=False, sort_keys=True).encode() + b"\n")
    observed = json.loads(native.read_regular(restored_path, 64 * 1024 * 1024))
    if observed.get("programPath") != str(target) or observed.get("originalIdentity") != receipt["originalIdentity"] or observed.get("retentionReceiptSHA256") != manifest["retained_previous_program"]["receipt_sha256"]:
        fail("已有恢复回执不配对，保留现场。")
    manifest["program_restoration"] = {"receipt_path": str(restored_path), "receipt_sha256": digest_file(restored_path), "program_path": str(target), "original_identity": receipt["originalIdentity"]}
    manifest["state"] = "rolled_back";manifest["rolled_back_at"] = datetime.datetime.now().astimezone().isoformat()
    atomic_json(path, manifest)
    print("已恢复原同inode旧接收方程序；本次候选、用户现用资料和完整安全备份保留，未回写资料。")


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


def registered_paths(dump):
    if "bundle id:" not in dump or "path:" not in dump:
        fail("系统应用登记无法完整读取，禁止按空白登记继续清理。")
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
            # Hidden transaction copies need not have a LaunchServices record.
            # Verify absence instead of treating an unregister error as success.
            return
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
    nonce = manifest.get("nonce")
    if not isinstance(nonce, str) or not re.fullmatch(r"[0-9a-f]{32}", nonce):
        fail("安装记录中的事务标识无效。")
    target = Path(manifest["target_app"])
    stage = Path(manifest["stage_dir"])
    expected_stage = ".gaowenjian-install-" + nonce
    if target.name != APP_NAME or stage.parent != target.parent or stage.name not in (expected_stage, expected_stage + ".noindex"):
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
    # Old receipts remain readable in place, but rollback must never generate a
    # failed-candidate.app in an ordinary indexed historical staging directory.
    # Relocating such a historical transaction requires a separately verified
    # pointer/restore-receipt migration; do not silently rename its stage here.
    if not any(parent.name.endswith(".noindex") and parent.is_dir() for parent in [stage, *stage.parents]):
        fail("旧回滚暂存不在 .noindex 容器中；已保留原程序和收据。请先核验备份指针迁移，禁止原样执行后补清理。")
    ensure_not_running(target, simulate)
    if manifest.get("retained_previous_program"):
        rollback_retained_program(manifest, path)
        return
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
    if not args.simulate and decimal.Decimal(version) >= decimal.Decimal("1.10"):
        # New formal candidates require the approved certificate/Team/stable DR.
        # Generic verify_signature remains backward-compatible for old rollback.
        run([sys.executable, str(Path(__file__).with_name("sign_bundle.py")), "verify", "--app", str(source)])
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
        stage = target.parent / (".gaowenjian-install-" + nonce + ".noindex")
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
            # Preserve the already verified build signature and designated identity.
            # Installation copies bytes; it must not recursively re-sign nested tools
            # or create a second signature generation that invalidates user grants.
            verify_signature(candidate, args.simulate)
            manifest["candidate_inventory"] = inventory(candidate, permit_symlinks=True)
            if had_previous:
                manifest["previous_inventory"] = inventory(target, permit_symlinks=True)
                before_path = transaction / "program-before-native.json"
                evidence = native_program_evidence(target)
                exclusive_private(before_path, json.dumps(evidence, ensure_ascii=False, sort_keys=True, indent=2).encode() + b"\n")
                manifest["program_before_native"] = {"path": str(before_path), "sha256": digest_file(before_path)}
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
            print("已安装搞文件 V" + version + "，等待安装后验证。旧程序、资料和设置备份均保留。")
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
        if manifest["state"] == "verified" and args.rollback:
            if manifest.get("had_previous") and not manifest.get("retained_previous_program"):
                fail("历史verified事务缺完整旧程序恢复指针，保留现场，禁止猜测回滚。")
            verify_backup(manifest)
            rollback(manifest, path)
            return
        if manifest["state"] in ("verified", "rolled_back"):
            if manifest["state"] == "verified" and manifest.get("had_previous"):
                verify_program_retention(manifest, path)
            print("安装事务已完成：" + manifest["state"])
            return
        if manifest["state"] != "installed_pending_verification":
            fail("此安装事务未处于待验收状态，禁止清理或覆盖。")
        if args.rollback:
            rollback(manifest, path)
            return
        verify_backup(manifest)
        if args.require_unchanged_data:
            for item in manifest["backups"].values():
                if inventory(Path(item["original_path"])) != item["inventory"]:
                    fail("资料或设置在安装后发生变化，未确认保留结果，禁止清理旧程序。")
        target = Path(manifest["target_app"])
        stage = Path(manifest["stage_dir"])
        verify_signature(target, manifest["simulate"])
        if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
            fail("程序在安装后发生变化，不能删除旧程序，请核验或回滚。")
        if (stage / "previous.app").exists():
            app_info(stage / "previous.app")
            if inventory(stage / "previous.app", permit_symlinks=True) != manifest["previous_inventory"]:
                fail("旧程序备份发生变化，禁止清理。")
        if manifest["had_previous"]:
            before_path = getattr(args, "previous_native_before", None)
            if before_path is None and manifest.get("program_before_native"):
                item = manifest["program_before_native"]
                before_path = Path(item["path"])
                if digest_file(before_path) != item["sha256"]:
                    fail("安装前完整程序元数据依据摘要变化。")
            retain_previous_program(manifest, path, Path(before_path) if before_path is not None else None)
        if stage.exists():
            allowed = {"previous.app", "candidate.app"}
            if any(child.name not in allowed for child in stage.iterdir()):
                fail("暂存目录包含未知文件，禁止自动清理。")
            for child in list(stage.iterdir()):
                if child.name == "previous.app" and manifest.get("retained_previous_program"):
                    continue
                app_info(child)
                if inventory(child, permit_symlinks=True) != manifest["candidate_inventory"]:
                    fail("未知暂存程序不是本事务候选，不自动删除。")
                register(child, manifest["simulate"], remove=True)
                shutil.rmtree(str(child))
            if not any(stage.iterdir()):
                stage.rmdir()
        manifest["state"] = "verified"
        manifest["verified_at"] = datetime.datetime.now().astimezone().isoformat()
        manifest["verification_note"] = args.verification_note
        manifest["unchanged_data_verified"] = bool(args.require_unchanged_data)
        atomic_json(path, manifest)
        print("安装后验证已记录；完整旧接收方原程序在私有.noindex位置及恢复指针中保留。用户资料和安全备份保留。" if manifest.get("retained_previous_program") else "安装后验证已记录，空安装暂存已清理。用户资料和安全备份保留。")


def main():
    parser = argparse.ArgumentParser(description="搞文件本地安装与安全回滚")
    commands = parser.add_subparsers(dest="command", required=True)
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--app", required=True)
    install_parser.add_argument("--target", default=str(DEFAULT_TARGET))
    install_parser.add_argument("--data-root", default=str(DEFAULT_DATA))
    install_parser.add_argument("--preferences", default=str(DEFAULT_PREFS))
    install_parser.add_argument("--backup-root", default=str(PROJECT / "安全备份"))
    install_parser.add_argument("--defer-cleanup", action="store_true", help="保留旧程序等待验证；所有安装均要求显式 finalize")
    install_parser.add_argument("--simulate", action="store_true", help="仅临时目录模拟，不调用签名或系统登记")
    final_parser = commands.add_parser("finalize")
    final_parser.add_argument("--manifest", required=True)
    final_parser.add_argument("--verification-note", default="", help="如实记录本次采用的验证方式，不自动运行 GUI")
    final_parser.add_argument("--require-unchanged-data", action="store_true", help="清理旧程序前再次核对资料和设置逐文件未变")
    final_parser.add_argument("--previous-native-before", help="旧安装事务兼容：安装前完整旧接收方程序native证据；不修改原证据或原程序")
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
