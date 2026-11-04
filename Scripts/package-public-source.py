#!/usr/bin/python3
"""Package the reviewed, committed public tree only. No network or app build.

Without --output this prints a plan. Packaging requires a clean worktree and
rejects private, ignored runtime and generated-program paths even if tracked.
"""
import argparse,hashlib,json,re,subprocess,sys,zipfile
from pathlib import Path
sys.dont_write_bytecode=True
PROJECT=Path(__file__).resolve().parent.parent
DIRECTORIES={'Sources','Resources','Assets','Scripts','Tests','Tools','Docs'}
FILES={'.gitignore','AGENTS.md','BUILD','README.md','VERSION','使用说明.txt','LICENSE','LICENSE.txt'}
PRIVATE_COMPONENTS={'.git','安全备份','Safety','Reports','Backups','keys','Release','build','.build','TestResults','dist','tmp','__pycache__','StickyNotes','History','.DS_Store','workspace.json','recovery.json'}
PRIVATE_COMPONENT_NAMES={item.casefold() for item in PRIVATE_COMPONENTS}
PRIVATE_SUFFIXES={'.p12','.p8','.key','.mobileprovision','.sqlite','.sqlite3','.db','.pyc','.dmg'}
DATABASE_SIDECAR=re.compile(r'\.(?:sqlite3?|db)-(?:wal|shm|journal)$',re.IGNORECASE)

def need(value,message):
    if not value:raise RuntimeError(message)
def git(*args):return subprocess.check_output(['git','-C',str(PROJECT),*args])
def public_path(name):
    path=Path(name)
    return (not path.is_absolute() and '..' not in path.parts and bool(path.parts)
            and (path.parts[0] in DIRECTORIES or name in FILES)
            and (name in FILES or not any(part.casefold() in PRIVATE_COMPONENT_NAMES
                        or part.casefold().startswith('.env') or part.casefold().endswith(('.app','.app.zip','.noindex','.dsym'))
                        or DATABASE_SIDECAR.search(part) for part in path.parts))
            and path.suffix.lower() not in PRIVATE_SUFFIXES)
def tree():
    result=[]
    for record in git('ls-tree','-r','-z','--full-tree','HEAD').split(b'\0'):
        if not record:continue
        header,path=record.split(b'\t',1);mode,kind,object_id=header.decode().split();name=path.decode('utf-8')
        need(kind=='blob' and mode in ('100644','100755') and public_path(name),'Non-public/linked/generated tracked path rejected: '+name)
        result.append((mode,object_id,name))
    return result
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output');a=parser.parse_args()
    commit=git('rev-parse','HEAD').decode().strip();files=tree();dirty=git('status','--porcelain','-z','--untracked-files=all')
    version=git('show','HEAD:VERSION').decode().strip();build=git('show','HEAD:BUILD').decode().strip()
    need(re.fullmatch(r'[0-9]+\.[0-9]{2}',version) is not None and build.isdigit(),'Committed public version/build format invalid')
    if not a.output:
        print(json.dumps({'mode':'plan-only','commit':commit,'committedVersion':version,'committedBuild':build,'publicFileCount':len(files),'worktreeNeedsReviewAndCommit':bool(dirty),'noFilesWritten':True},ensure_ascii=False,indent=2));return
    need(not dirty,'Review/commit the public changes first; do not package an old HEAD or unreviewed working tree')
    output=Path(a.output).expanduser().absolute()
    need(output.parent==PROJECT/'Release' and output.name=='GaoWenJian-'+version+'-source.zip','Use the exact current public Release source ZIP path')
    need(not output.exists(),'Source ZIP output exists; preserve/review it before replacement')
    output.parent.mkdir(exist_ok=True)
    need(output.parent.resolve()==output.parent and output.parent.is_dir(),'Release output parent must be a real local directory')
    prefix='GaoWenJian-'+version+'-source/'
    with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED) as archive:
        for mode,object_id,name in files:
            data=git('cat-file','blob',object_id);entry=zipfile.ZipInfo(prefix+name,(1980,1,1,0,0,0));entry.compress_type=zipfile.ZIP_DEFLATED
            entry.external_attr=(int(mode,8)&0o777)<<16;archive.writestr(entry,data)
    with zipfile.ZipFile(output) as archive:
        need(archive.testzip() is None and archive.namelist()==[prefix+item[2] for item in files],'Public source ZIP verification failed; preserve output')
    print(json.dumps({'sourceZIP':str(output),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'commit':commit,'version':version,'build':build,'publicFileCount':len(files),'onlyCommittedPublicBlobs':True},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
