"""Local, read-only Darwin metadata primitives for receiver program retention.

The state format matches the existing native original-program evidence:
``tree``, ``metadata`` and ``provenance`` with a root key of ``""``.  This
module has no application-specific archive, process, SQL, signing or registry
operations.  Importing it performs no filesystem or native metadata reads.

Only ordinary files and directories are supported. Links, placeholders,
hardlinked files, foreign owners and unstable objects stop verification.
"""
import base64
import contextlib
import ctypes
import functools
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


# Public Darwin SDK constants, kept local rather than importing another App.
O_SEARCH = 0x40000000 | os.O_DIRECTORY
DATALESS = getattr(stat, "SF_DATALESS", 0x40000000)
PROVENANCE = "com.apple.provenance"
PROVENANCE_B64 = base64.b64encode(PROVENANCE.encode()).decode("ascii")
APP_XATTR_OPTIONS = 0x20  # XATTR_SHOWCOMPRESSION
APP_ACL_TYPE = 0x100     # ACL_TYPE_EXTENDED
APP_META_LIMIT = 16 * 1024 * 1024


def need(value, message):
    if not value:
        raise RuntimeError(message)


def signature(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
            info.st_flags)


def checked_stat(name, fd):
    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
    need(not info.st_flags & DATALESS,
         "Cloud placeholder rejected without materializing it")
    return info


@contextlib.contextmanager
def directory_fd(path, read=False):
    path = Path(path)
    need(path.is_absolute() and ".." not in path.parts,
         "An exact absolute directory path is required")
    fd = os.open("/", O_SEARCH | os.O_NOFOLLOW)
    try:
        for index, part in enumerate(path.parts[1:]):
            before = checked_stat(part, fd)
            need(stat.S_ISDIR(before.st_mode),
                 "Directory ancestor is a link or special object")
            flags = os.O_RDONLY | os.O_DIRECTORY if read and index == len(path.parts) - 2 else O_SEARCH
            child = os.open(part, flags | os.O_NOFOLLOW, dir_fd=fd)
            after = os.fstat(child)
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino) or after.st_flags & DATALESS:
                os.close(child)
                raise RuntimeError("Directory ancestor changed while opening")
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def safe_lstat(path):
    path = Path(path)
    with directory_fd(path.parent) as parent:
        return checked_stat(path.name, parent)


def optional_stat(path):
    try:
        return safe_lstat(path)
    except FileNotFoundError:
        return None


def read_regular(path, limit=None):
    path = Path(path)
    with directory_fd(path.parent) as parent:
        before = checked_stat(path.name, parent)
        need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
             "Expected an independent ordinary file")
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=parent)
        try:
            need(signature(before) == signature(os.fstat(fd)),
                 "File changed while opening")
            data = bytearray()
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                data.extend(chunk)
                need(limit is None or len(data) <= limit,
                     "File exceeds the allowed read budget")
            need(signature(before) == signature(os.fstat(fd)) and len(data) == before.st_size,
                 "File changed while reading")
            return bytes(data)
        finally:
            os.close(fd)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(",", ":")).encode()).hexdigest()


def no_materialization(function):
    @functools.wraps(function)
    def wrapped(*args, **kwargs):
        system = ctypes.CDLL(None, use_errno=True)
        previous = system.getiopolicy_np(3, 1)
        need(previous >= 0 and system.setiopolicy_np(3, 1, 1) == 0,
             "Cannot prevent placeholder materialization")
        try:
            return function(*args, **kwargs)
        finally:
            need(system.setiopolicy_np(3, 1, previous) == 0,
                 "Cannot restore the prior file-access policy")
    return wrapped


def native_private(path):
    """Return the identity of an existing owned, no-follow 0700 container."""
    info = safe_lstat(path)
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
         and stat.S_IMODE(info.st_mode) == 0o700,
         "Expected an existing owned 0700 directory")
    return {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid,
            "gid": info.st_gid, "mode": stat.S_IMODE(info.st_mode)}


nativePrivate = native_private


