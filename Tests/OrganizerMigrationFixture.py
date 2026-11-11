#!/usr/bin/env python3
"""Synthetic Organizer migration fixture generator. Tests only, private temporary data only.
Never opens the source SQLite database: raw database/WAL are copied while the
source app's existing lock is held, and SQLite online backup runs on that copy.
Only an absent .noindex output is created. No actual export runs on import.
"""
import argparse
import base64
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import urllib.parse
import uuid

REQUIRED = ['configuration.json', 'configuration.initialized', 'metadata.sqlite', 'index-initialized.json',
            'associations_history.json', 'associations_history.initialized', 'exchange-initialized.json',
            'Exchange/Journal/ledger.json', 'MovePlans/initialized.json', 'MovePlans/ledger.json', 'MovePlans.initialized']
LOCKS = {'.app.lock', 'MovePlans/.lock', 'Exchange/Journal/ledger.lock'}
SIDECARS = {'metadata.sqlite-wal', 'metadata.sqlite-shm', 'metadata.sqlite-journal'}
COPY_POLICY = 'exact-data-copy-with-evidenced-os-provenance-v1'
PROVENANCE = 'com.apple.provenance'


def need(value, text):
    if not value:
        raise RuntimeError(text)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def safe(path):
    p = Path(path)
    need(p.is_absolute() and '..' not in p.parts, 'Only exact absolute paths are allowed')
    for part in [*reversed(p.parents), p]:
        s = os.lstat(part)
        need(not stat.S_ISLNK(s.st_mode), 'Symlink path/ancestor rejected: ' + str(part))
    return p


def xattrs(path, provenance=None):
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    listing, getting = lib.listxattr, lib.getxattr
    listing.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    getting.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    listing.restype = getting.restype = ctypes.c_ssize_t
    def call(fn, *args):
        ctypes.set_errno(0)
        n = fn(*args)
        if n < 0:
            e = ctypes.get_errno()
            raise OSError(e, os.strerror(e), str(path))
        return n
    rawpath = os.fsencode(path)
    n = call(listing, rawpath, None, 0, 0x61)
    if not n:
        return {}
    b = ctypes.create_string_buffer(n)
    need(call(listing, rawpath, b, n, 0x61) == n, 'Attributes changed')
    need(b.raw.endswith(b'\0'), 'Malformed attributes')
    result = {}
    for name in sorted(b.raw[:-1].split(b'\0')):
        length = call(getting, rawpath, name, None, 0, 0, 0x61)
        v = ctypes.create_string_buffer(max(1, length))
        need(call(getting, rawpath, name, v, length, 0, 0x61) == length, 'Attribute changed')
        result[os.fsdecode(name)] = sha(v.raw[:length])
        if provenance is not None and name == PROVENANCE.encode():
            provenance.update(base64=base64.b64encode(v.raw[:length]).decode(), byteCount=length, sha256=result[PROVENANCE])
    return result


def read(path):
    p = safe(path)
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        a = os.fstat(fd)
        need(stat.S_ISREG(a.st_mode) and a.st_nlink == 1 and a.st_uid == os.getuid(), 'Unsafe source file: ' + str(p))
        need(not (getattr(a, 'st_flags', 0) & 0x40000000), 'Dataless file cannot be materialized')
        h = hashlib.sha256()
        with os.fdopen(os.dup(fd), 'rb') as f:
            for block in iter(lambda: f.read(1048576), b''):
                h.update(block)
        b = os.fstat(fd)
        fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_uid', 'st_gid', 'st_nlink')
        need(all(getattr(a, k) == getattr(b, k) for k in fields), 'Source changed while hashing')
        return h.hexdigest(), a
    finally:
        os.close(fd)


