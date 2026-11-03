"""Package the two rendered tutorials for offline playback."""
from pathlib import Path
import hashlib
import html
import sys
import zipfile

root = Path(sys.argv[1]).resolve()
titles = {"lda-app-walkthrough": "Use the LDA app", "lda-codex-walkthrough": "Connect LDA through MCP"}
page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LDA 2.0 walkthroughs</title><style>body{margin:40px auto;padding:0 24px;max-width:1080px;background:#f2f6fb;color:#202b40;font:18px/1.6 system-ui}h1{line-height:1.2}section{margin:48px 0}video{width:100%;border-radius:12px;background:#fff}a{color:#40529f}summary{cursor:pointer;padding:14px 0}pre{white-space:pre-wrap;font:inherit}</style><h1>LDA 2.0 walkthroughs</h1><p>Silent videos with English captions. Fictional documents. Recorded LDA windows and clearly labeled explanatory examples. Everything on this page works offline.</p>'''
assets=[]
for stem,title in titles.items():
    for ext in ('mp4','png','vtt','md'):
        path=root/f'{stem}.{ext}'
        if not path.is_file(): raise SystemExit(f'Missing {path.name}')
        assets.append(path)
    transcript=html.escape((root/f'{stem}.md').read_text())
    page+=f'<section><h2>{title}</h2><video controls preload="metadata" poster="{stem}.png"><source src="{stem}.mp4" type="video/mp4"><track kind="captions" srclang="en" label="English" src="{stem}.vtt"></video><p><a href="{stem}.mp4">Download video</a> · <a href="{stem}.vtt">Captions</a></p><details><summary>Read the transcript</summary><pre>{transcript}</pre></details></section>'
page+='<p>Review your redacted document before sharing it. Keep originals, mappings and passwords local.</p></html>'
(root/'setup.html').write_text(page)
assets.append(root/'setup.html')
zip_path=root/'LDA-Tutorials.zip'
with zipfile.ZipFile(zip_path,'w',zipfile.ZIP_DEFLATED) as z:
    for path in assets: z.write(path,path.name)
checks=assets+[zip_path]
(root/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in checks))
print(f'Created {zip_path.name} with {len(assets)} files')
