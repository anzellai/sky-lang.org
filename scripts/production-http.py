#!/usr/bin/env python3
"""Public GET-only release smoke. Never invokes a business mutation endpoint."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urljoin,urlsplit
import argparse, hashlib, importlib.util, io, json, os, re, subprocess, sys, urllib.request, urllib.error, gzip
ROOT=Path(__file__).resolve().parent.parent
class Failure(Exception):pass
def need(v,label):
 if not v:raise Failure(label)
def sha_bytes(v):return hashlib.sha256(v).hexdigest()
def target(policy):
 base=policy['base'];need(base=='https://sky-lang.org','production-target');return base
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args):return None
class Assets(HTMLParser):
 def __init__(self):super().__init__();self.scripts=[];self.wasm=[]
 def handle_starttag(self,tag,attrs):
  values=dict(attrs)
  if tag=='script' and values.get('src'):self.scripts.append(values['src'])
  if values.get('data-wasm'):self.wasm.append(values['data-wasm'])
def source_check(policy):
 for rel,expected in policy['sourceAuthority'].items():
  need(sha_bytes((ROOT/rel).read_bytes())==expected,'readonly-source-authority-drift')
def main():
 p=argparse.ArgumentParser();p.add_argument('--expected-commit',required=True);p.add_argument('--archive',type=Path,required=True);p.add_argument('--facts',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 need(re.fullmatch('[0-9a-f]{40}',a.expected_commit),'expected-source-format')
 policy=json.loads((ROOT/'scripts/ci-site-policy.json').read_text());source_check(policy);base=target(policy)
 spec=importlib.util.spec_from_file_location('ci_artifacts',ROOT/'scripts/ci-artifacts.py');ci=importlib.util.module_from_spec(spec);spec.loader.exec_module(ci)
 head,source_sha=ci.source();facts=json.loads(a.facts.read_text());need(head==a.expected_commit==facts['sourceCommit'] and source_sha==facts['sourceSHA256'],'expected-source-artifact-mismatch')
 need(facts['app']=='sky-lang.org' and facts['format']=='website-hosted-build-v1' and re.search(r'(?<![0-9])0\.29\.4(?![0-9])',facts['compilerVersion']),'expected-official-toolchain')
 need(ci.sha(a.archive)==facts['archiveSHA256'] and ci.members(a.archive,'sky-lang.org')==facts['files'],'ci-artifact-drift')
 expected={k[len('frontend/dist/'):]:v['sha256'] for k,v in facts['files'].items() if k.startswith('frontend/dist/')}
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect());checks=[];asset_facts=[]
 def request(path,headers=None,limit=8*1024*1024):
  u=urlsplit(urljoin(base,path));need(u.scheme=='https' and u.netloc==urlsplit(base).netloc and not u.username and not u.password,'cross-origin-probe')
  req=urllib.request.Request(u.geturl(),headers={'User-Agent':'Sky-public-release-smoke','Accept-Encoding':'identity',**(headers or {})},method='GET')
  try:r=opener.open(req,timeout=25)
  except urllib.error.HTTPError as e:r=e
  with r:
   body=r.read(limit+1);need(len(body)<=limit,'response-bound');return r.code,r.headers,body
 def check(label,ok):
  checks.append({'name':label,'passed':bool(ok)})
 def buildinfo():
  code,_,body=request('/_sky/buildinfo');check('buildinfo-status',code==200);b=json.loads(body)
  observed=b.get('commit','');need(re.fullmatch('[0-9a-f]{7,40}',observed) is not None,'observed-source-format')
  check('observed-source',a.expected_commit.startswith(observed));check('observed-official-compiler',re.search(r'(?<![0-9])0\.29\.4(?![0-9])',b.get('skyVersion','')) is not None)
  need(checks[-1]['passed'] and checks[-2]['passed'],'deployed-identity-mismatch')
 buildinfo()
 for path in ['/healthz']:
  code,_,_=request(path);check('health-'+path.rsplit('/',1)[1],code==200)
 home=None
 for path in ['/','/blog','/robots.txt','/sitemap.xml']:
  code,headers,body=request(path);check('public-page',code==200);check('no-private-key-pattern',re.search(rb'(?:sk_live_|whsec_)[A-Za-z0-9]{12,}',body) is None)
  if path=='/':
   home=body;check('tls-security-headers',bool(headers.get('Strict-Transport-Security')) and headers.get('X-Content-Type-Options','').lower()=='nosniff')
   check('wasm-csp',"'wasm-unsafe-eval'" in headers.get('Content-Security-Policy',''))
   cookies=headers.get_all('Set-Cookie',[]);check('secure-production-cookies',bool(cookies) and all(any(x.strip().lower()=='secure' for x in c.split(';')[1:]) for c in cookies))
 for path in ['/_sky/console','/_sky/metrics']:
  code,_,_=request(path);check('protected-readonly-route',code in [401,403,404,302,303])
 # Run the unchanged, source-bound eleven denial assertions without logging
 # any returned production body. No cookie is sent by that script.
 r=subprocess.run(['bash',str(ROOT/'scripts/verify-admin-rpc-auth.sh'),base],capture_output=True,timeout=240)
 check('original-eleven-admin-refusals',r.returncode==0)
 parser=Assets();need(home is not None,'home-missing');parser.feed(home.decode())
 urls=list(dict.fromkeys(parser.scripts+parser.wasm));need(parser.wasm and any(urlsplit(x).path.endswith('wasm_exec.js') for x in parser.scripts),'framework-assets-not-discovered')
 for path in urls:
  name=urlsplit(path).path.lstrip('/')
  # Framework SDK/boot/Wasm must match the successful exact-source CI pair.
  required=name.endswith('.wasm') or name.endswith('wasm_exec.js') or name.startswith('spa-boot.')
  if not required:continue
  need(name in expected,'framework-asset-not-in-ci-pair')
  code,_,identity=request(path,limit=256*1024*1024);check('asset-identity',code==200 and sha_bytes(identity)==expected[name]);need(checks[-1]['passed'],'framework-asset-identity-mismatch')
  for encoding in ['gzip','br']:
   code,headers,encoded=request(path,{'Accept-Encoding':encoding},256*1024*1024);need(code==200 and headers.get('Content-Encoding','').lower()==encoding,'compression-not-negotiated')
   if encoding=='gzip':
    with gzip.GzipFile(fileobj=io.BytesIO(encoded)) as stream:decoded=stream.read(256*1024*1024+1)
    need(len(decoded)<=256*1024*1024,'gzip-output-bound')
   else:
    r=subprocess.run(['node','-e','const z=require("node:zlib");let b=[];process.stdin.on("data",x=>b.push(x));process.stdin.on("end",()=>process.stdout.write(z.brotliDecompressSync(Buffer.concat(b),{maxOutputLength:256*1024*1024})));'],input=encoded,capture_output=True,timeout=30)
    need(r.returncode==0,'brotli-decode');decoded=r.stdout
   check('asset-compression-equality',sha_bytes(decoded)==expected[name])
  asset_facts.append({'sha256':expected[name],'sdk':name.endswith('wasm_exec.js'),'wasm':name.endswith('.wasm')})
 buildinfo();passed=all(c['passed'] for c in checks);need(checks and asset_facts,'empty-smoke')
 result={'passed':passed,'expectedCommit':a.expected_commit,'compilerVersion':'0.29.3','checks':checks,'assetFacts':asset_facts,'businessMutationRequests':0,'formsSubmitted':0,'jobPaymentMailEndpointsInvoked':False}
 a.out.parent.mkdir(parents=True,exist_ok=True)
 fd=os.open(a.out,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:json.dump(result,f,indent=2);f.write('\n')
 print(json.dumps({'passed':passed,'checks':len(checks),'failedChecks':sum(not x['passed'] for x in checks),'frameworkAssets':len(asset_facts),'businessMutationRequests':0}))
 return 0 if passed else 1
if __name__=='__main__':
 try:sys.exit(main())
 except Exception:print(json.dumps({'passed':False,'stage':'readonly-http-smoke'}));sys.exit(1)
