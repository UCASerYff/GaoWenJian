"""Public-tree path gate only; no network, repository mutation or real package."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
SCRIPTS=Path(__file__).resolve().parent.parent/'Scripts'
spec=importlib.util.spec_from_file_location('public_source_package',SCRIPTS/'package-public-source.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class PublicSourcePackageTests(unittest.TestCase):
    def test_public_code_resources_and_licenses_allowed(self):
        for name in ['VERSION','BUILD','README.md','使用说明.txt','Sources/App.swift','Scripts/install_safety.py','Tests/InstallTests.py','Docs/Licenses/Organizer-MIT.txt','Resources/Fonts/font.woff2','Assets/AppIcon.svg','Tools/OrganizerMigrationCLI.swift']:
            with self.subTest(name=name):self.assertTrue(module.public_path(name))

    def test_private_runtime_program_and_generated_paths_refuse(self):
        for name in ['安全备份/manifest.json','Release/package.zip','.git/config','Sources/.env','Sources/private.key','Resources/Previous.APP/Info.plist','Docs/previous.app.zip','Tools/cache.noindex/data.json','Sources/workspace.json','Docs/Recovery.json','Tests/private.sqlite','Tests/Progress.db','Scripts/__pycache__/x.pyc','Sources/../private.json','/absolute/file','Sources/runtime.dSYM/Contents/Info.plist','Docs/gaowenjian-install-private.json','Scripts/candidate.app.signing.json','Docs/GaoWenJian-1.11-copy-verification.json']:
            with self.subTest(name=name):self.assertFalse(module.public_path(name))

    def test_private_directory_names_refuse_at_any_depth(self):
        for name in ['Docs/Safety/manifest.json','Docs/Reports/receipt.json','Docs/Backups/data.json','Docs/keys/credentials.txt','Sources/feature/sAfEtY/manifest.json','Docs/nested/rEpOrTs/receipt.json','Resources/nested/BACKUPS/data.json','Tests/fixtures/KEYS/credentials.txt','Tools/nested/安全备份/manifest.json']:
            with self.subTest(name=name):self.assertFalse(module.public_path(name))

    def test_database_sidecars_refuse_without_blocking_source_names(self):
        for extension in ['sqlite','sqlite3','db']:
            for sidecar in ['wal','shm','journal']:
                for name in ['Tests/private.'+extension+'-'+sidecar,'Docs/nested/Private.'+extension.upper()+'-'+sidecar.upper()]:
                    with self.subTest(name=name):self.assertFalse(module.public_path(name))
        for name in ['Sources/DatabaseJournal.swift','Docs/SQLite-WAL.md','Tests/JournalTests.py','Docs/Build.md']:
            with self.subTest(name=name):self.assertTrue(module.public_path(name))

    def test_tracked_symlink_submodule_or_private_blob_stops_tree(self):
        for row in [b'120000 blob abc\tSources/link\0',b'160000 commit abc\tTools/submodule\0',b'100644 blob abc\tSources/.env\0']:
            with self.subTest(row=row),patch.object(module,'git',return_value=row),self.assertRaises(RuntimeError):module.tree()
        with patch.object(module,'git',return_value=b'100644 blob abc\tSources/App.swift\0'):
            self.assertEqual(module.tree(),[('100644','abc','Sources/App.swift')])

if __name__=='__main__':unittest.main(verbosity=2)
