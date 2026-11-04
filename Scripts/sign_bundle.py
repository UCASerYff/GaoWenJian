#!/usr/bin/env python3
"""Stable local Development signing, inside-out, never --deep signing.
Only new build Apps in owned private .noindex containers may be modified.
No keychain imports, unlocks, ACL changes, ad-hoc fallback, or network timestamp.
"""
import argparse, ctypes, datetime, hashlib, json, os, plistlib, re, shutil, stat, subprocess, tempfile
from pathlib import Path

IDENTITY='A15B2B2D22B018CBC842063C9A8A589946647524'
TEAM='5G96498KGJ'
BUNDLE='com.gaoseries.GaoWenJian'
MECHANISM_FLAGS=0x2 | 0x20000  # ad-hoc and linker-signed, not business options
MAGIC={bytes.fromhex(x) for x in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
CS='/usr/bin/codesign'

def need(ok,message):
    if not ok: raise RuntimeError(message)
def run(args):
    p=subprocess.run([str(a) for a in args],capture_output=True)
    need(p.returncode==0, str(args[0])+': '+p.stderr.decode(errors='replace'))
    return p

def private_app(path):
    p=Path(path)
    need(p.is_absolute() and p.resolve()==p and p.suffix=='.app' and p.is_dir(),'Signing requires an exact nonlinked App path')
    containers=[q for q in p.parents if q.name.endswith('.noindex')]
    need(containers,'Signing is only permitted inside .noindex staging')
    s=containers[0].stat();need(s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o700,'Signing container must be owned and 0700')
    need(plistlib.loads((p/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']==BUNDLE,'Wrong host bundle identity')
    return p

def identity_available():
    p=run(['/usr/bin/security','find-identity','-v','-p','codesigning'])
    text=p.stdout.decode(errors='replace')
    need(re.search(r'\b'+IDENTITY+r'\b',text,re.I),'Approved signing identity cannot be confirmed in this user context; stop, do not fall back to ad-hoc')

def identifier(value):
    need(isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,254}',value),'Unsafe or missing signing identifier')
    return value

def requirement(ident):
    return 'identifier '+json.dumps(identifier(ident))+' and anchor apple generic and certificate leaf[subject.OU] = "'+TEAM+'"'

def signing_command(ident,semantic_flags,entitlements_path=None):
    # codesign treats requirements without '=' as a file path, not source.
    command=[CS,'--force','--sign',IDENTITY,'--timestamp=none','--identifier',ident,'--options',hex(semantic_flags),'--requirements','=designated => '+requirement(ident),'--preserve-metadata=runtime,launch-constraints,library-constraints']
    if entitlements_path is not None:
        command+=['--entitlements',str(entitlements_path),'--generate-entitlement-der','--force-library-entitlements']
    return command

def require_stable_designated(full_requirements,ident):
    # codesign -d -r- emits one complete source line for each requirement.
    # Require the explicit DR; an implied '# designated' or a merely stronger
    # requirement satisfying -R does not establish the fixed future identity.
    lines=[line for line in full_requirements.splitlines() if re.match(r'^\s*designated\s*=>',line)]
    need(len(lines)==1,'Expected one explicit designated requirement')
    tokens=lambda value:re.findall(r'"(?:\\.|[^"\\])*"|=>|[=()]|[^\s"=()]+',value)
    need(tokens(lines[0])==tokens('designated => '+requirement(ident)),'Actual complete designated requirement differs from the stable policy')

def compare_copy_receipts(source,actual):
    """Compare portable copy evidence; never repair the copied App."""
    differences=[]
    if source.get('actualZIPRestore',{}).get('pass') is not True:
        differences.append('source.actualZIPRestore.pass')
    for field in ('schemaVersion','identitySHA1','teamIdentifier','hostBundleID','stableRequirementTemplate','machO','inventory'):
        if field not in source or field not in actual or source[field]!=actual[field]:differences.append(field)
    source_code=source.get('signedCodeObjects');actual_code=actual.get('signedCodeObjects')
    if not isinstance(source_code,dict) or not isinstance(actual_code,dict) or source_code.keys()!=actual_code.keys():
        differences.append('signedCodeObjects.keys')
    else:
        # details contains the historical absolute executable path; it is not
        # portable. Retain it in both receipts, but compare identity data itself.
        for path,old in source_code.items():
            new=actual_code[path]
            for field in ('identifier','rawFlags','semanticFlags','entitlements','entitlementsXMLSHA256','entitlementsDERSHA256','fullRequirements'):
                if field not in old or field not in new or old[field]!=new[field]:differences.append('signedCodeObjects.'+path+'.'+field)
    return {'pass':not differences,'differences':differences,
            'completePortableInventoryEqual':'inventory' not in differences,
            'allMachOArchitecturesAndSHA256Equal':'machO' not in differences,
            'noCopiedContentOrSecurityMetadataRepaired':True}

def macho(path):
    if path.is_symlink() or not path.is_file():return False
    with path.open('rb') as f:return f.read(4) in MAGIC

def code_objects(app):
    need(plistlib.loads((app/"Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")==BUNDLE,"Wrong host bundle identity")
    bundles=[app];mains={}
    for path in sorted(app.rglob('*')):
        if path.is_dir() and not path.is_symlink() and path.suffix in {'.app','.framework','.xpc','.appex','.bundle','.plugin'}:
            candidates=[path/'Contents/Info.plist',path/'Resources/Info.plist',path/'Info.plist']
            info=next((q for q in candidates if q.is_file()),None)
            if info:
                data=plistlib.loads(info.read_bytes())
                if data.get('CFBundleExecutable'):bundles.append(path)
    expected={}
    for path in bundles:
        infos=[path/'Contents/Info.plist',path/'Resources/Info.plist',path/'Info.plist']
        info=next(q for q in infos if q.is_file());data=plistlib.loads(info.read_bytes());ident=identifier(data.get('CFBundleIdentifier'))
        name=data.get('CFBundleExecutable');need(isinstance(name,str) and '/' not in name,'Invalid bundle executable')
        choices=[path/'Contents/MacOS'/name,path/name,path/'MacOS'/name]
        exe=next((q.resolve() for q in choices if q.is_file()),None)
        need(exe and app in exe.parents and macho(exe),'Bundle executable is missing or escapes App')
        mains[exe]=path;expected[path]=ident
    machines=sorted(p for p in app.rglob('*') if macho(p))
    for path in machines:
        state=path.lstat();need(state.st_uid==os.getuid() and state.st_nlink==1,'Native code must be owned and not hardlinked outside this App')
    for path in machines:
        if path.resolve() not in mains:
            rel=str(path.relative_to(app))
            if rel=='Contents/Resources/Tools/tectonic':expected[path]=BUNDLE+'.tectonic'
            else:
                meta=metadata(path)
                expected[path]=identifier(meta['identifier'])
    objects=sorted(expected,key=lambda p:(len(p.parts),str(p)),reverse=True)
    need(objects[-1]==app,'Host must be the final seal')
    return objects,expected,machines

def metadata(path):
    detail=run([CS,'-d','--verbose=4',path]).stderr.decode(errors='strict')
    ident=re.search(r'^Identifier=(.+)$',detail,re.M);flags=re.search(r'flags=(0x[0-9a-fA-F]+)',detail)
    need(ident and flags,'Unrecognized code signature metadata')
    req=run([CS,'-d','-r-',path]).stdout.decode(errors='strict')
    ent=run([CS,'-d','--entitlements','-','--xml',path]).stdout
    der=run([CS,'-d','--entitlements','-','--der',path]).stdout
    decoded=plistlib.loads(ent) if ent else None
    need(decoded is None or isinstance(decoded,dict),'Invalid entitlement dictionary')
    return {'identifier':ident.group(1),'rawFlags':int(flags.group(1),16),'semanticFlags':int(flags.group(1),16)&~MECHANISM_FLAGS,'entitlements':decoded,'entitlementsXMLSHA256':hashlib.sha256(ent).hexdigest(),'entitlementsDERSHA256':hashlib.sha256(der).hexdigest(),'rawEntitlementsXML':ent.decode() if ent else None,'details':detail,'fullRequirements':req}

def verify_objects(app,temp):
    objects,expected,machines=code_objects(app);proof={}
    certificates=Path(tempfile.mkdtemp(prefix="certificates-",dir=temp))
    for index,path in enumerate(objects):
        m=metadata(path);ident=expected[path]
        need(m['identifier']==ident and re.search(r'^TeamIdentifier='+re.escape(TEAM)+r'$',m['details'],re.M),'Wrong signing identifier or Team')
        need(not m['rawFlags']&MECHANISM_FLAGS and not re.search(r'\bcdhash\b',m['fullRequirements'],re.I),'Old ad-hoc/linker identity or cdhash requirement retained')
        require_stable_designated(m['fullRequirements'],ident)
        run([CS,'--verify','--strict','--all-architectures','-R','='+requirement(ident),path])
        # The optional prefix must be attached; a separated token is parsed as
        # another code path by codesign instead of as the extraction prefix.
        prefix=certificates/('certificate-'+str(index)+'-');run([CS,'-d','--extract-certificates='+str(prefix),path])
        leaf=Path(str(prefix)+'0');need(leaf.is_file() and hashlib.sha1(leaf.read_bytes()).hexdigest().upper()==IDENTITY,'Signing leaf certificate is not the approved exact identity')
        proof[str(path.relative_to(app)) if path!=app else '.']=m
    for path in machines:run([CS,'--verify','--strict','--all-architectures',path])
    run([CS,'--verify','--deep','--strict',app])  # --deep is verification ONLY
    return proof,machines

def xattr_hashes(path):
    # Darwin CPython does not expose os.listxattr/getxattr. Use the public native
    # calls, retaining link semantics and compression attributes; errors stop.
    lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    listing,getting=lib.listxattr,lib.getxattr
    listing.argtypes=[ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int]
    getting.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_int]
    listing.restype=getting.restype=ctypes.c_ssize_t
    def call(fn,*args):
        ctypes.set_errno(0);n=fn(*args)
        if n<0:
            error=ctypes.get_errno();raise OSError(error,os.strerror(error),str(path))
        return n
    raw=os.fsencode(path);options=0x21  # XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION
    size=call(listing,raw,None,0,options)
    if not size:return {}
    names=ctypes.create_string_buffer(size)
    need(call(listing,raw,names,size,options)==size and names.raw.endswith(b'\0'),'Attribute list changed or malformed')
    result={}
    for name in sorted(names.raw[:-1].split(b'\0')):
        length=call(getting,raw,name,None,0,0,options)
        value=ctypes.create_string_buffer(max(1,length))
        need(name and os.fsdecode(name) not in result and call(getting,raw,name,value,length,0,options)==length,'Attribute changed or duplicated')
        result[os.fsdecode(name)]=hashlib.sha256(value.raw[:length]).hexdigest()
    return result

def inventory(root):
    entries={}
    for p in [root]+sorted(root.rglob('*')):
        s=p.lstat();rel='.' if p==root else str(p.relative_to(root))
        kind='link' if p.is_symlink() else 'directory' if p.is_dir() else 'file'
        need(kind!='file' or stat.S_ISREG(s.st_mode),'Unexpected special file')
        attrs=xattr_hashes(p)
        acl=run(['/bin/ls','-lde',p]).stdout.decode().splitlines()[1:]
        e={'kind':kind,'mode':stat.S_IMODE(s.st_mode),'uid':s.st_uid,'gid':s.st_gid,'flags':s.st_flags,'nlink':s.st_nlink,'mtimeNS':s.st_mtime_ns,'xattrs':attrs,'acl':acl}
        if kind=='file':e.update(bytes=s.st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
        elif kind=='link':
            e['target']=os.readlink(p);need(p.resolve()==root or root in p.resolve().parents,'Symlink escapes code bundle')
        entries[rel]=e
    return entries

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=['preflight','sign','verify']);parser.add_argument('--app',type=Path);parser.add_argument('--receipt',type=Path)
    parser.add_argument('--source-receipt',type=Path,help='Verify a final copy against its retained signing/ZIP-restore receipt; save all evidence via --receipt')
    parser.add_argument('--restore-check',action='store_true',help='Read-only verification plus actual ZIP restore; never re-sign existing code')
    args=parser.parse_args()
    need(args.source_receipt is None or (args.mode=='verify' and args.receipt is not None),'--source-receipt requires verify and a new --receipt')
    need(not args.restore_check or (args.mode=='verify' and args.receipt is not None and args.source_receipt is None),'--restore-check requires verify and a new standalone --receipt')
    if args.mode=='preflight':identity_available();print('Approved Development identity available in current user context');return
    need(args.app is not None,'--app required');app=private_app(args.app) if args.mode=='sign' else args.app.resolve()
    temp=Path(tempfile.mkdtemp(prefix='gaowenjian-signing.',suffix='.noindex',dir='/private/tmp'))
    try:
        original={}
        if args.mode=='sign':
            identity_available();objects,expected,_=code_objects(app)
            for index,path in enumerate(objects):
                old=metadata(path);rel='.' if path==app else str(path.relative_to(app));original[rel]=old
                ent=None
                if old['entitlements'] is not None:
                    ent=temp/('entitlements-'+str(index)+'.plist');ent.write_bytes(plistlib.dumps(old['entitlements']))
                command=signing_command(expected[path],old['semanticFlags'],ent)
                run(command+[path])
                new=metadata(path);need(new['entitlements']==old['entitlements'] and new['semanticFlags']==old['semanticFlags'],'Entitlements or semantic flags changed')
        signed,machines=verify_objects(app,temp)
        receipt={'schemaVersion':1,'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'identitySHA1':IDENTITY,'teamIdentifier':TEAM,'hostBundleID':BUNDLE,'signatureClass':'Apple Development, not Developer ID; not notarized','stableRequirementTemplate':'designated => '+requirement(BUNDLE),'oldPermissionsAutomaticallyTransferred':False,'originalCodeObjects':original,'signedCodeObjects':signed,'machO':{str(p.relative_to(app)):{'architectures':run(['/usr/bin/lipo','-archs',p]).stdout.decode().strip(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in machines},'preservedSemanticOptionsAndEntitlements':args.mode=='sign','noDeepSigning':True,'inventory':inventory(app),'inventoryDefinition':'All entries: content/symlink target, mode/uid/gid/flags/mtime, full xattr SHA and extended ACL lines. Physical inode/ctime/birthtime intentionally not claimed as portable restoration metadata.'}
        if args.mode=='sign' or args.restore_check:
            archive=temp/'candidate.zip';restore=temp/'Restore.noindex';restore.mkdir(mode=0o700)
            run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',app,archive]);run(['/usr/bin/ditto','-x','-k',archive,restore]);restored=restore/app.name
            raw_restored=inventory(restored)
            # ZIP timestamps can be coarser than the original APFS nanoseconds.
            # A complete receipt-assisted restore may restore that recorded time;
            # no content, identity-bearing link, permission, ACL or xattr mismatch
            # is hidden or rewritten to make an incomplete archive look exact.
            need(raw_restored.keys()==receipt['inventory'].keys(),'ZIP restore entry set differs')
            timestamp_fixups=[]
            for rel,expected in receipt['inventory'].items():
                actual=dict(raw_restored[rel]);comparison=dict(expected)
                actual.pop('mtimeNS');comparison.pop('mtimeNS')
                need(actual==comparison,'ZIP restore content or security metadata differs: '+rel)
                if raw_restored[rel]['mtimeNS']!=expected['mtimeNS']:
                    q=restored if rel=='.' else restored/rel
                    os.utime(q,ns=(q.lstat().st_atime_ns,expected['mtimeNS']),follow_symlinks=False)
                    timestamp_fixups.append(rel)
            need(inventory(restored)==receipt['inventory'],'Receipt-assisted ZIP restoration differs')
            restored_proof,_=verify_objects(restored,temp)
            need({k:v['fullRequirements'] for k,v in restored_proof.items()}=={k:v['fullRequirements'] for k,v in signed.items()},'Restored complete requirements differ')
            receipt['actualZIPRestore']={'pass':True,'archiveSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),'rawArchivePortableMetadataEqual':raw_restored==receipt['inventory'],'receiptAssistedTimestampFixups':timestamp_fixups,'allRecordedPortableMetadataEqualAfterExplicitReceiptRestore':True,'noSecurityAttributeOrContentMismatchRepaired':True,'allMachOAndCompleteDRVerified':True}
        if args.source_receipt:
            raw_source=args.source_receipt.read_bytes();source=json.loads(raw_source)
            receipt['copyVerification']=compare_copy_receipts(source,receipt)
            receipt['copyVerification'].update(verifiedAppPath=str(app),sourceSigningReceiptPath=str(args.source_receipt.resolve()),sourceSigningReceiptSHA256=hashlib.sha256(raw_source).hexdigest())
        if args.receipt:
            need(args.receipt.parent.is_dir() and not args.receipt.exists(),'Receipt destination must be new')
            with args.receipt.open('x') as f:json.dump(receipt,f,ensure_ascii=False,indent=2);f.write('\n')
            os.chmod(args.receipt,0o600)
        if args.source_receipt:
            need(receipt['copyVerification']['pass'],'Copied App differs from its signing receipt; evidence retained at '+str(args.receipt)+': '+', '.join(receipt['copyVerification']['differences']))
        print('PASS Development signature, exact certificate/Team, complete DR and all MachO'+('; actual ZIP restore verified' if args.mode=='sign' or args.restore_check else ''))
    finally:shutil.rmtree(temp)
if __name__=='__main__':main()
