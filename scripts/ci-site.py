#!/usr/bin/env python3
"""Run only the CI archive against the job-owned database. Never deploy."""
from pathlib import Path
import argparse,json,os,signal,subprocess,time,urllib.request
p=argparse.ArgumentParser();p.add_argument('--archive',required=True);p.add_argument('--facts',required=True);p.add_argument('--commit',required=True);a=p.parse_args()
root=Path.cwd();unpacked=root/'ci-browser-unpacked';backend=unpacked/'backend/app';assert backend.is_file()
logs=root/'ci-results';logs.mkdir(exist_ok=True);out=(logs/'backend.log').open('xb');proc=None
try:
 subprocess.run(['python3','-I','-B','scripts/ci-artifacts.py','verify','--app','sky-lang.org','--archive',a.archive,'--facts',a.facts,'--source-commit',a.commit],check=True)
 proc=subprocess.Popen([str(backend)],cwd=unpacked/'backend',stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}));base='http://127.0.0.1:38940';deadline=time.monotonic()+90
 while True:
  try:
   with opener.open(base+'/healthz',timeout=2)as r:assert r.status==200
   break
  except Exception:
   if proc.poll()is not None or time.monotonic()>deadline:raise RuntimeError('ScratchBackendNotReady')
   time.sleep(.1)
 for path in ['/','/blog','/robots.txt','/sitemap.xml']:
  with opener.open(base+path,timeout=15)as r:body=r.read().decode();assert r.status==200
  if path in ['/','/blog']:assert 'sky-model'in body and'<title>'in body
  if path=='/':assert'Less repeated SPA work'in body and'Scroll after a step renders'in body
  if path=='/robots.txt':assert'Sitemap:'in body
  if path=='/sitemap.xml':assert'<urlset'in body
 subprocess.run(['bash',str(root/'scripts/verify-admin-rpc-auth.sh'),base],check=True,timeout=240,stdout=(logs/'admin-refusals.log').open('xb'),stderr=subprocess.STDOUT)
 subprocess.run(['node','scripts/site-browser.cjs','--base',base,'--facts',a.facts,'--out',str(logs/'browsers.json')],check=True,timeout=600)
 subprocess.run(['python3','-I','-B','scripts/ci-artifacts.py','verify','--app','sky-lang.org','--archive',a.archive,'--facts',a.facts,'--source-commit',a.commit],check=True)
 print(json.dumps({'passed':True,'scratchHTTP':4,'originalAdminRefusals':11,'browserEngines':2,'productionTouched':False}))
finally:
 if proc is not None and proc.poll()is None:
  proc.terminate()
  try:proc.wait(timeout=15)
  except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
 out.close()
