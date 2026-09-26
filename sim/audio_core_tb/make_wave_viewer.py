"""Generate the in-conversation A2 waveform viewer from the latest sample trace."""

import csv
import json
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
SOURCE = HERE / "build/iverilog/waveforms/a2_samples.csv"
if len(sys.argv) != 2:
    raise SystemExit("usage: python make_wave_viewer.py <visualization-folder>")
TARGET = Path(sys.argv[1]) / "a2-waveforms.html"
COLUMNS = (
    "scenario", "audio", "count", "clip", "env0", "env1", "env2", "env3",
    "stage0", "stage1", "stage2", "stage3", "event_count", "param_count",
)
with SOURCE.open(newline="", encoding="utf-8") as stream:
    rows = [
        [int(row[name]) for name in COLUMNS]
        for row in csv.DictReader(stream)
    ]

payload = json.dumps(rows, separators=(",", ":"))
html = r"""
<div id="a2-wave-viewer">
  <style>
    #a2-wave-viewer { color: var(--foreground); width: 100%; }
    #a2-wave-viewer .controls { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 8px; }
    #a2-wave-viewer label { display: inline-flex; align-items: center; gap: 5px; white-space: nowrap; }
    #a2-wave-viewer select { color: var(--foreground); background: var(--background); border: 1px solid var(--border); padding: 5px; max-width: 100%; }
    #a2-wave-viewer button { color: var(--foreground); background: var(--secondary); border: 1px solid var(--border); padding: 5px 10px; cursor: pointer; }
    #a2-wave-viewer canvas { display: block; width: 100%; height: 400px; touch-action: none; cursor: crosshair; }
    #a2-wave-viewer .readout { min-height: 24px; color: var(--muted-foreground); font-family: ui-monospace, monospace; overflow-wrap: anywhere; }
    #a2-wave-viewer .legend { display: flex; gap: 12px; flex-wrap: wrap; margin: 6px 0; color: var(--muted-foreground); }
    #a2-wave-viewer .swatch { display: inline-block; width: 10px; height: 3px; vertical-align: middle; }
  </style>
  <div class="controls">
    <select id="a2-scenario" aria-label="仿真场景">
      <option value="2">四音和弦</option><option value="3">满声部与重触发</option>
      <option value="4">音量变化</option><option value="5">独立 Release</option>
      <option value="6">全部松键</option><option value="7">低电平 Release</option>
      <option value="8">最大力度</option><option value="9">饱和测试</option>
      <option value="10">参数溢出</option><option value="11">FIFO 碰撞</option>
      <option value="12">事件溢出静音</option>
    </select>
    <label><input type="checkbox" id="a2-audio" checked>音频</label>
    <label><input type="checkbox" id="a2-env" checked>ADSR</label>
    <label><input type="checkbox" id="a2-status" checked>状态</label>
    <button type="button" id="a2-fit">适应范围</button>
  </div>
  <canvas id="a2-canvas" aria-label="A2 仿真波形"></canvas>
  <div class="legend" id="a2-legend"></div>
  <div class="readout" id="a2-readout" aria-live="polite"></div>
  <script>
    (() => {
      const root = document.getElementById("a2-wave-viewer");
      const rows = __DATA__;
      const canvas = root.querySelector("#a2-canvas");
      const ctx = canvas.getContext("2d");
      const selector = root.querySelector("#a2-scenario");
      const readout = root.querySelector("#a2-readout");
      const legend = root.querySelector("#a2-legend");
      const toggles = [root.querySelector("#a2-audio"), root.querySelector("#a2-env"), root.querySelector("#a2-status")];
      let shown = [], left = 0, right = 1, cursor = -1, drag = null;
      const margin = 48;

      function theme() {
        const css = getComputedStyle(root);
        return {
          fg: css.getPropertyValue("--foreground").trim() || "#222",
          muted: css.getPropertyValue("--muted-foreground").trim() || "#666",
          border: css.getPropertyValue("--border").trim() || "#aaa",
          colors: [1, 2, 3, 4].map(i => css.getPropertyValue("--viz-series-" + i).trim() || ["#007c85","#d15e43","#8b71ae","#ad943a"][i-1])
        };
      }
      function fit() {
        shown = rows.filter(r => r[0] === Number(selector.value));
        left = 0; right = shown.length - 1; cursor = -1;
        draw();
      }
      function xAt(i, width) { return margin + (i - left) * (width - margin - 12) / Math.max(1, right - left); }
      function indexAt(x, width) {
        return Math.max(0, Math.min(shown.length - 1,
          Math.round(left + (x - margin) * (right - left) / (width - margin - 12))));
      }
      function line(values, top, bottom, min, max, color, width) {
        const begin = Math.max(0, Math.floor(left)), end = Math.min(shown.length - 1, Math.ceil(right));
        const stride = Math.max(1, Math.floor((end - begin) / (width * 2)));
        ctx.strokeStyle = color; ctx.lineWidth = 1.25; ctx.beginPath();
        for (let i = begin; i <= end; i += stride) {
          const y = bottom - (values(shown[i]) - min) * (bottom - top) / (max - min);
          if (i === begin) ctx.moveTo(xAt(i, width), y);
          else ctx.lineTo(xAt(i, width), y);
        }
        ctx.stroke();
      }
      function draw() {
        const width = canvas.clientWidth, height = canvas.clientHeight;
        if (!width || !shown.length) return;
        const dpi = window.devicePixelRatio || 1;
        if (canvas.width !== Math.round(width*dpi) || canvas.height !== Math.round(height*dpi)) {
          canvas.width = Math.round(width*dpi); canvas.height = Math.round(height*dpi);
        }
        ctx.setTransform(dpi,0,0,dpi,0,0); ctx.clearRect(0,0,width,height);
        const t = theme();
        const active = toggles.map(x => x.checked);
        const labels = [];
        let y = 14;
        const lanes = active.filter(Boolean).length || 1;
        const space = (height - 42) / lanes;
        function lane(name, fn) {
          const top = y + 15, bottom = y + space - 16;
          ctx.strokeStyle = t.border; ctx.lineWidth = 1;
          ctx.beginPath(); ctx.moveTo(margin, bottom); ctx.lineTo(width - 10, bottom); ctx.stroke();
          ctx.fillStyle = t.muted; ctx.font = "12px sans-serif"; ctx.fillText(name, 4, top + 5);
          fn(top,bottom); y += space;
        }
        if (active[0]) {
          lane("音频", (top,bottom) => {
            const max = Math.max(1000, ...shown.slice(Math.floor(left), Math.ceil(right)+1).map(r => Math.abs(r[1])));
            line(r => r[1], top,bottom,-max,max,t.colors[0],width);
            ctx.strokeStyle = t.border; ctx.setLineDash([3,4]); ctx.beginPath();
            ctx.moveTo(margin,(top+bottom)/2); ctx.lineTo(width-10,(top+bottom)/2); ctx.stroke(); ctx.setLineDash([]);
          });
          labels.push(["音频",t.colors[0]]);
        }
        if (active[1]) {
          lane("ADSR", (top,bottom) => {
            for (let i=0;i<4;i++) line(r => r[4+i],top,bottom,0,65535,t.colors[i],width);
          });
          for (let i=0;i<4;i++) labels.push(["声部 "+(i+1),t.colors[i]]);
        }
        if (active[2]) {
          lane("状态", (top,bottom) => {
            line(r => r[2],top,bottom,0,4,t.colors[1],width);
            line(r => r[3]*4,top,bottom,0,4,t.colors[2],width);
          });
          labels.push(["活跃声部",t.colors[1]],["削波",t.colors[2]]);
        }
        legend.innerHTML = labels.map(([name,color]) =>
          '<span><i class="swatch" style="background:'+color+'"></i> '+name+'</span>').join("");
        ctx.fillStyle = t.muted; ctx.font = "12px sans-serif";
        ctx.fillText((left/48).toFixed(2)+" ms",margin,height-5);
        ctx.fillText((right/48).toFixed(2)+" ms",Math.max(margin,width-85),height-5);
        if (cursor >= 0) {
          const x = xAt(cursor,width);
          ctx.strokeStyle = t.fg; ctx.setLineDash([4,3]); ctx.beginPath();
          ctx.moveTo(x,10); ctx.lineTo(x,height-22); ctx.stroke(); ctx.setLineDash([]);
          const r = shown[cursor];
          readout.textContent = "t "+(cursor/48).toFixed(3)+" ms  音频 "+r[1]+
            "  声部 "+r[2]+"  削波 "+r[3]+"  包络 ["+r.slice(4,8).join(", ")+
            "]  阶段 ["+r.slice(8,12).join(", ")+"]  FIFO ["+r[12]+", "+r[13]+"]";
        } else readout.textContent = "";
      }
      selector.addEventListener("change",fit);
      toggles.forEach(t => t.addEventListener("change",draw));
      root.querySelector("#a2-fit").addEventListener("click",fit);
      canvas.addEventListener("pointermove", e => {
        const rect = canvas.getBoundingClientRect();
        if (drag !== null) {
          const delta = (e.clientX - drag.x) * (right-left)/(canvas.clientWidth-margin-12);
          const span = right-left, maxLeft = Math.max(0,shown.length-1-span);
          left = Math.min(maxLeft,Math.max(0,drag.left-delta)); right = left+span;
        }
        cursor = indexAt(e.clientX-rect.left,canvas.clientWidth);
        draw();
      });
      canvas.addEventListener("pointerdown",e => {
        drag = {x:e.clientX,left}; canvas.setPointerCapture(e.pointerId);
      });
      canvas.addEventListener("pointerup",() => { drag=null; });
      canvas.addEventListener("pointercancel",() => { drag=null; });
      canvas.addEventListener("wheel",e => {
        e.preventDefault();
        const rect = canvas.getBoundingClientRect();
        const anchor = indexAt(e.clientX-rect.left,canvas.clientWidth);
        const span = Math.max(32,Math.min(shown.length-1,(right-left)*(e.deltaY>0?1.3:0.77)));
        const fraction = (anchor-left)/Math.max(1,right-left);
        left = Math.max(0,Math.min(shown.length-1-span,anchor-span*fraction));
        right = left+span;
        draw();
      },{passive:false});
      new ResizeObserver(draw).observe(root);
      fit();
    })();
  </script>
</div>
"""
TARGET.parent.mkdir(parents=True, exist_ok=True)
TARGET.write_text(html.replace("__DATA__", payload), encoding="utf-8")
print(f"{TARGET} ({TARGET.stat().st_size} bytes)")
