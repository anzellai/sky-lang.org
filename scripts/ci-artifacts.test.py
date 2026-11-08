"""Pure public archive-contract fixtures; no compiler, app, DB or browser."""
from pathlib import Path
import importlib.util, io, tarfile, tempfile, unittest
spec=importlib.util.spec_from_file_location('ci_artifacts',Path(__file__).with_name('ci-artifacts.py'))
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class Contract(unittest.TestCase):
 def archive(self,root,extra=(),omit=()):
  p=root/'bundle.tar.gz'
  with tarfile.open(p,'w:gz') as tar:
   for name in ['backend/app','frontend/dist/app.wasm',*extra]:
    if name in omit:continue
    m=tarfile.TarInfo(name);m.size=4;m.mode=0o755 if name.endswith('/app') else 0o600;tar.addfile(m,io.BytesIO(b'data'))
  return p
 def test_pair_has_backend_and_wasm(self):
  with tempfile.TemporaryDirectory() as d:self.assertEqual(len(h.members(self.archive(Path(d)))),2)
 def test_missing_wasm_fails(self):
  with tempfile.TemporaryDirectory() as d:
   with self.assertRaises(RuntimeError):h.members(self.archive(Path(d),omit=('frontend/dist/app.wasm',)))
 def test_traversal_fails(self):
  with tempfile.TemporaryDirectory() as d:
   with self.assertRaises(RuntimeError):h.members(self.archive(Path(d),extra=('../escape',)))
 def test_duplicate_normalized_path_fails(self):
  with tempfile.TemporaryDirectory() as d:
   with self.assertRaises(RuntimeError):h.members(self.archive(Path(d),extra=('./backend/app',)))
 def test_dotenv_fails(self):
  with tempfile.TemporaryDirectory() as d:
   with self.assertRaises(RuntimeError):h.members(self.archive(Path(d),extra=('backend/.env',)))
 def test_unknown_namespace_fails(self):
  with tempfile.TemporaryDirectory() as d:
   with self.assertRaises(RuntimeError):h.members(self.archive(Path(d),extra=('unobserved/file',)))
 def test_link_fails(self):
  with tempfile.TemporaryDirectory() as d:
   p=self.archive(Path(d))
   # A fresh archive, not a mutation of the application or its artifacts.
   with tarfile.open(p,'w:gz') as tar:
    m=tarfile.TarInfo('backend/app');m.type=tarfile.SYMTYPE;m.linkname='/outside';tar.addfile(m)
   with self.assertRaises(RuntimeError):h.members(p)
if __name__=='__main__':unittest.main()
