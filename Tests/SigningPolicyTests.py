"""Changed signing-policy tests only: no identity lookup, private key or signing."""
import importlib.util
import copy
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('file_signing',Path(__file__).resolve().parents[1]/'Scripts/sign_bundle.py')
signing=importlib.util.module_from_spec(spec);spec.loader.exec_module(signing)

class SigningPolicyTests(unittest.TestCase):
    def test_native_xattr_inventory_is_complete_and_fail_closed(self):
        import hashlib
        with tempfile.TemporaryDirectory(prefix='gaowenjian-native-xattr.',suffix='.noindex',dir='/private/tmp') as t:
            path=Path(t)/'fixture';path.write_bytes(b'isolated fixture')
            signing.run(['/usr/bin/xattr','-w','com.gaoseries.signing-test','value',path])
            signing.run(['/usr/bin/xattr','-w','com.gaoseries.signing-empty','',path])
            attrs=signing.xattr_hashes(path)
            self.assertEqual(attrs['com.gaoseries.signing-test'],hashlib.sha256(b'value').hexdigest())
            self.assertEqual(attrs['com.gaoseries.signing-empty'],hashlib.sha256(b'').hexdigest())
            self.assertEqual(signing.inventory(Path(t))['fixture']['xattrs'],attrs)
            with self.assertRaises(OSError):signing.xattr_hashes(Path(t)/'missing')

    def test_actual_designated_requirement_must_match_complete_policy(self):
        fixed='designated => '+signing.requirement(signing.BUNDLE)
        signing.require_stable_designated(fixed,signing.BUNDLE)
        signing.require_stable_designated(fixed.replace(' and ','  and\t'),signing.BUNDLE)
        signing.require_stable_designated('library => anchor apple\n'+fixed,signing.BUNDLE)
        for wrong in ('# '+fixed,fixed+' and certificate leaf[subject.CN] = "extra"',fixed+'\n'+fixed):
            with self.subTest(wrong=wrong),self.assertRaises(RuntimeError):
                signing.require_stable_designated(wrong,signing.BUNDLE)

    def test_final_copy_receipt_compares_portable_data_without_path_details(self):
        source={'schemaVersion':1,'identitySHA1':signing.IDENTITY,'teamIdentifier':signing.TEAM,
                'hostBundleID':signing.BUNDLE,'stableRequirementTemplate':'designated => '+signing.requirement(signing.BUNDLE),
                'actualZIPRestore':{'pass':True},'machO':{'Contents/MacOS/GaoWenJian':{'architectures':'arm64','sha256':'fixture'}},
                'inventory':{'.':{'mode':493,'mtimeNS':123}},'signedCodeObjects':{'.':{
                    'identifier':signing.BUNDLE,'rawFlags':0,'semanticFlags':0,'entitlements':None,
                    'entitlementsXMLSHA256':'xml','entitlementsDERSHA256':'der',
                    'fullRequirements':'library => anchor apple\ndesignated => '+signing.requirement(signing.BUNDLE),
                    'details':'Executable=/private/tmp/staging.noindex/搞文件.app/Contents/MacOS/GaoWenJian'}}}
        actual=copy.deepcopy(source);actual.pop('actualZIPRestore')
        actual['signedCodeObjects']['.']['details']='Executable=/final.noindex/搞文件.app/Contents/MacOS/GaoWenJian'
        self.assertTrue(signing.compare_copy_receipts(source,actual)['pass'])
        mutations=[('inventory',lambda value:value['inventory']['.'].update(mtimeNS=124)),
                   ('machO',lambda value:value['machO']['Contents/MacOS/GaoWenJian'].update(sha256='changed')),
                   ('identitySHA1',lambda value:value.update(identitySHA1='wrong')),
                   ('signedCodeObjects...entitlements',lambda value:value['signedCodeObjects']['.'].update(entitlements={'extra':True})),
                   ('signedCodeObjects...semanticFlags',lambda value:value['signedCodeObjects']['.'].update(semanticFlags=1)),
                   ('signedCodeObjects...fullRequirements',lambda value:value['signedCodeObjects']['.'].update(fullRequirements='designated => '+signing.requirement(signing.BUNDLE)))]
        for field,mutate in mutations:
            changed=copy.deepcopy(actual);mutate(changed);before=copy.deepcopy(changed)
            result=signing.compare_copy_receipts(source,changed)
            with self.subTest(field=field):
                self.assertFalse(result['pass']);self.assertIn(field,result['differences']);self.assertEqual(changed,before)
        invalid=copy.deepcopy(source);invalid['actualZIPRestore']['pass']=False
        self.assertFalse(signing.compare_copy_receipts(invalid,actual)['pass'])

    def test_signing_command_uses_literal_requirement_source(self):
        # A missing '=' makes codesign read a filename instead of the stable DR.
        with patch.object(signing,'run') as execute:
            command=signing.signing_command(signing.BUNDLE,0x10000,Path('/private/tmp/fixture.plist'))
            self.assertEqual(command[command.index('--requirements')+1],
                             '=designated => '+signing.requirement(signing.BUNDLE))
            self.assertEqual(command[command.index('--sign')+1],signing.IDENTITY)
            self.assertEqual(command[command.index('--options')+1],'0x10000')
            self.assertEqual(command[command.index('--entitlements')+1],'/private/tmp/fixture.plist')
            self.assertNotIn('--deep',command)
            execute.assert_not_called()

    def test_stable_requirement_and_signature_mechanism_flags(self):
        value=signing.requirement(signing.BUNDLE)
        self.assertIn('anchor apple generic',value);self.assertIn('5G96498KGJ',value)
        self.assertNotIn('cdhash',value)
        self.assertEqual(0x20002 & ~signing.MECHANISM_FLAGS,0)
        self.assertEqual(0x10002 & ~signing.MECHANISM_FLAGS,0x10000)
        with self.assertRaises(RuntimeError):signing.requirement('bad" or always')

    def test_empty_user_identity_context_fails_without_fallback(self):
        calls=[]
        def no_identity(command):
            calls.append(command);return SimpleNamespace(stdout=b'0 valid identities found',stderr=b'',returncode=0)
        with patch.object(signing,'run',no_identity):
            with self.assertRaises(RuntimeError):signing.identity_available()
        self.assertEqual(calls,[['/usr/bin/security','find-identity','-v','-p','codesigning']])

    def test_inside_out_includes_resource_tool_and_framework(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-sign-policy.',suffix='.noindex',dir='/private/tmp') as t:
            root=Path(t);app=root/'搞文件.app'
            main=app/'Contents/MacOS/GaoWenJian';main.parent.mkdir(parents=True)
            main.write_bytes(bytes.fromhex('cffaedfe'))
            info={'CFBundleIdentifier':signing.BUNDLE,'CFBundleExecutable':'GaoWenJian'}
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            tool=app/'Contents/Resources/Tools/tectonic';tool.parent.mkdir(parents=True);tool.write_bytes(bytes.fromhex('cffaedfe'))
            framework=app/'Contents/Frameworks/Fixture.framework';(framework/'Resources').mkdir(parents=True)
            (framework/'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.example.Fixture','CFBundleExecutable':'Fixture'}))
            (framework/'Fixture').write_bytes(bytes.fromhex('cffaedfe'))
            objects,ids,machines=signing.code_objects(app)
            self.assertEqual(objects[-1],app);self.assertIn(tool,objects);self.assertIn(framework,objects)
            self.assertEqual(ids[tool],signing.BUNDLE+'.tectonic');self.assertEqual(len(machines),3)
            self.assertEqual(signing.private_app(app),app)

    def test_hardlinked_native_code_is_not_mutable_staging(self):
        with tempfile.TemporaryDirectory(prefix='gaowenjian-sign-policy.',suffix='.noindex',dir='/private/tmp') as t:
            app=Path(t)/'搞文件.app';main=app/'Contents/MacOS/GaoWenJian';main.parent.mkdir(parents=True)
            main.write_bytes(bytes.fromhex('cffaedfe'))
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':signing.BUNDLE,'CFBundleExecutable':'GaoWenJian'}))
            outside=Path(t)/'retained-original';outside.hardlink_to(main)
            with self.assertRaises(RuntimeError):signing.code_objects(app)
            self.assertEqual(outside.read_bytes(),bytes.fromhex('cffaedfe'))

if __name__=='__main__':unittest.main(verbosity=2)