def inventory(root, identity=False, provenance=None):
    root = safe(root)
    out = []
    def visit(p, rel):
        before = os.lstat(p)
        need(before.st_uid == os.getuid(), 'Foreign-owned source object')
        raw = {} if provenance is not None else None
        e = {'path': rel, 'kind': 'directory' if stat.S_ISDIR(before.st_mode) else 'file',
             'mode': stat.S_IMODE(before.st_mode), 'xattrs': xattrs(p, raw)}
        if provenance is not None:
            provenance[rel] = raw or None
        if stat.S_ISDIR(before.st_mode):
            for child in sorted(p.iterdir()):
                visit(child, child.name if rel == '.' else rel + '/' + child.name)
        else:
            need(stat.S_ISREG(before.st_mode), 'Symlink/special object rejected: ' + str(p))
            digest, state = read(p)
            e.update(bytes=state.st_size, sha256=digest)
        after = os.lstat(p)
        stable = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_mtime_ns', 'st_ctime_ns', 'st_nlink')
        need(all(getattr(before, k) == getattr(after, k) for k in stable), 'Source tree changed')
        if identity:
            e.update(device=before.st_dev, inode=before.st_ino, mtimeNS=before.st_mtime_ns,
                     ctimeNS=before.st_ctime_ns, uid=before.st_uid, gid=before.st_gid, nlink=before.st_nlink,
                     flags=getattr(before, 'st_flags', 0))
        out.append(e)
    visit(root, '.')
    return sorted(out, key=lambda e: e['path'])


def json_read(path):
    def unique(pairs):
        d = {}
        for k, v in pairs:
            need(k not in d, 'Duplicate JSON key')
            d[k] = v
        return d
    return json.loads(Path(path).read_bytes(), object_pairs_hook=unique)


def envelope(path, schema=True):
    value = json_read(path)
    need(not schema or value.get('schemaVersion') == 1, 'Unsupported protected envelope schema')
    data = base64.b64decode(value['payload'], validate=True)
    need(sha(data) == value['sha256'], 'Protected payload checksum mismatch')
    return json.loads(data)


def validate_move_permissions(data):
    directory = safe(data / 'MovePlans')
    info = os.lstat(directory)
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) & 0o077 == 0,
         'MovePlans must already have production private-directory permissions; source is never repaired')
    for rel in ['MovePlans/initialized.json', 'MovePlans/ledger.json', 'MovePlans.initialized']:
        info = os.lstat(safe(data / rel))
        need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid()
             and stat.S_IMODE(info.st_mode) & 0o077 == 0,
             'Source move ledger type/owner/private permissions do not satisfy production engine: ' + rel)


def validate(data):
    validate_move_permissions(data)
    for rel in REQUIRED:
        need((data / rel).is_file(), 'Initialized source is incomplete: ' + rel)
    for name in ['configuration', 'associations_history']:
        need((data / (name + '.initialized')).read_bytes() == b'schema=1\n', 'Invalid initialization marker')
    config = envelope(data / 'configuration.json')
    need(config.get('schemaVersion') == 1 and isinstance(config['workspaces'], list) and isinstance(config['savedQueries'], list), 'Unsupported configuration')
    associations = envelope(data / 'associations_history.json')
    need(isinstance(associations, list), 'Invalid association history')
    marker = json_read(data / 'index-initialized.json')
    need(marker.get('schemaVersion') in [1, 2] and str(uuid.UUID(marker['databaseID'])).upper() == marker['databaseID'].upper(), 'Index marker invalid')
    connection = sqlite3.connect('file:' + urllib.parse.quote(str(data / 'metadata.sqlite')) + '?mode=ro&immutable=1', uri=True)
    try:
        need(connection.execute('PRAGMA quick_check').fetchall() == [('ok',)], 'SQLite integrity failure')
        version = connection.execute('PRAGMA user_version').fetchone()[0]
        need(version in [1, 2], 'Unsupported SQLite schema')
        need(connection.execute('SELECT value FROM index_meta WHERE key=?', ('databaseID',)).fetchall() == [(marker['databaseID'],)], 'Index databaseID mismatch')
        need(not connection.execute('PRAGMA foreign_key_check').fetchall(), 'SQLite foreign key corruption')
        for table in ['index_meta', 'schema_history', 'authorized_roots', 'files', 'scan_checkpoints', 'staged_files']:
            need(connection.execute('SELECT count(*) FROM sqlite_master WHERE type=? AND name=?', ('table', table)).fetchone()[0] == 1, 'Missing SQLite table: ' + table)
        roots = list(connection.execute('SELECT id,path FROM authorized_roots'))
        for ident, path in roots:
            uuid.UUID(ident)
            need(path.startswith('/'), 'Root must be absolute')
        file_count = connection.execute('SELECT count(*) FROM files').fetchone()[0]
    finally:
        connection.close()
    move_marker = json_read(data / 'MovePlans/initialized.json')
    need(move_marker.get('schemaVersion') == 1 and json_read(data / 'MovePlans.initialized') == move_marker, 'Move initialization pair mismatch')
    moves = envelope(data / 'MovePlans/ledger.json', schema=False)
    need(moves.get('schemaVersion') == 1 and moves['storeID'] == move_marker['storeID'] and len(moves['plans']) <= 1000, 'Invalid move ledger')
    ids = set()
    for plan in moves['plans']:
        ident = str(uuid.UUID(plan['id']))
        need(ident not in ids and len(plan['operations']) <= 256, 'Duplicate move ID or excessive operations')
        ids.add(ident)
    exchange = envelope(data / 'Exchange/Journal/ledger.json')
    need(exchange.get('schemaVersion') == 1 and len(exchange['records']) <= 4096 and json_read(data / 'exchange-initialized.json').get('schemaVersion') == 1, 'Invalid exchange history')
    return marker['databaseID'], version, config, associations, moves, exchange, roots, file_count


