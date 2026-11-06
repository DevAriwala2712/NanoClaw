import concurrent.futures, hashlib, json, subprocess
from pathlib import Path
root=Path('/home/ubuntu/NanoClaw')
models=json.loads((root/'state/grid-manifest.json').read_text())
def download(m):
 p=root/'models'/m['filename']
 if not p.exists():
  part=p.with_suffix('.gguf.part')
  print('Downloading '+m['filename'],flush=True)
  subprocess.run(['curl','-fLsS','--retry','3','--retry-delay','2','--connect-timeout','30','--max-time','1200','-C','-',m['url'],'-o',str(part)],check=True)
  assert part.stat().st_size==m['size_bytes'],m['filename']+' size mismatch'
  assert hashlib.file_digest(part.open('rb'),'sha256').hexdigest()==m['sha256'],m['filename']+' hash mismatch'
  part.rename(p)
 else:
  assert p.stat().st_size==m['size_bytes']
  assert hashlib.file_digest(p.open('rb'),'sha256').hexdigest()==m['sha256']
 print('SHA-256 verified '+m['filename'],flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 list(pool.map(download,models))
print('All six models verified',flush=True)
