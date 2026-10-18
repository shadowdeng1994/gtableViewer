// 浏览器端渲染定量校验片段（通过 browser.evaluate 注入使用）
//
// 原理：Scripts/ref_grid.R 用 R 把同一张图渲染成 PNG（画布 = Size 英寸，分辨率
// res=200，即 1400x1000 / 1400x1222 这种），再压缩成平均亮度网格（白底，行 0 = 顶部，
// 每格约 6.4 px @72dpi），存到 Scripts/.ref/<id>.grid.txt。
// 这里在浏览器里加载同一份 JSON、把 2D 容器伪成同一像素预算（长边 1400）后画到
// canvas-2d，用同样的网格采样，逐格求平均亮度后计算 MAE（0-255 尺度）并列出误差最大的格子。
//
// 网格尺寸不写死：从基准文件自身推断（非空行数 = 行，第一行的数字个数 = 列），
// 所以 79x57 的老基准和 79x70 这种新尺寸都能直接比。
//
// 判据：MAE <= 1.5 视为与 R 渲染一致；> 3 说明有图元缺失或错位。
//
// 用法（需 http:// 打开，因为要 fetch .ref 网格；preview.html 已内嵌 JSON）：
//   fetch('./Scripts/check_render.js').then(r=>r.text()).then(t=>eval(t))
// 分批：先 window.__CHECK_IDS__ = ['RepresentativeTree'] 再执行上面那句。

(async () => {
  const G = window.__GTV__;
  if (!G) return JSON.stringify({ error: 'no __GTV__ hook' });
  const cv = document.getElementById('canvas-2d');
  const ctx = cv.getContext('2d');
  // 样例清单里谁有 Scripts/.ref/<id>.grid.txt 基准就查谁：新丢进来的图没基准会自动跳过
  let ids;
  try {
    const man = await (await fetch('./samples/index.json', { cache: 'no-store' })).json();
    const probed = await Promise.all(man.map(async (s) => {
      const r = await fetch('./Scripts/.ref/' + s.id + '.grid.txt');
      return r.ok ? s.id : null;
    }));
    ids = probed.filter(Boolean);
    if (!ids.length) ids = ['scatter', 'boxplot', 'facet'];
  } catch (e) { ids = ['scatter', 'boxplot', 'facet']; }
  // 只查指定样例：十几 MB 的大样例一次跑不完注入脚本的超时，可以分批
  //   window.__CHECK_IDS__ = ['scatter', 'facet']
  if (Array.isArray(window.__CHECK_IDS__) && window.__CHECK_IDS__.length) {
    ids = ids.filter((i) => window.__CHECK_IDS__.indexOf(i) >= 0);
  }
  const out = [];

  // 画布像素预算与参考图对齐：ref_grid.R 按 Size 英寸 x res=200 光栅化（1400x1000 之类），
  // 网页若只有一张 500px 的小画布，栅格噪声本身就能把 MAE 抬到 10 以上。
  // 这里把 2D 容器临时伪成同一像素预算（长边 1400，保持 page 宽高比），再 resize2d。
  const TARGET_LONG = 1400;
  const parent = cv.parentElement;
  const realRect = parent.getBoundingClientRect;
  parent.getBoundingClientRect = () => {
    const p = (G.state && G.state.page) || { w: 504, h: 360 };
    const ar = p.w / p.h;
    let w = TARGET_LONG, h = w / ar;
    if (h > TARGET_LONG) { h = TARGET_LONG; w = h * ar; }
    return { x: 0, y: 0, top: 0, left: 0, right: w, bottom: h, width: w, height: h,
             toJSON: () => ({ width: w, height: h }) };
  };

  // 把 canvas 采样成 GW x GH 的平均亮度网格；透明像素按白底合成
  const sampleGrid = (GW, GH) => {
    const W = cv.width, H = cv.height;
    const d = ctx.getImageData(0, 0, W, H).data;
    const g = new Float64Array(GW * GH);
    for (let gy = 0; gy < GH; gy++) {
      const y0 = Math.floor(gy * H / GH), y1 = Math.max(y0 + 1, Math.floor((gy + 1) * H / GH));
      for (let gx = 0; gx < GW; gx++) {
        const x0 = Math.floor(gx * W / GW), x1 = Math.max(x0 + 1, Math.floor((gx + 1) * W / GW));
        let sum = 0, n = 0;
        for (let y = y0; y < y1; y++) {
          for (let x = x0; x < x1; x++) {
            const i = (y * W + x) * 4, a = d[i + 3] / 255;
            const r = d[i] * a + 255 * (1 - a);
            const gg = d[i + 1] * a + 255 * (1 - a);
            const b = d[i + 2] * a + 255 * (1 - a);
            sum += 0.299 * r + 0.587 * gg + 0.114 * b; n++;
          }
        }
        g[gy * GW + gx] = n ? sum / n : 255;
      }
    }
    return g;
  };

  for (const id of ids) {
    await G.loadSample(id);
    G.resize2d();                 // 按上面的容器预算重排 2D 画布（page 尺寸此时已就绪）
    const txt = await (await fetch('./Scripts/.ref/' + id + '.grid.txt')).text();
    const rows = txt.split('\n').map(l => l.trim()).filter(Boolean);
    if (!rows.length) { out.push({ id, error: 'ref grid 是空的' }); continue; }
    const GH = rows.length;
    const GW = rows[0].split(/\s+/).length;
    if (!rows.every(r => r.split(/\s+/).length === GW)) {
      out.push({ id, error: 'ref grid 每行列数不一致' }); continue;
    }
    const ref = rows.flatMap(r => r.split(/\s+/).map(Number));
    const page = G.state.page;
    // 画布被挤窄（比如 2D 单元折叠）时只有 80x80，采样分辨率不够会把 MAE 抬高，先报出来
    const cw = cv.width, ch = cv.height;
    const mine = sampleGrid(GW, GH);
    let abs = 0; const worst = [];
    for (let gy = 0; gy < GH; gy++) {
      for (let gx = 0; gx < GW; gx++) {
        const k = gy * GW + gx, e = Math.abs(mine[k] - ref[k]);
        abs += e;
        if (e > 40) worst.push([gx, gy, Math.round(ref[k]), Math.round(mine[k])]);
      }
    }
    worst.sort((a, b) => Math.abs(b[2] - b[3]) - Math.abs(a[2] - a[3]));
    out.push({
      id,
      grid: GW + 'x' + GH,
      canvas: cw + 'x' + ch,
      page: page.w + 'x' + page.h,
      mae: +(abs / (GW * GH)).toFixed(2),
      badCells: worst.length,
      hot: worst.slice(0, 6).map(w => w[0] + ',' + w[1] + ' ref' + w[2] + ' js' + w[3])
    });
  }
  parent.getBoundingClientRect = realRect;   // 还原，别影响页面正常布局
  return JSON.stringify(out, null, 1);
})()