def file_url(value):
    if isinstance(value, str):
        if value.startswith('file://'):
            url = urllib.parse.urlparse(value)
            need(url.netloc in ['', 'localhost'], 'Remote file URL rejected')
            return urllib.parse.unquote(url.path)
        if value.startswith('/'):
            return value
    return None


def strings(value):
    if isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)
    elif isinstance(value, str):
        p = file_url(value)
        if p:
            yield p


def validate_copy_provenance(rows, evidence):
    need(isinstance(evidence, dict) and set(evidence) == {row['path'] for row in rows}, 'Copy provenance evidence entry set differs')
    for row in rows:
        value = evidence[row['path']]
        digest = row['xattrs'].get(PROVENANCE)
        if value is None:
            need(digest is None, 'Missing raw provenance evidence: ' + row['path'])
            continue
        need(isinstance(value, dict) and set(value) == {'base64', 'byteCount', 'sha256'}
             and isinstance(value['base64'], str) and type(value['byteCount']) is int
             and 0 <= value['byteCount'] <= 16 * 1024 * 1024, 'Invalid raw provenance evidence')
        raw = base64.b64decode(value['base64'], validate=True)
        need(len(raw) == value['byteCount'] and sha(raw) == value['sha256'] == digest, 'Raw provenance evidence digest differs: ' + row['path'])


def compare_data_copy(before, copied, source_provenance, copy_provenance, *, allow_provenance):
    """New objects have new physical identities; all other fields stay exact."""
    validate_copy_provenance(before, source_provenance)
    validate_copy_provenance(copied, copy_provenance)
    a, b = {row['path']: row for row in before}, {row['path']: row for row in copied}
    need(len(a) == len(before) and len(b) == len(copied) and a.keys() == b.keys(), 'Copy entry set differs')
    differences = []
    for path, original in a.items():
        first, second = dict(original), dict(b[path])
        # These belong to the new object. UID/GID/mode/nlink/mtime/flags are
        # retained and still compared; no physical-copy identity is claimed.
        for key in ['device', 'inode', 'ctimeNS']:
            first.pop(key, None); second.pop(key, None)
        first['xattrs'], second['xattrs'] = dict(first['xattrs']), dict(second['xattrs'])
        if allow_provenance:
            first['xattrs'].pop(PROVENANCE, None); second['xattrs'].pop(PROVENANCE, None)
        need(first == second, 'Copy contents/modes/owner/mtime/flags/non-provenance xattrs mismatch: ' + path)
        old, new = source_provenance[path], copy_provenance[path]
        if old != new:
            need(allow_provenance, 'Strict restore provenance differs: ' + path)
            differences.append({'relativePath': path, 'attribute': PROVENANCE, 'source': old, 'copy': new})
    return differences


