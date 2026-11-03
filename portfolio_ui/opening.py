"""Repository-specific opening compositions. Shared rendering does not prescribe shared UX."""
from html import escape as e
def opening(d,nav):
 c=d['design'];n=e(c['name']);q=e(c['question']);r=d['repo'];cla=e(c['classification'])
 def navigation(cls=''):return f'<nav class="nav {cls}" aria-label="Dashboard sections">{nav}</nav>'
 if r=='sukuklab':return f'''<header class="atlas-heading"><div class="atlas-register">TREASURY RESEARCH PAPERS <span>JANUARY 2026 / IILM</span></div><div class="atlas-title"><span class="atlas-monogram" aria-hidden="true">§</span><div><h1>{n}</h1><p>{q}</p></div><div class="atlas-date">OBSERVATION<br><strong>13</strong>JAN 2026</div></div></header>{navigation('ledger-index')}'''
 return ''
