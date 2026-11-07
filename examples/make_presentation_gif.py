from pathlib import Path
import base64
import io
import json
import re
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTFont
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

base=Path(__file__).resolve().parents[1]
def font(repo,family,size):
    fonts=json.loads((base/repo/'portfolio_ui/fonts.json').read_text(encoding='utf-8'))
    path=base/(family.replace(' ','')+'.ttf')
    if not path.exists():
        raw=base64.b64decode(re.findall(r'base64,([^\)]+)',fonts[family])[-1])
        f=TTFont(io.BytesIO(raw));f.flavor=None;f.save(path)
    return ImageFont.truetype(str(path),size)

def sukuk():
    root=base;results=json.loads((root/'examples/results.json').read_text())
    fonts=json.loads((root/'portfolio_ui/fonts.json').read_text(encoding='utf8'))
    title=font('','Fraunces',43);small=font('','IBM Plex Mono',17);medium=font('','IBM Plex Mono',24)
    yields=results['uae_price_sweep_yield_pct'];prices=results['uae_price_sweep_prices']
    frames=[]
    for index in range(0,len(yields),2):
        im=Image.new('RGB',(1200,740),'#f7f3e9');d=ImageDraw.Draw(im)
        d.rectangle((0,0,1200,137),fill='#0c2843')
        d.text((38,22),'SukukLab',font=title,fill='#f7f3e9')
        d.text((40,86),'DATED CASH FLOWS / UAE RETAIL T-SUKUK',font=small,fill='#d4b779')
        fig,ax=plt.subplots(figsize=(7.4,4.2),dpi=100)
        fig.patch.set_facecolor('#f7f3e9');ax.set_facecolor('#f7f3e9')
        ax.plot(yields,prices,color='#8d6528',linewidth=2.5)
        ax.scatter([yields[index]],[prices[index]],s=85,color='#185166',zorder=3)
        ax.spines[['top','right']].set_visible(False);ax.grid(alpha=.2)
        ax.set_xlabel('Nominal semiannual yield (%)',fontsize=13,color='#122a42')
        ax.set_ylabel('Full price / 1,000 face',fontsize=13,color='#122a42')
        ax.tick_params(labelsize=12,colors='#122a42');fig.tight_layout()
        buf=io.BytesIO();fig.savefig(buf,format='png',facecolor=fig.get_facecolor());plt.close(fig);buf.seek(0)
        im.paste(Image.open(buf).convert('RGB'),(15,200))
        d.text((42,164),'Yield changes. Contract dates stay fixed.',font=medium,fill='#122a42')
        d.line((790,168,790,649),fill='#d6d0c1',width=2)
        d.text((830,175),'SCENARIO YIELD',font=small,fill='#536577')
        d.text((830,209),f'{yields[index]:.1f}%',font=title,fill='#122a42')
        d.text((830,280),'FULL PRICE',font=small,fill='#536577')
        d.text((830,314),f'{prices[index]:,.2f}',font=title,fill='#122a42')
        accrued=results['uae_accrued']
        d.text((830,392),'ACCRUED PROFIT',font=small,fill='#536577')
        d.text((830,427),f'{accrued:.2f}',font=medium,fill='#122a42')
        d.text((830,492),'CLEAN PRICE',font=small,fill='#536577')
        d.text((830,527),f'{prices[index]-accrued:,.2f}',font=title,fill='#865719')
        d.line((40,665,1160,665),fill='#d6d0c1',width=2)
        d.text((42,687),'Settlement '+results['uae_settlement']+' · 5.06% annual profit · 2031-09-30 maturity',font=small,fill='#536577')
        frames.append(im.quantize(colors=160))
    durations=[130]*len(frames);durations[0]=900;durations[-1]=1400
    frames[0].save(root/'docs/demo.gif',save_all=True,append_images=frames[1:],duration=durations,loop=0,optimize=True)
    print('Sukuk GIF',len(frames),'frames from canonical Julia price sweep')


if __name__=='__main__':
    sukuk()
