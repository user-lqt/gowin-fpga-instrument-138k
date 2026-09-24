"""Plot actual recorded VCD signals (not an illustrative timing sketch)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parent
source = root / 'results/tb_input_top/waveform.vcd'
signals = ['system_ready', 'pressed', 'keys', 'ev', 'note', 'ab', 'sw', 'pv', 'pid', 'pvalue', 'page', 'vol', 'inst']
codes, traces, scope = {}, {}, []
now = 0
for line in source.read_text().splitlines():
    parts = line.split()
    if not parts:
        continue
    if parts[0] == '$scope':
        scope.append(parts[2])
    elif parts[0] == '$upscope':
        scope.pop()
    elif parts[0] == '$var' and scope == ['tb_input_top'] and parts[4] in signals:
        codes[parts[3]] = parts[4]
        traces[parts[4]] = []
    elif line.startswith('#'):
        now = int(line[1:]) / 1e6  # VCD timescale is 1ps -> us
    elif line[0] in 'bB':
        value, code = parts[0][1:], parts[1]
        if code in codes and not any(c in value.lower() for c in 'xz'):
            traces[codes[code]].append((now, int(value, 2)))
    elif line[0] in '01' and line[1:] in codes:
        traces[codes[line[1:]]].append((now, int(line[0])))

im = Image.new('RGB', (1800, 1500), 'white')
draw = ImageDraw.Draw(im)
font = ImageFont.truetype('C:/Windows/Fonts/consola.ttf', 19)
draw.text((180, 18), 'B0/B1/B2 input_top - actual XSim VCD (accelerated test timing)', fill='black', font=font)
for row, name in enumerate(signals):
    y0 = 70 + row * 102
    points = traces[name]
    draw.text((12, y0 + 25), name, fill='black', font=font)
    if points:
        points = points + [(now, points[-1][1])]
        low = min(v for t,v in points)
        high = max(v for t,v in points)
        scale = max(1, high-low)
        draw.text((180, y0), f'range {low}..{high}', fill='#555555', font=font)
        for k in range(11):
            x = 340 + k*140
            draw.line((x,y0+25,x,y0+85), fill='#dddddd')
        coords=[]
        old=None
        for t,v in points:
            x=340+1400*t/now
            y=y0+82-50*(v-low)/scale
            if old is not None:
                coords.append((x,old))
            coords.append((x,y))
            old=y
        if len(coords)>1:
            draw.line(coords, fill='#1166aa', width=2)
for k in range(11):
    draw.text((330+k*140,1420),f'{now*k/10:.1f}',fill='black',font=font)
draw.text((740,1460),'Simulation time (us)',fill='black',font=font)
im.save(root / 'results/input_top_waveform.png')
print('Saved actual VCD waveform plot')