def extended_attributes(fd, provenance=None):
    """Read complete ordinary FD xattr digests and original provenance bytes."""
    system = ctypes.CDLL(None, use_errno=True)
    system.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    system.flistxattr.restype = ctypes.c_ssize_t
    system.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                               ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    system.fgetxattr.restype = ctypes.c_ssize_t

    def sized(call):
        length = call(None, 0)
        if length < 0:
            raise OSError(ctypes.get_errno(), "Cannot read extended attributes")
        need(length <= APP_META_LIMIT, "Extended attribute exceeds the read budget")
        buffer = ctypes.create_string_buffer(length or 1)
        actual = call(buffer, length)
        need(actual == length, "Extended attribute changed while reading")
        return buffer.raw[:length]

    names = sized(lambda buffer, count: system.flistxattr(fd, buffer, count, 0))
    result = {}
    for name in names.split(b"\0"):
        if not name:
            continue
        value = sized(lambda buffer, count: system.fgetxattr(fd, name, buffer, count, 0, 0))
        result[os.fsdecode(name)] = hashlib.sha256(value).hexdigest()
        if name == PROVENANCE.encode() and provenance is not None:
            provenance.update(base64=base64.b64encode(value).decode("ascii"),
                              byteCount=len(value),
                              sha256=hashlib.sha256(value).hexdigest())
    return result


def tree_manifest(path, allow_links=False, provenance=None, identities=None):
    """Bounded no-follow inventory; it never copies or repairs an object."""
    need(not allow_links, "Links are not supported by this original-program verifier")
    path = Path(path)
    root_info = safe_lstat(path)
    need(not stat.S_ISLNK(root_info.st_mode), "The inventory root cannot be a link")
    result = {}
    count = 0

    def walk(parent, name, relative):
        nonlocal count
        count += 1
        need(count <= 1_000_000 and len(Path(relative).parts) <= 64,
             "Tree exceeds the safe inventory budget")
        before = checked_stat(name, parent)
        need(before.st_dev == root_info.st_dev and before.st_uid in (0, os.getuid()),
             "Tree crosses a volume or contains a foreign owner")
        if identities is not None:
            identities[relative] = list(signature(before))
        mode = stat.S_IMODE(before.st_mode)
        need(not stat.S_ISLNK(before.st_mode), "Links are unsupported; no target was followed")
        if stat.S_ISDIR(before.st_mode):
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                         dir_fd=parent)
            try:
                need(signature(before) == signature(os.fstat(fd)),
                     "Directory changed while opening")
                raw = {} if provenance is not None else None
                attributes = extended_attributes(fd, raw)
                if provenance is not None:
                    provenance[relative] = raw or None
                result[relative] = {"type": "directory", "mode": mode,
                                    "xattrs": attributes}
                for child in sorted(os.listdir(fd)):
                    walk(fd, child, str(Path(relative) / child) if relative else child)
                need(signature(before) == signature(os.fstat(fd)),
                     "Directory changed during inventory")
            finally:
                os.close(fd)
            return
        need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
             "Hardlinked files or special objects are unsupported")
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=parent)
        try:
            need(signature(before) == signature(os.fstat(fd)), "File changed while opening")
            checksum = hashlib.sha256()
            size = 0
            while True:
                block = os.read(fd, 1024 * 1024)
                if not block:
                    break
                checksum.update(block)
                size += len(block)
            raw = {} if provenance is not None else None
            attributes = extended_attributes(fd, raw)
            if provenance is not None:
                provenance[relative] = raw or None
            need(signature(before) == signature(os.fstat(fd)) and size == before.st_size,
                 "File changed during inventory")
            result[relative] = {"type": "file", "mode": mode,
                                "sha256": checksum.hexdigest(), "xattrs": attributes}
        finally:
            os.close(fd)

    with directory_fd(path.parent) as parent:
        walk(parent, path.name, "")
    return result


