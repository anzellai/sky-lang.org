import hashlib,json,pathlib,re,sys,unittest
P=pathlib.Path(__file__).resolve().parent.parent
# Exact rt.strictCSPBase from published Sky0.29.3; source SHA256 ed1809e851ddfd12bb480845c30cdec670a91df6db28537885e605f9b88aa94c
CSP="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'"
BLOCK='\n    # Same-origin Sky.Spa SDK + Std.Ui policy, matching rt.strictCSPBase.\n    # HSTS is scoped to this host; deliberately no subdomain/preload promise.\n    header {\n        Strict-Transport-Security "max-age=31536000"\n        Content-Security-Policy "default-src \'self\'; script-src \'self\' \'wasm-unsafe-eval\'; style-src \'self\' \'unsafe-inline\'; img-src \'self\' data: blob:; font-src \'self\' data:; connect-src \'self\'; object-src \'none\'; base-uri \'self\'; form-action \'self\'"\n    }\n'
NEW=(P/'deploy/Caddyfile.spa').read_text()
OLD=pathlib.Path(sys.argv[sys.argv.index('--baseline-file')+1]).read_text()if '--baseline-file'in sys.argv else NEW.replace(BLOCK,'',1)
BASE_SHA256='a1c79cf0fbf0c2dd7fd486d2f8ba529ffa5033d89aba5300ff50be389398f053'
def contract(text):
 found={}
 for m in re.finditer(r'(?m)^\s*(Strict-Transport-Security|Content-Security-Policy)\s+("(?:[^"\\]|\\.)*")\s*$',text):
  key=m.group(1);assert key not in found;assert m.start()>text.index(':443 {');found[key]=json.loads(m.group(2))
 assert found=={'Strict-Transport-Security':'max-age=31536000','Content-Security-Policy':CSP}
 assert 'includeSubDomains'not in found['Strict-Transport-Security']and 'preload'not in found['Strict-Transport-Security']
class Policy(unittest.TestCase):
 def test_required_headers(self):contract(OLD if '--baseline' in sys.argv else NEW)
 def test_routing_tls_ports_other_headers_preserved(self):self.assertEqual(hashlib.sha256(NEW.replace(BLOCK,'',1).encode()).hexdigest(),BASE_SHA256)
 def test_wasm_permission_not_omitted(self):
  with self.assertRaises(AssertionError):contract(NEW.replace(" 'wasm-unsafe-eval'",''))
 def test_hsts_subdomain_promise_refused(self):
  with self.assertRaises(AssertionError):contract(NEW.replace('max-age=31536000','max-age=31536000; includeSubDomains'))
 def test_wrong_hsts_age_refused(self):
  with self.assertRaises(AssertionError):contract(NEW.replace('max-age=31536000','max-age=0'))
 def test_duplicate_header_refused(self):
  with self.assertRaises(AssertionError):contract(NEW+BLOCK)
if __name__=='__main__':
 suite=unittest.TestSuite([Policy('test_required_headers')])if '--baseline'in sys.argv else unittest.defaultTestLoader.loadTestsFromTestCase(Policy)
 r=unittest.TextTestRunner(verbosity=2).run(suite);print(json.dumps({'passed':r.wasSuccessful(),'checks':r.testsRun,'network':False,'configReloaded':False}));raise SystemExit(0 if r.wasSuccessful()else 1)
