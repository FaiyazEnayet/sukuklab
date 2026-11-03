"""Presentation-only postprocessor. Reads fresh source HTML; never changes research calculations.

Usage: python portfolio_ui/renderer.py --repo NAME --root /path/to/repo --input docs/dashboard.html --output docs/dashboard.html
Requires beautifulsoup4. The Sukuk alternative uses only stdlib plus beautifulsoup4.
"""
import argparse,base64,calendar,copy,datetime,hashlib,html,json,math,re,sys
from pathlib import Path
from bs4 import BeautifulSoup
from configs import CONFIGS
from opening import opening
HERE=Path(__file__).parent
DEC=json.JSONDecoder()
def extract(raw,repo):
 soup=BeautifulSoup(raw,'html.parser');figs=[]
 for sc in soup.find_all('script'):
  t=sc.string or ''
  if len(t)>500000:continue
  for m in re.finditer(r'Plotly\.newPlot\(\s*',t):
   args=[];pos=m.end()
   try:
    for i in range(4):
     while t[pos] in ' \r\n\t,':pos+=1
     v,n=DEC.raw_decode(t[pos:]);args.append(v);pos+=n
   except (ValueError,IndexError):continue
   fm=re.search(r"Plotly\.addFrames\(\s*['\"]"+re.escape(args[0])+r"['\"],\s*",raw)
   figs.append(dict(id=args[0],data=args[1],layout=args[2],config=args[3],frames=DEC.raw_decode(raw[fm.end():])[0] if fm else []))
 d=dict(repo=repo,figures=figs,tables=[],recommendations=[])
 for tb in soup.find_all('table'):
  prev=tb.find_previous(['h2','h3']);headers=[x.get_text(' ',strip=True) for x in tb.select('thead th')]
  rows=[[x.get_text(' ',strip=True) for x in tr.find_all('td')] for tr in tb.select('tbody tr')]
  d['tables'].append(dict(title=prev.get_text(' ',strip=True) if prev else 'Results',headers=headers,rows=rows))
 for card in soup.select('.rec-card'):
  for attr in card.select('[style]'):del attr['style']
  d['recommendations'].append(str(card).replace('—',':'))
 return d,soup