def copy_exact(source, target, *, allow_provenance=True):
    need(not os.path.lexists(target), 'Copy destination exists')
    source_provenance, copy_provenance = {}, {}
    before = inventory(source, True, source_provenance)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/ditto', '--rsrc', '--extattr', '--acl', str(source), str(target)], check=True, capture_output=True)
    copied = inventory(target, True, copy_provenance)
    differences = compare_data_copy(before, copied, source_provenance, copy_provenance, allow_provenance=allow_provenance)
    after_provenance = {}
    need(inventory(source, True, after_provenance) == before and after_provenance == source_provenance, 'Copy source identity/contents/attributes changed')
    return {'schemaVersion': 1, 'policy': COPY_POLICY, 'sourceRoot': str(source), 'copyRoot': str(target),
            'sourceInventorySHA256': sha(encoded(before)), 'copyInventorySHA256': sha(encoded(copied)),
            'allowEvidencedOSProvenanceDifference': allow_provenance, 'provenanceDifferences': differences,
            'sourceRetainedUnchanged': True, 'fullPhysicalMetadataCopyExact': False}


def require_standalone_data(data):
    """Only the new private Data is queried; never remove unknown sidecars."""
    data = safe(data)
    need(data.name == 'Data' and data.parent.name.endswith('.noindex')
         and (data.parent / '.organizer-export-owner').read_bytes() == b'GaoWenJian Organizer snapshot v1\n',
         'Standalone check requires this export private Data')
    blocked = SIDECARS | {'metadata.sqlite.wal'}
    need(not any(os.path.lexists(data / name) for name in blocked), 'Private Data has SQLite sidecars; preserve output and stop')
    database = data / 'metadata.sqlite'
    before = inventory(database, True)
    with database.open('rb') as file:
        header = file.read(100)
    need(header[:16] == b'SQLite format 3\0' and header[18:20] == b'\x01\x01', 'Private Data is not a rollback-journal standalone database')
    connection = sqlite3.connect('file:' + urllib.parse.quote(str(database)) + '?mode=ro&immutable=1', uri=True)
    try:
        mode = connection.execute('PRAGMA journal_mode').fetchall()
        need(mode == [('delete',)], 'Private Data journal mode is not DELETE')
    finally:
        connection.close()
    need(inventory(database, True) == before and not any(os.path.lexists(data / name) for name in blocked),
         'Private Data changed or acquired SQLite sidecars during standalone check')
    return {'journalMode': 'delete', 'persistentHeaderJournalBytes': [1, 1], 'sidecarsAbsent': True,
            'immutableCheckDatabaseUnchanged': True}


def backup_private_database(work, data):
    """Merge WAL only in this new work copy before backing up into fresh Data.

    SQLite 3.54 may leave an SHM when changing a WAL-header backup destination
    to DELETE. Convert the disposable work first; the final destination never
    inherits that WAL header or its transitional sidecar.
    """
    work, data = safe(work), safe(data)
    need(work.name == '.sqlite-work.noindex' and data.name == 'Data' and work.parent == data.parent
         and (data.parent / '.organizer-export-owner').read_bytes() == b'GaoWenJian Organizer snapshot v1\n',
         'Backup requires this export private work/Data pair')
    read(work / 'metadata.sqlite')  # Existing owned ordinary input; rw must not create it.
    need(not os.path.lexists(data / 'metadata.sqlite'), 'Private backup destination already exists')
    rawdb = sqlite3.connect('file:' + urllib.parse.quote(str(work / 'metadata.sqlite')) + '?mode=rw', uri=True)
    targetdb = None
    try:
        checkpoint = rawdb.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall()
        need(len(checkpoint) == 1 and len(checkpoint[0]) == 3 and checkpoint[0][0] == 0,
             'Private work checkpoint did not finish; preserve output')
        need(rawdb.execute('PRAGMA journal_mode=DELETE').fetchall() == [('delete',)],
             'Private work journal mode did not become DELETE')
        rawdb.commit()
        targetdb = sqlite3.connect(str(data / 'metadata.sqlite'))
        rawdb.backup(targetdb)
        need(targetdb.execute('PRAGMA journal_mode=DELETE').fetchall() == [('delete',)],
             'Private Data journal mode did not become DELETE')
        targetdb.commit()
    finally:
        if targetdb is not None:
            targetdb.close()
        rawdb.close()
    result = require_standalone_data(data)
    result.update(method='checkpoint-private-work-to-delete-before-backup', privateWorkCheckpoint=list(checkpoint[0]))
    return result


