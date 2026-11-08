#!/usr/bin/env python3
"""Bind a private CI browser bundle to exact source and released compiler bytes."""
from pathlib import Path, PurePosixPath
import argparse, hashlib, json, os, re, shutil, subprocess, tarfile

def need(ok, label):
    if not ok: raise RuntimeError(label)
def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()
def forbidden(name):return any(p=='.env' or p.startswith('.env.') or p=='env.local' for p in PurePosixPath(name).parts)
def source():
    head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    names=subprocess.check_output(['git','ls-files','-z']).decode().split('\0')[:-1]
    facts={}
    for name in names:
        
        if forbidden(name):continue
        p=Path(name);need(p.is_file() and not p.is_symlink(),'source-file-required')
        facts[name]=sha(p)
    return head,hashlib.sha256(json.dumps(facts,sort_keys=True).encode()).hexdigest()
def compiler():
    p=Path('/usr/local/bin/sky');need(p.is_file(),'released-compiler-missing')
    version=subprocess.check_output([str(p),'--version'],text=True).strip()
    need(len(version)<256 and re.search(r'(?<![0-9])0\.29\.4(?![0-9])',version),'wrong-released-compiler')
    return sha(p),version

def members(archive, app='sky-lang.org'):
    facts={};total=0;count=0
    with tarfile.open(archive,'r:gz') as tar:
        for m in tar:
            count+=1;need(count<=10000,'archive-member-bound')
            rel=PurePosixPath(m.name)
            need(not rel.is_absolute() and '..' not in rel.parts and not forbidden(m.name),'unsafe-archive-path')
            if str(rel)=='.':need(m.isdir(),'archive-root-type');continue
            name=str(rel)
            allowed=rel.parts[0] in ('backend','frontend','content','static-fallback')
            need(allowed,'unknown-archive-namespace')
            need(m.isfile() or m.isdir(),'archive-link-or-special')
            if m.isdir():continue
            name=str(rel);need(name not in facts and m.size>=0,'duplicate-archive-member')
            total+=m.size;need(total<=2*1024**3 and len(facts)<10000,'archive-bound')
            f=tar.extractfile(m);need(f is not None,'archive-member-unreadable');h=hashlib.sha256()
            with f:
                for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
            facts[name]={'sha256':h.hexdigest(),'mode':m.mode & 0o777,'size':m.size}
    need(facts,'empty-archive');need(any(n.startswith('frontend/dist/') and n.endswith('.wasm') for n in facts),'wasm-missing')
    need('backend/app' in facts or 'backend/sky-out/app' in facts,'backend-missing')
    return facts

def extract(archive,destination):
    need(not destination.exists(),'exclusive-unpack-required');destination.mkdir(parents=True,mode=0o700)
    with tarfile.open(archive,'r:gz') as tar:
        for m in tar:
            rel=PurePosixPath(m.name)
            if str(rel)=='.':continue
            dest=destination/str(rel)
            if m.isdir():dest.mkdir(parents=True,exist_ok=True,mode=0o700);continue
            dest.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
            with tar.extractfile(m) as src, dest.open('xb') as dst:shutil.copyfileobj(src,dst,1024*1024)
            dest.chmod(m.mode & 0o777)

def staged(facts,app):
    root=Path('.skyapp/web-app/.split')
    for name,f in facts.items():
        if not name.startswith(('backend/','frontend/')):
            p=Path(name);need(p.is_file()and not p.is_symlink()and sha(p)==f['sha256'],'source-asset-drift');continue
        rel='backend/sky-out/app' if name=='backend/app' else name
        p=root/rel
        need(p.is_file() and not p.is_symlink() and sha(p)==f['sha256'],'staged-artifact-drift')

def main():
    p=argparse.ArgumentParser();p.add_argument('mode',choices=['write','unpack','verify']);p.add_argument('--app',choices=['sky-lang.org'],required=True);p.add_argument('--archive',type=Path,required=True);p.add_argument('--facts',type=Path,required=True);p.add_argument('--source-commit',required=True);a=p.parse_args()
    head,source_sha=source();need(head==a.source_commit,'source-commit-mismatch');sky_sha,version=compiler();items=members(a.archive,a.app)
    if a.mode=='write':
        staged(items,a.app)
        value={'format':'website-hosted-build-v1','app':a.app,'sourceCommit':head,'sourceSHA256':source_sha,'compilerSHA256':sky_sha,'compilerVersion':version,'archiveSHA256':sha(a.archive),'files':items}
        with a.facts.open('x') as f:json.dump(value,f,indent=2);f.write('\n')
    else:
        value=json.loads(a.facts.read_text())
        need(value['format']=='website-hosted-build-v1' and value['app']==a.app,'artifact-domain')
        need(value['sourceCommit']==head and value['sourceSHA256']==source_sha and value['compilerSHA256']==sky_sha,'artifact-producer-inputs')
        need(value['archiveSHA256']==sha(a.archive) and value['files']==items,'artifact-archive-drift')
        if a.mode=='unpack':
            dest=Path('ci-browser-unpacked');extract(a.archive,dest)
            split=Path('.skyapp/web-app/.split');need(not split.exists(),'stale-split-directory')
            split.mkdir(parents=True)
            for name in ('backend','frontend'):shutil.copytree(dest/name,split/name)
            if a.app=='sky-lang.org':
                (split/'backend/sky-out').mkdir(exist_ok=True);shutil.copy2(split/'backend/app',split/'backend/sky-out/app')
        staged(items,a.app)
    print(json.dumps({'passed':True,'mode':a.mode,'app':a.app,'boundArtifactFiles':len(items),'wasmFiles':sum(n.endswith('.wasm') for n in items),'sourceSHA256':source_sha,'compilerSHA256':sky_sha}))
if __name__=='__main__':
    try:main()
    except Exception:raise SystemExit('CI artifact contract failed')
