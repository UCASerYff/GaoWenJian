"""Only new retention/finalized-rollback behavior, in private synthetic roots."""
import argparse,contextlib,importlib.util,io,json,os,plistlib,shutil,subprocess,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode=True
SCRIPTS=Path(__file__).resolve().parent.parent/'Scripts'
spec=importlib.util.spec_from_file_location('receiver_retention_installer',SCRIPTS/'install_safety.py');installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)

def app(path,version,build,payload):
    (path/'Contents/MacOS').mkdir(parents=True)
    (path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':installer.BUNDLE,'CFBundleExecutable':'GaoWenJian','CFBundleShortVersionString':version,'CFBundleVersion':build}))
    (path/'Contents/MacOS/GaoWenJian').write_bytes(payload);(path/'Contents/MacOS/GaoWenJian').chmod(0o755)

class ReceiverProgramRetentionTests(unittest.TestCase):
    def transaction(self,root):
        target=root/'Applications/搞文件.app';source=root/'New/搞文件.app'
        app(target,'1.09','10',b'previous original synthetic program');app(source,'1.10','11',b'new synthetic program')
        native=installer.native_state();before=installer.native_program_evidence(target)
        old_id=target.stat().st_ino
        data=root/'ReceiverData';data.mkdir(mode=0o700);(data/'workspace.json').write_bytes(b'initial receiver data')
        prefs=root/'preferences.plist';prefs.write_bytes(b'synthetic preferences')
        output=io.StringIO()
        args=argparse.Namespace(app=str(source),target=str(target),data_root=str(data),preferences=str(prefs),backup_root=str(root/'ReceiverBackups'),simulate=True,defer_cleanup=True)
        with contextlib.redirect_stdout(output):installer.install(args)
        path=Path(next(line[9:] for line in output.getvalue().splitlines() if line.startswith('MANIFEST=')))
        return target,data,path,before,old_id

    def finalize(self,path,**overrides):
        args=argparse.Namespace(manifest=str(path),rollback=False,verified=True,require_unchanged_data=False,verification_note='Only synthetic retained-original/rollback fixture',previous_native_before=None)
        for key,value in overrides.items():setattr(args,key,value)
        with contextlib.redirect_stdout(io.StringIO()):installer.finalize(args)

    def test_verified_retains_same_native_original_and_standalone_tool_can_restore(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-retained-program-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();target,data,path,before,old_id=self.transaction(root)
            (data/'workspace.json').write_bytes(b'legitimate receiver changes retained')
            self.finalize(path)
            manifest=installer.load_manifest(path);self.assertEqual(manifest['state'],'verified');self.assertFalse(manifest['unchanged_data_verified'])
            previous=Path(manifest['stage_dir'])/'previous.app'
            self.assertTrue(previous.exists());self.assertEqual(previous.stat().st_ino,old_id)
            installer.native_state().moved_equal(before['fullNativeOriginalState'],installer.native_state().full_state(previous))
            receipt=installer.verify_program_retention(manifest,path)
            self.assertTrue(receipt['originalSignature']['notARealSignatureVerification'])
            result=subprocess.run(manifest['retained_previous_program']['restore_command'],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(target.stat().st_ino,old_id)
            self.assertEqual((target/'Contents/MacOS/GaoWenJian').read_bytes(),b'previous original synthetic program')
            self.assertEqual((data/'workspace.json').read_bytes(),b'legitimate receiver changes retained')
            self.assertEqual(installer.load_manifest(path)['state'],'rolled_back')
            self.assertTrue((path.parent/'ProgramRecovery.noindex/restored.json').exists())

    def test_legacy_pending_uses_external_before_without_rewriting_it(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-retention-legacy-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();target,data,path,before,old_id=self.transaction(root)
            manifest=installer.load_manifest(path);manifest.pop('program_before_native');installer.atomic_json(path,manifest)
            evidence=root/'Root-before.json';payload=json.dumps(before).encode();evidence.write_bytes(payload)
            self.finalize(path,previous_native_before=str(evidence))
            self.assertEqual(evidence.read_bytes(),payload)
            current=installer.load_manifest(path);self.assertEqual(Path(current['retained_previous_program']['program_path']).stat().st_ino,old_id)
            self.assertEqual(current['retained_previous_program']['restore_command'][1],str(path.parent/'ProgramRecovery.noindex/Tools/install_safety.py'))

    def test_missing_before_or_unchanged_data_claim_refuses_without_deleting_original(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-retention-refusal-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();target,data,path,before,old_id=self.transaction(root)
            manifest=installer.load_manifest(path);manifest.pop('program_before_native');installer.atomic_json(path,manifest)
            with self.assertRaisesRegex(RuntimeError,'元数据依据'):self.finalize(path)
            previous=Path(manifest['stage_dir'])/'previous.app';self.assertEqual(previous.stat().st_ino,old_id)
            evidence=root/'Before.json';evidence.write_text(json.dumps(before))
            (data/'workspace.json').write_bytes(b'legitimate changed data')
            with self.assertRaisesRegex(RuntimeError,'资料或设置'):self.finalize(path,previous_native_before=str(evidence),require_unchanged_data=True)
            self.assertEqual(previous.stat().st_ino,old_id);self.assertEqual(installer.load_manifest(path)['state'],'installed_pending_verification')
            self.assertFalse((path.parent/'ProgramRecovery.noindex').exists())

    def test_native_drift_blocks_later_verification(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-retention-drift-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();target,data,path,before,old_id=self.transaction(root);self.finalize(path)
            manifest=installer.load_manifest(path);previous=Path(manifest['stage_dir'])/'previous.app'
            payload=previous/'Contents/MacOS/GaoWenJian';subprocess.run(['/usr/bin/xattr','-w','com.gaoseries.synthetic-retention','changed',str(payload)],check=True,capture_output=True)
            with self.assertRaisesRegex(RuntimeError,'原生元数据'):installer.verify_program_retention(manifest,path)
            self.assertEqual(previous.stat().st_ino,old_id)

    def test_restore_tool_change_refuses_and_keeps_retained_original(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-retention-tool-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();target,data,path,before,old_id=self.transaction(root);self.finalize(path)
            manifest=installer.load_manifest(path);previous=Path(manifest['stage_dir'])/'previous.app'
            tool=path.parent/'ProgramRecovery.noindex/Tools/install_safety.py';tool.write_bytes(tool.read_bytes()+b'\n# unexpected change\n')
            with self.assertRaisesRegex(RuntimeError,'恢复工具摘要'):installer.verify_program_retention(manifest,path)
            self.assertEqual(previous.stat().st_ino,old_id);self.assertTrue(target.exists())

    def test_interrupted_restore_after_original_return_resumes_from_durable_intent(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-retention-resume-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();target,data,path,before,old_id=self.transaction(root);self.finalize(path)
            manifest=installer.load_manifest(path);command=manifest['retained_previous_program']['restore_command']
            actual_register=installer.register
            def interrupted(p,simulate,remove=False):
                if p==target and not remove:raise RuntimeError('synthetic registration failure after same-inode return')
                return actual_register(p,simulate,remove=remove)
            with patch.object(installer,'register',side_effect=interrupted),self.assertRaisesRegex(RuntimeError,'synthetic registration failure'):
                self.finalize(path,rollback=True,verified=False)
            self.assertEqual(target.stat().st_ino,old_id)
            self.assertFalse((Path(manifest['stage_dir'])/'previous.app').exists())
            self.assertTrue((path.parent/'ProgramRecovery.noindex/restore-intent.json').exists())
            self.assertEqual(installer.load_manifest(path)['state'],'verified')
            resumed=subprocess.run(command,capture_output=True,text=True)
            self.assertEqual(resumed.returncode,0,resumed.stderr)
            self.assertEqual(target.stat().st_ino,old_id)
            final=installer.load_manifest(path);self.assertEqual(final['state'],'rolled_back')
            self.assertTrue((Path(manifest['stage_dir'])/'failed-candidate.app').exists())
            self.assertEqual(final['program_restoration']['original_identity'],':'.join(map(str,(target.stat().st_dev,old_id,os.getuid()))))

    def test_missing_candidate_restore_retry_refuses_unknown_failed_program(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-retention-unknown-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();target,data,path,before,old_id=self.transaction(root);self.finalize(path)
            manifest=installer.load_manifest(path);shutil.rmtree(target)  # This private synthetic candidate only.
            actual_register=installer.register
            def interrupted(p,simulate,remove=False):
                if p==target and not remove:raise RuntimeError('synthetic stop after original return')
                return actual_register(p,simulate,remove=remove)
            with patch.object(installer,'register',side_effect=interrupted),self.assertRaises(RuntimeError):self.finalize(path,rollback=True,verified=False)
            failed=Path(manifest['stage_dir'])/'failed-candidate.app';app(failed,'1.10','11',b'unknown synthetic program')
            with patch.object(installer,'register') as register,self.assertRaisesRegex(RuntimeError,'未知失败程序'):
                self.finalize(path,rollback=True,verified=False)
            register.assert_not_called();self.assertEqual(target.stat().st_ino,old_id)
            self.assertEqual((failed/'Contents/MacOS/GaoWenJian').read_bytes(),b'unknown synthetic program')

    def test_retained_previous_process_guard_stops_before_recovery_writes(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-retention-running-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();target,data,path,before,old_id=self.transaction(root)
            with patch.object(installer,'ensure_not_running',side_effect=RuntimeError('synthetic running previous')),self.assertRaisesRegex(RuntimeError,'running previous'):self.finalize(path)
            self.assertFalse((path.parent/'ProgramRecovery.noindex').exists())
            self.assertEqual((Path(installer.load_manifest(path)['stage_dir'])/'previous.app').stat().st_ino,old_id)

    def test_local_native_schema_complete_and_same_inode_move(self):
        native=installer.native_state()
        with tempfile.TemporaryDirectory(prefix='gaowenjian-native-schema-',suffix='.noindex',dir='/private/tmp') as temporary:
            root=Path(temporary).resolve();item=root/'Original';item.mkdir(mode=0o700);(item/'ordinary').write_bytes(b'native fixture')
            before=native.full_state(item)
            self.assertEqual(set(before),{'tree','metadata','provenance'})
            self.assertEqual(set(before['metadata']['']),{'stat','birthTime','acl','xattrs'})
            destination=root/'Retained';item.rename(destination);after=native.full_state(destination)
            native.moved_equal(before,after)
            self.assertEqual(before['metadata']['']['stat'][1],after['metadata']['']['stat'][1])

if __name__=='__main__':unittest.main(verbosity=2)