def export(source, preferences, output, retiring):
    # A fixture helper must never export actual application or user data.
    # The first container must be created by a GaoWenJian test harness.
    paths = [source, preferences, output, *[Path(p) for p in retiring]]
    for candidate in paths:
        path = Path(candidate)
        need(path.is_absolute() and len(path.parts) > 4 and path.parts[:3] == ('/', 'private', 'tmp')
             and path.parts[3].startswith('gaowenjian-') and '..' not in path.parts,
             'Only synthetic data in an isolated /private/tmp/gaowenjian-* test container is allowed')
        need(path.parent.resolve() == path.parent, 'Fixture paths cannot resolve through symbolic links')
    source, preferences = safe(source), safe(preferences)
    safe(output.parent)
    need(not os.path.lexists(output) and output.name.endswith('.noindex'), 'Output must be a NEW .noindex container')
    need(source != output and source not in output.parents and output not in source.parents, 'Source/output overlap')
    prefs = plistlib.loads(preferences.read_bytes())
    need(prefs.get('GaoZhengLi.initialized.v1') is True, 'Missing independent source initialization preference')
    lock = None
    if (source / '.app.lock').exists():
        lock = os.open(source / '.app.lock', os.O_RDONLY | os.O_NOFOLLOW)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        before, prefs_before = inventory(source, True), inventory(preferences, True)
        validate_move_permissions(source)
        output.mkdir(mode=0o700)
        (output / '.organizer-export-owner').write_bytes(b'GaoWenJian Organizer snapshot v1\n')
        raw = output / 'SourceRaw'
        copy_verifications = [copy_exact(source, raw), copy_exact(preferences, output / 'SourcePreferences.plist')]
        data = output / 'Data'
        copy_verifications.append(copy_exact(raw, data))
        for rel in sorted(LOCKS | SIDECARS | {'metadata.sqlite'}):
            p = data / rel
            if p.exists():
                need(p.is_file() and not p.is_symlink(), 'Unexpected copied runtime file')
                p.unlink()  # Only verified new private copy, never the source.
        work = output / '.sqlite-work.noindex'
        work.mkdir(mode=0o700)
        for rel in ['metadata.sqlite', 'metadata.sqlite-wal', 'metadata.sqlite-shm']:
            if (raw / rel).exists():
                copy_verifications.append(copy_exact(raw / rel, work / rel))
        standalone = backup_private_database(work, data)
        shutil.rmtree(work)  # Only this freshly created private working copy.
        os.chmod(data / 'metadata.sqlite', 0o600)
        database_id, version, config, associations, moves, exchange, roots, file_count = validate(data)
        prefixes = sorted(set([str(source)] + [str(safe(Path(p))) for p in retiring]), key=len, reverse=True)
        need('/' not in prefixes, 'The whole filesystem cannot be a retiring boundary')
        all_paths = set()
        for value in [config, associations, moves, exchange]:
            all_paths.update(strings(value))
        all_paths.update(p for _, p in roots)
        required_recovery = set()
        for plan in moves['plans']:
            for op in plan['operations']:
                if op['state'] in ['renameIntent', 'moved', 'rollbackIntent']:
                    choices = [file_url(op['source']), file_url(op['destination'])]
                    existing = [p for p in choices if p and os.path.lexists(p)]
                    need(existing, 'Pending recovery has neither physical source nor destination')
                    required_recovery.update(existing)
        all_paths |= required_recovery
        references = []
        external_frozen = {}
        for value in sorted(all_paths):
            p = Path(value)
            inside_source = p == source or source in p.parents
            retired = any(value == prefix or value.startswith(prefix + '/') for prefix in prefixes)
            if not retired and value not in required_recovery:
                continue  # User originals stay at their original path and require new authorization.
            exists = os.path.lexists(p)
            if inside_source:
                relative = 'Data' + ('' if p == source else '/' + str(p.relative_to(source)))
            elif exists:
                relative = 'References/' + sha(value.encode()) + '/' + p.name
                external_frozen[value] = inventory(p, True)
                copy_verifications.append(copy_exact(p, output / relative))
            else:
                relative = None
            references.append({'originalPath': value, 'snapshotRelativePath': relative,
                               'requiredForRecovery': value in required_recovery, 'exists': exists,
                               'retiringPath': retired})
        need(inventory(source, True) == before and inventory(preferences, True) == prefs_before,
             'Source or preferences changed during export; output is NOT verified')
        need(all(inventory(Path(p), True) == frozen for p, frozen in external_frozen.items()), 'Recovery reference changed during export')
        need(require_standalone_data(data) == {key: standalone[key] for key in ['journalMode', 'persistentHeaderJournalBytes', 'sidecarsAbsent', 'immutableCheckDatabaseUnchanged']},
             'Final private Data standalone state changed before manifest')
        # SourceRaw is evidence, not an openable SQLite store. Its SHM can be
        # altered by SQLite reading the private raw copy; freeze the completed copy.
        entries = inventory(output)
        entries = [e for e in entries if e['path'] != '.']
        manifest = {'schemaVersion': 1, 'snapshotID': str(uuid.uuid4()).upper(), 'sourceBundleID': 'com.gaoseries.GaoZhengLi',
                    'sourceDatabaseID': database_id, 'sourceDataRoot': str(source), 'indexSchemaVersion': version, 'initialized': True,
                    'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    'entries': entries, 'references': references, 'retiringPrefixes': prefixes,
                    'sourceInventorySHA256': sha(encoded(before)), 'sourcePreferencesSHA256': prefs_before[0]['sha256'],
                    'rootCount': len(roots), 'fileCount': file_count, 'sourceReadOnlyAndStable': True,
                    'sqliteSnapshotMethod': 'sqlite-online-backup-from-private-raw-copy-including-WAL',
                    'dataCopyPolicy': COPY_POLICY, 'copyVerifications': copy_verifications,
                    'sqliteStandaloneVerification': standalone,
                    'sourceBookmarksRequireAuthorization': True, 'oldExchangeHistoryOnly': True}
        (output / 'snapshot.json').write_bytes(encoded(manifest) + b'\n')
        (output / 'VERIFIED').write_bytes(('schema=1;sha256=' + sha((output / 'snapshot.json').read_bytes()) + '\n').encode())
        # Actual restore drill of the complete exported objects into another
        # owned new container; compares every exported file/xattr and opens DB.
        restore_root = Path(tempfile.mkdtemp(prefix='gaowenjian-organizer-restore.', suffix='.noindex', dir='/private/tmp'))
        (restore_root / '.owner').write_bytes(b'GaoWenJian Organizer restore drill\n')
        try:
            restored = restore_root / 'Snapshot'
            # Frozen production import requires allExportedObjectsMatch. Keep
            # this final complete restore strict, including OS provenance;
            # never redefine that existing field to conceal an attribute delta.
            restored_copy = copy_exact(output, restored, allow_provenance=False)
            validate(restored / 'Data')
            restore_report = {'schemaVersion': 1, 'pass': True, 'actualFilesystemRestore': True,
                              'snapshotSHA256': sha((output / 'snapshot.json').read_bytes()),
                              'allExportedObjectsMatch': True, 'SQLiteQuickCheckPassed': True,
                              'dataCopyPolicy': COPY_POLICY, 'restoreCopyVerification': restored_copy,
                              'sourceUnchanged': inventory(source, True) == before and inventory(preferences, True) == prefs_before}
            need(restore_report['sourceUnchanged'], 'Source changed before restore completion')
            (output / 'RestoreReport.json').write_bytes(encoded(restore_report) + b'\n')
        finally:
            need(restore_root.parent == Path('/private/tmp') and (restore_root / '.owner').read_bytes() == b'GaoWenJian Organizer restore drill\n', 'Restore cleanup owner conflict')
            shutil.rmtree(restore_root)
        return {'snapshotID': manifest['snapshotID'], 'snapshotPath': str(output), 'manifestSHA256': sha((output / 'snapshot.json').read_bytes()),
                'roots': len(roots), 'files': file_count, 'referenceCount': len(references), 'actualRestorePassed': True}
    finally:
        if lock is not None:
            os.close(lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--preferences', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--retiring-path', action='append', default=[])
    args = parser.parse_args()
    print(json.dumps(export(args.source, args.preferences, args.output, args.retiring_path), ensure_ascii=False))


if __name__ == '__main__':
    main()