def _app_libc():
    need(sys.platform == "darwin", "Complete native metadata requires macOS; no byte-only fallback")
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    ptr, size, ssize = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ssize_t
    lib.flistxattr.argtypes = [ctypes.c_int, ptr, size, ctypes.c_int]
    lib.flistxattr.restype = ssize
    lib.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ptr, size, ctypes.c_uint32, ctypes.c_int]
    lib.fgetxattr.restype = ssize
    lib.filesec_init.argtypes = []
    lib.filesec_init.restype = ptr
    lib.filesec_free.argtypes = [ptr]
    lib.filesec_free.restype = None
    lib.fstatx_np.argtypes = [ctypes.c_int, ptr, ptr]
    lib.fstatx_np.restype = ctypes.c_int
    lib.filesec_query_property.argtypes = [ptr, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
    lib.filesec_query_property.restype = ctypes.c_int
    lib.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    lib.acl_get_fd_np.restype = ptr
    lib.acl_size.argtypes = [ptr]
    lib.acl_size.restype = ssize
    lib.acl_copy_ext.argtypes = [ptr, ptr, ssize]
    lib.acl_copy_ext.restype = ssize
    lib.acl_to_text.argtypes = [ptr, ctypes.POINTER(ssize)]
    lib.acl_to_text.restype = ptr
    lib.acl_free.argtypes = [ptr]
    lib.acl_free.restype = ctypes.c_int
    return lib


def _app_b64(value):
    return base64.b64encode(value).decode("ascii")


def _app_xattrs(lib, fd):
    def names():
        count = lib.flistxattr(fd, None, 0, APP_XATTR_OPTIONS)
        need(0 <= count <= APP_META_LIMIT, "Cannot completely read xattr names")
        buffer = ctypes.create_string_buffer(max(count, 1))
        actual = lib.flistxattr(fd, buffer, count, APP_XATTR_OPTIONS)
        need(actual == count, "Xattr names changed while reading")
        raw = buffer.raw[:count]
        need(not raw or raw.endswith(b"\0"), "Malformed xattr name list")
        result = raw[:-1].split(b"\0") if raw else []
        need(all(result) and len(result) == len(set(result)) if result else True,
             "Duplicate or invalid xattr name")
        return sorted(result)
    before = names()
    result = {}
    total = 0
    for name in before:
        count = lib.fgetxattr(fd, name, None, 0, 0, APP_XATTR_OPTIONS)
        need(0 <= count <= APP_META_LIMIT, "Cannot completely read xattr value")
        total += count
        need(total <= 4 * APP_META_LIMIT, "Complete xattr values exceed the read budget")
        buffer = ctypes.create_string_buffer(max(count, 1))
        actual = lib.fgetxattr(fd, name, buffer, count, 0, APP_XATTR_OPTIONS)
        need(actual == count, "Xattr value changed while reading")
        result[_app_b64(name)] = _app_b64(buffer.raw[:count])
    need(names() == before, "Xattr name list changed while reading values")
    return result


def _app_acl(lib, fd):
    security = lib.filesec_init()
    need(bool(security), "Cannot initialize complete ACL reading")
    try:
        native_stat = (ctypes.c_uint64 * 128)()
        need(lib.fstatx_np(fd, native_stat, security) == 0,
             "Cannot read complete file security information")
        present = ctypes.c_int(-1)
        need(lib.filesec_query_property(security, 5, ctypes.byref(present)) == 0
             and present.value >= 0, "Cannot positively prove ACL presence")
        if present.value == 0:
            return {"present": False, "external_b64": None, "text_b64": None,
                    "absenceProof": "fstatx_np/filesec_query_property(FILESEC_ACL)"}
    finally:
        lib.filesec_free(security)
    acl = lib.acl_get_fd_np(fd, APP_ACL_TYPE)
    need(bool(acl), "Cannot read complete ACL; no absence inference")
    text = None
    try:
        count = lib.acl_size(acl)
        need(0 <= count <= APP_META_LIMIT, "Invalid ACL size")
        buffer = ctypes.create_string_buffer(max(count, 1))
        actual = lib.acl_copy_ext(buffer, acl, count)
        need(0 <= actual <= count, "Cannot read ACL external representation")
        length = ctypes.c_ssize_t()
        text = lib.acl_to_text(acl, ctypes.byref(length))
        need(bool(text) and 0 <= length.value <= APP_META_LIMIT, "Cannot read ACL text")
        return {"present": True, "external_b64": _app_b64(buffer.raw[:actual]),
                "text_b64": _app_b64(ctypes.string_at(text, length.value))}
    finally:
        if text:
            lib.acl_free(text)
        lib.acl_free(acl)


class AttrList(ctypes.Structure):
    _fields_ = [("count", ctypes.c_uint16), ("reserved", ctypes.c_uint16)] + [
        (name, ctypes.c_uint32) for name in ["common", "volume", "directory", "file", "fork"]]


class Birth(ctypes.Structure):
    _pack_ = 4
    _fields_ = [("length", ctypes.c_uint32), ("seconds", ctypes.c_int64),
                ("nanoseconds", ctypes.c_int64)]


def birth_time(fd):
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    lib.fgetattrlist.argtypes = [ctypes.c_int, ctypes.POINTER(AttrList), ctypes.c_void_p,
                               ctypes.c_size_t, ctypes.c_uint32]
    lib.fgetattrlist.restype = ctypes.c_int
    request = AttrList(5, 0, 0x200, 0, 0, 0, 0)
    value = Birth()
    need(lib.fgetattrlist(fd, ctypes.byref(request), ctypes.byref(value), ctypes.sizeof(value), 0) == 0
         and value.length == ctypes.sizeof(value) and 0 <= value.nanoseconds < 1000000000,
         "Cannot read exact native creation time")
    return [value.seconds, value.nanoseconds]


def full_state(path):
    """Return the exact established tree/metadata/provenance evidence schema."""
    path = Path(path)
    raw, identities = {}, {}
    tree = tree_manifest(path, allow_links=False, provenance=raw, identities=identities)
    lib = _app_libc()
    metadata = {}
    for relative in tree:
        item = path / relative
        with directory_fd(item.parent, read=True) as parent:
            before = checked_stat(item.name, parent)
            fd = os.open(item.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=parent)
            try:
                need(signature(os.fstat(fd)) == signature(before),
                     "Object changed before native metadata read")
                value = {"stat": list(signature(before)), "birthTime": birth_time(fd),
                         "acl": _app_acl(lib, fd), "xattrs": _app_xattrs(lib, fd)}
                need(signature(os.fstat(fd)) == signature(before),
                     "Object changed during native metadata read")
                need(value["acl"] == _app_acl(lib, fd) and value["xattrs"] == _app_xattrs(lib, fd)
                     and value["birthTime"] == birth_time(fd), "Native metadata changed")
                metadata[relative] = value
            finally:
                os.close(fd)
    final_identities = {}
    final_tree = tree_manifest(path, allow_links=False, identities=final_identities)
    need(tree == final_tree and identities == final_identities
         and all(metadata[key]["stat"] == identities[key] for key in tree),
         "Tree changed between byte and native metadata inventories")
    return {"tree": tree, "metadata": metadata, "provenance": raw}


def root_provenance_move_only(before, after):
    """Only an observed existing root-directory provenance value may differ."""
    if before == after:
        return True
    if before.keys() != after.keys() or "" not in before:
        return False
    if any(before[key] != after[key] for key in before if key):
        return False
    first, second = dict(before[""]), dict(after[""])
    if first.get("type") != "directory" or second.get("type") != "directory":
        return False
    attributes, other = first.get("xattrs", {}), second.get("xattrs", {})
    if PROVENANCE not in attributes or PROVENANCE not in other:
        return False
    first["xattrs"] = {key: value for key, value in attributes.items() if key != PROVENANCE}
    second["xattrs"] = {key: value for key, value in other.items() if key != PROVENANCE}
    return first == second


def validate_provenance_state(state):
    """Bind original raw provenance evidence to both recorded inventories."""
    tree, raw = state["tree"], state["provenance"]
    need(isinstance(raw, dict) and raw.keys() == tree.keys(),
         "Original provenance evidence entry set differs")
    for key, entry in tree.items():
        expected = entry["xattrs"].get(PROVENANCE)
        evidence = raw[key]
        native_raw = state["metadata"][key]["xattrs"].get(PROVENANCE_B64)
        if evidence is None:
            need(expected is None and native_raw is None,
                 "Missing original raw provenance evidence: " + key)
            continue
        need(isinstance(evidence, dict) and set(evidence) == {"base64", "byteCount", "sha256"}
             and isinstance(evidence["base64"], str) and type(evidence["byteCount"]) is int
             and 0 <= evidence["byteCount"] <= APP_META_LIMIT,
             "Invalid original raw provenance evidence: " + key)
        value = base64.b64decode(evidence["base64"], validate=True)
        need(len(value) == evidence["byteCount"]
             and hashlib.sha256(value).hexdigest() == evidence["sha256"] == expected
             and native_raw == evidence["base64"],
             "Original provenance bytes/digests disagree: " + key)


def moved_equal(before, after):
    """Verify the same original inode, allowing only native root rename effects."""
    validate_provenance_state(before)
    validate_provenance_state(after)
    need(root_provenance_move_only(before["tree"], after["tree"]),
         "Moved original differs beyond native root provenance")
    need(before["metadata"].keys() == after["metadata"].keys(),
         "Moved metadata entry set changed")
    for key, original in before["metadata"].items():
        current = after["metadata"][key]
        a, b = list(original["stat"]), list(current["stat"])
        if key == "":
            a[8] = b[8]  # Native root rename ctime, never written back.
        need(a == b and original["birthTime"] == current["birthTime"]
             and original["acl"] == current["acl"],
             "Same-inode original security or identity metadata changed: " + key)
        x, y = dict(original["xattrs"]), dict(current["xattrs"])
        if key == "":
            x.pop(PROVENANCE_B64, None)
            y.pop(PROVENANCE_B64, None)
        need(x == y, "Moved original xattrs changed: " + key)
