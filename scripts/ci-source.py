#!/usr/bin/env python3
"""Exclude dotenv paths before opening them, including sparse tracked examples."""
from pathlib import Path
import subprocess,json
files=subprocess.check_output(['git','ls-files','-z']).decode().split('\0')[:-1]
excluded=[n for n in files if any(x=='.env'or x.startswith('.env.')or x=='env.local'for x in Path(n).parts)]
for n in excluded:
 subprocess.run(['git','update-index','--skip-worktree','--',n],check=True)
 p=Path(n)
 if p.exists()or p.is_symlink():p.unlink()
print(json.dumps({'excludedDotenvPaths':len(excluded),'contentsOpened':False}))