def jsonfile(root,p):return json.loads((root/p).read_text(encoding='utf8'))
def enrich(d,soup,root):
 repo=d['repo'];c=CONFIGS[repo];d['design']=c;d['metrics']=[]
 if repo=='sukuklab':
  anchor=datetime.date(2026,1,15);dates=[datetime.date(2026+i//2,(7 if i%2==0 else 1),15) for i in range(10)]
  # Explicit semiannual dates, matching Dates.Month increments in Julia.
  dates=[datetime.date(2026+(6+i*6)//12,(6+i*6)%12+1,15) for i in range(10)]
  cfs=[dict(date=x.isoformat(),amount=25.3+(1000 if i==9 else 0),t=(x-anchor).days/365) for i,x in enumerate(dates)]
  raw=jsonfile(root,'data/iilm_2026-01.json');obs=[]
  def collect(v):
   if isinstance(v,dict):
    if 'months' in v and 'profit_rate' in v:obs.append(v)
    for x in v.values():collect(x)
   elif isinstance(v,list):
    for x in v:collect(x)
  collect(raw);ca=datetime.date(2026,1,13);pillars=[];zeros=[]
  for o in obs:
   mm=ca.month-1+o['months'];mat=datetime.date(ca.year+mm//12,mm%12+1,ca.day);t=(mat-ca).days/365;pillars.append(t);zeros.append(math.log1p(o['profit_rate']*t)/t)
  structures=[t for t in d['tables'] if t['title'].startswith(('Ijara','Murabaha','Wakala'))]
  d['sukuk']=dict(cashflows=cfs,pillars=pillars,zeros=zeros,structures=structures)
  d['metrics']=[['13 Jan 2026','curve observation anchor'],['4','IILM maturity pillars'],['5.06%','example profit rate'],['1,000','example face · currency units']]
 # Fingerprint the immutable Julia input, not the generated output itself.
 # Hashing dashboard.html here would change its own payload on every rebuild.
 source_files=[p for p in c['sources'] if p!='docs/dashboard.html']+['portfolio_ui/julia-source-snapshot.html']
 d['provenance']=dict(files={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in source_files if (root/p).is_file()},classification=c['classification'])
 return d
def page_parts(d):
 c=d['design'];cols=c['colors'];tokens=';'.join('--'+k+':'+v for k,v in zip(['bg','surface','text','muted','accent','line'],cols));tokens+=';--radius:3px;--display:"'+c['display']+'";--body:"'+c['body']+'";--mono:"'+c['mono']+'"'
 fonts=json.loads((HERE/'fonts.json').read_text(encoding='utf8'));font='\n'.join(fonts.get(f,'') for f in dict.fromkeys([c['display'],c['body'],c['mono']]));css=(HERE/'base.css').read_text(encoding='utf8');js=(HERE/'runtime.js').read_text(encoding='utf8')
 source='https://github.com/FaiyazEnayet/'+d['repo'];limits=''.join('<li>'+html.escape(x)+'</li>' for x in c['limits']);files=''.join('<li><code>'+html.escape(p)+'</code></li>' for p in c['sources'])
 refs={'sukuklab': [('Price & yield', 'valuation'), ('Curve', 'curve'), ('Cash flows', 'cashflows')]}
 nav=''.join(f'<a href="#{a}">{t}</a>' for t,a in refs[d['repo']])+'<a href="#sources">Sources & limits</a>'
 head=f'''<!doctype html><html lang="en" style='{tokens};color-scheme:{'light' if cols[0][1:3] in ['ee','f1','f2','f3','f4'] else 'dark'}'><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="{cols[0]}"><title>{html.escape(c['name'])} | {d['repo']}</title><style>{font}</style><style>{css}</style></head><body data-repo="{d['repo']}"><a class="skip" href="#content">Skip to dashboard</a><div class="shell"><header class="masthead"><div class="identity"><svg class="seal" viewBox="0 0 32 32" aria-hidden="true"><path d="M16 2 29 9v14l-13 7L3 23V9ZM16 8v16M8 12l16 8M24 12 8 20" fill="none" stroke="currentColor" stroke-width="1"/></svg><b>{html.escape(d['repo'])}</b> / RESEARCH PORTFOLIO</div><div class="edition">FAIYAZ ENAYET<br>LOCAL EDITION · 2026</div></header><div class="hero"><div><div class="eyebrow">{html.escape(c['brief'])}</div><h1>{html.escape(c['name'])}</h1><p class="question">{html.escape(c['question'])}</p></div><div class="brief"><b>Evidence, with its boundaries.</b>{html.escape(c['classification'])}<br><span class="badge">SELF-CONTAINED SNAPSHOT</span></div></div><nav class="nav" aria-label="Dashboard sections">{nav}</nav><main id="content"></main><div id="status" class="status" role="status" aria-live="polite">Preparing local charts…</div><section class="source" id="sources"><h2>Evidence & limitations</h2><p>{html.escape(c['classification'])}. This page preserves the repository’s recorded results; it does not fetch live data or rerun research models.</p><ul>{limits}</ul><details><summary>Inspect data lineage and assumptions</summary><p>Source: <a href="{source}">FaiyazEnayet/{d['repo']}</a>. Recorded chart arrays are extracted from the committed dashboard. Additional views use the explicit source calculations documented in DESIGN-AND-VALIDATION.md. Research code and evaluation methods are preserved.</p><ul>{files}</ul><p>Source-file SHA-256 checksums are embedded in this file’s evidence payload. The accompanying validation report distinguishes automated checks from visual review.</p></details></section><footer class="footer"><span>{html.escape(c['name'])} · Faiyaz Enayet</span><span>Designed for inspection. Built from source evidence.</span></footer></div>'''
 head=re.sub(r'<header class="masthead">.*?<main id="content"></main>',opening(d,nav)+'<main id="content"></main>',head,flags=re.S)
 return head,js
def render_html(root,repo,raw):
 d,soup=extract(raw,repo);d=enrich(d,soup,Path(root));head,js=page_parts(d)
 # Full source Plotly distribution: original reduced bundles silently downgrade unsupported traces.
 lib=(HERE/'plotly.min.js').read_text(encoding='utf8')
 katex=''
 payload=json.dumps(d,ensure_ascii=False,separators=(',',':')).replace('</','<\\/')
 result=head+katex+'<script>'+lib+'</script><script>const EVIDENCE='+payload+';\n'+js+'</script></body></html>'
 return result,d
def render(root,repo,input_path,output_path):
 result,d=render_html(root,repo,Path(input_path).read_text(encoding='utf8'))
 Path(output_path).parent.mkdir(parents=True,exist_ok=True);Path(output_path).write_text(result,encoding='utf8');return d
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--repo',required=True);ap.add_argument('--root',required=True);ap.add_argument('--input',required=True);ap.add_argument('--output',required=True);a=ap.parse_args();render(a.root,a.repo,a.input,a.output)
if __name__=='__main__':main()
