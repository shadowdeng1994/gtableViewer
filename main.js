/* gtableViewer — main.js
 * 左侧：2D 成品图（由导出的图元重绘）；右侧：3D 拆解视图（每个叶子 grob 占一层平面）
 * 坐标约定：全部为页面 npc（x 向右、y 向上，0~1），由 R 导出脚本产生。
 *
 * 约定：下面两行 import 必须各占一行，Scripts/build_preview.ps1 依赖这一点把它们剥离。
 */
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

(function () {
  'use strict';

  /* ───────────────────────── 常量 ───────────────────────── */

  // 样例清单：正常由 samples/index.json 提供（export_all.R 生成），
  // 下面这份只是清单缺失/加载失败时的兜底，保证老检出也能打开页面。
  const SAMPLES_FALLBACK = [
    { id: 'scatter', name: '散点图 + 图例', desc: '单个 panel：数据层、网格线、刻度、图例键' },
    { id: 'boxplot', name: '箱线图（分类轴）', desc: '离散 x 轴、线段型网格、按组着色' },
    { id: 'facet', name: '分面图（facet_wrap）', desc: '7 个 panel + strip 条，gtable 嵌套最丰富' },
  ];
  let SAMPLES = SAMPLES_FALLBACK.slice();

  // kind → 中文名与配色（图层树徽标 / 3D 描边 / 图例）
  // 注意：color 是「原色」，显示时要过 kindInfo() 拿主题适配色，别直接读这里的 color
  const KIND = {
    'background':  { label: '画布背景',   color: '#6b7280' },
    'panel-bg':    { label: '面板背景',   color: '#3b82f6' },
    'panel':       { label: '面板容器',   color: '#60a5fa' },
    'grid-major':  { label: '主网格线',   color: '#22d3ee' },
    'grid-minor':  { label: '次网格线',   color: '#0e7490' },
    'data':        { label: '数据层',     color: '#f472b6' },
    'axis':        { label: '轴线',       color: '#a3e635' },
    'axis-marks':  { label: '刻度线',     color: '#facc15' },
    'tick-labels': { label: '刻度标签',   color: '#fb923c' },
    'axis-title':  { label: '轴标题',     color: '#f87171' },
    'strip-bg':    { label: '分面条背景', color: '#a78bfa' },
    'strip-text':  { label: '分面条文字', color: '#c4b5fd' },
    'strip':       { label: '分面条',     color: '#8b5cf6' },
    'legend-key':  { label: '图例键',     color: '#34d399' },
    'legend-text': { label: '图例文字',   color: '#6ee7b7' },
    'legend':      { label: '图例容器',   color: '#10b981' },
    'title':       { label: '标题',       color: '#fbbf24' },
    'layout':      { label: '布局容器',   color: '#94a3b8' },
  };
  // 类别色的唯一出口：亮色主题下自动压暗，保证在浅底上仍读得清（调用点不要再各自处理）
  const kindInfo = (k) => {
    const i = KIND[k] || { label: k || 'grob', color: '#9ca3af' };
    return { label: i.label, color: ink(i.color) };
  };

  const TEX_Q = 2;                 // 纹理分辨率：每物理像素 2 个 texel
  const TEX_MIN = 32, TEX_MAX = 2048;
  const FRUSTUM_HALF = 4.6;        // 正交视锥半高（页面为 7×5 世界单位）

  /* ───────────────────────── 状态 ───────────────────────── */

  const state = {
    sampleId: null,
    data: null,
    page: { w: 504, h: 360 },
    nodes: [],
    byId: new Map(),
    childrenOf: new Map(),
    leaves: [],          // 带图元的节点，3D 中各占一层
    maxDraw: 1,
    minDraw: 0,
    vpW: 1, vpH: 1,    // 3D 视口的 CSS 像素尺寸（位图尺寸 = vpW × dpr）
    selected: new Set(), // 选中的叶子 id
    hover: null,
    explode: 0,          // 启动是俯视，爆炸量归零；点 3D 会恢复到 lastExplode
    isolate: false,
    showLabels: true,
    theme: 'light',      // 'dark' | 'light'，默认白天；<head> 预置脚本会按 localStorage 覆盖它
    meshOf: new Map(),   // id → THREE.Mesh
  };

  /* ───────────────────────── DOM ───────────────────────── */

  const $ = (id) => document.getElementById(id);
  const select = $('sample-select');
  const canvas2d = $('canvas-2d');
  const overlay2d = $('canvas-2d-overlay');
  const legend = $('legend');
  const selInfo = $('sel-info');
  const rpathBox = $('rpath');
  const viewport = $('viewport');
  const tooltip = $('tooltip');
  const tree = $('tree');
  const chkIsolate = $('chk-isolate');
  const chkLabels = $('chk-labels');
  const rangeExplode = $('explode');

  /* ───────────────────── 主题（明 / 暗） ───────────────────── */

  // 颜色唯一事实源是 style.css 的 CSS 变量；canvas 与 3D 线框画不出 var()，
  // 所以换主题时把这几个变量重读进 themeColors，别在 JS 里另写一套色值。
  const THEME_KEY = 'gtv-theme-v2';   // v1（'gtv-theme'）里的值可能是初始化自己写进去的，没法当偏好信任，故换键
  const cssVar = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  const themeColors = {};
  function readThemeColors() {
    themeColors.labelBg = cssVar('--label-bg') || 'rgba(255,255,255,.94)';
    themeColors.labelBd = cssVar('--label-bd') || 'rgba(22,32,58,.22)';
    themeColors.labelFg = cssVar('--label-fg') || '#16203a';
    themeColors.hlHover = cssVar('--hl-hover') || '#0f172a';
    themeColors.frame = cssVar('--frame-3d') || '#94a3b8';
  }

  /**
   * 类别色在亮底上会糊掉（#facc15 这种淡黄字在白底上几乎读不出），
   * 所以「文字 / 描边」用途统一走压暗变体；实心色块（图例色标）仍用原色。
   */
  const ink = (c) => {
    if (state.theme !== 'light' || typeof c !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(c)) return c;
    const f = (i) => Math.round(parseInt(c.substr(i, 2), 16) * 0.56).toString(16).padStart(2, '0');
    return '#' + f(1) + f(3) + f(5);
  };

  function applyTheme(t, first) {
    state.theme = t === 'light' ? 'light' : 'dark';
    document.documentElement.dataset.theme = state.theme;
    // 只在「用户真的点了切换」时落盘：初始化那次（first）写进去的值不是偏好，
    // 却会被 <head> 的预置脚本当成偏好读回来 —— 换默认主题时就会被它顶掉。
    if (!first) { try { localStorage.setItem(THEME_KEY, state.theme); } catch (e) { /* file:// 下可能被禁用 */ } }
    const btn = $('btn-theme');
    if (btn) {
      btn.querySelector('.ico').textContent = state.theme === 'light' ? '☀' : '☾';
      $('theme-text').textContent = state.theme === 'light' ? '亮色' : '暗色';
    }
    readThemeColors();
    if (first || !state.data) return;   // 还没数据：只换皮，别碰树和 3D
    if (frame3d) frame3d.material.color.set(themeColors.frame);
    const keepScroll = tree.scrollTop;   // 重建树会把滚动位置清掉，手动还回去
    buildTree();
    tree.scrollTop = keepScroll;
    buildLegend();
    renderSelInfo();
    syncTreeSelection();
    syncTreeHover();
    applyVisibility();                  // 重设高亮色，末尾顺带 render2d + drawOverlay
  }

  /* ─────────────────── 折叠（功能单元 + 左右整栏） ─────────────────── */

  // 折叠是「阅读偏好」，不是作品事实，所以只存 localStorage，不进事实层文件。
  // 键：sample / 2d / legend / sel / rpath = 左栏五个单元；toolbar = 3D 工具条；
  //     col-left / col-right = 整栏（整栏状态还要落到 <html data-lfold|data-rfold>，CSS 靠它改列宽）。
  const FOLD_KEY = 'gtv-fold';
  const FOLD_UNITS = ['sample', '2d', 'legend', 'sel', 'rpath', 'toolbar', 'col-left', 'col-right'];
  const foldState = {};
  try { Object.assign(foldState, JSON.parse(localStorage.getItem(FOLD_KEY) || '{}') || {}); } catch (e) { /* file:// 下可能被禁用 */ }

  const isFolded = (key) => !!foldState[key];

  function saveFold() {
    try { localStorage.setItem(FOLD_KEY, JSON.stringify(foldState)); } catch (e) { /* 同上 */ }
  }

  /** 把 foldState 翻译成 class 与 data 属性；不碰布局，可反复调用。 */
  function applyFold() {
    for (const el of document.querySelectorAll('[data-fold]')) {
      const on = isFolded(el.dataset.fold);
      el.classList.toggle('folded', on);
      const btn = el.querySelector('.fold');   // 单元标题栏与工具条共用 .fold
      if (btn) btn.setAttribute('aria-expanded', on ? 'false' : 'true');
    }
    const root = document.documentElement;
    root.dataset.lfold = isFolded('col-left') ? '1' : '';
    root.dataset.rfold = isFolded('col-right') ? '1' : '';
    for (const b of document.querySelectorAll('.gutter .gbtn')) {
      b.title = isFolded(b.parentElement.dataset.col) ? '展开这一栏' : '折叠这一栏';
    }
    const btn = $('btn-fold-all');
    if (btn) {
      const all = FOLD_UNITS.every(isFolded);
      btn.querySelector('.ico').textContent = all ? '⊞' : '⊟';
      $('fold-all-text').textContent = all ? '展开全部' : '折叠全部';
      btn.title = (all ? '展开' : '折叠') + '全部功能单元（快捷键 F）';
    }
  }

  /** force 省略 = 取反；画布尺寸跟着容器变，所以量完布局立刻重画一次。 */
  function toggleFold(key, force) {
    foldState[key] = force === undefined ? !isFolded(key) : !!force;
    saveFold();
    applyFold();
    // bindUI 里的 ResizeObserver 稍后会补一次，这里先同步量，展开的瞬间就是新尺寸
    resize2d();
    resize3d();
  }

  function toggleFoldAll() {
    // 只要还有没收起来的就「全收起」；已经全收了就「全展开」
    const open = FOLD_UNITS.some((k) => !isFolded(k));
    for (const k of FOLD_UNITS) foldState[k] = open;
    saveFold();
    applyFold();
    resize2d();
    resize3d();
  }

  /* ───────────────────── 栏宽（可拖拽） ───────────────────── */

  // 栏宽和折叠一样是「阅读偏好」，不是作品事实，所以只存 localStorage（与爆炸量记忆同一个键）。
  // 变量分两层：--w-*-set 是用户拖出来的值（内联在 <html> 上，<head> 里预置以免刷新时跳一下）；
  // --w-* 是网格真正用的那个，整栏折叠时 CSS 把它改成竖条宽度，内联值不参与竞争。
  const PREF_KEY = 'gtv-view';
  const COLS = {
    'col-left': { prop: '--w-left-set', panel: 'panel-left', min: 240, max: 720, dir: 1 },
    'col-right': { prop: '--w-right-set', panel: 'tree-panel', min: 170, max: 560, dir: -1 },
  };
  const prefs = {};
  try { Object.assign(prefs, JSON.parse(localStorage.getItem(PREF_KEY) || '{}') || {}); } catch (e) { /* file:// 下可能被禁用 */ }

  const rootEl = document.documentElement;

  /** 把存储里的栏宽落到 <html> 上；没存值就删掉内联属性，让 :root 的默认值生效。 */
  function applyColWidths() {
    for (const key in COLS) {
      const v = prefs[key];
      if (typeof v === 'number' && isFinite(v) && v > 0) rootEl.style.setProperty(COLS[key].prop, v + 'px');
      else rootEl.style.removeProperty(COLS[key].prop);
    }
  }

  function savePrefs() {
    try { localStorage.setItem(PREF_KEY, JSON.stringify(prefs)); } catch (e) { /* 同上 */ }
  }

  /** 当前实际栏宽：读网格解析后的面板宽度比读变量可靠（默认值是 minmax(320px, 40%)）。 */
  function colWidthNow(key) {
    const el = document.getElementById(COLS[key].panel);
    return el ? el.getBoundingClientRect().width : 320;
  }

  /**
   * 设栏宽（带上下限）。上限还要给中间 3D 视口留够地方：视口至少 360px，
   * 另一栏按它此刻的宽度算，所以两栏不会一起被拖到把视口挤没。
   * dir：左栏向右拖变宽（+1），右栏向左拖变宽（-1）。
   */
  function setColWidth(key, px) {
    const c = COLS[key];
    const other = key === 'col-left' ? colWidthNow('col-right') : colWidthNow('col-left');
    const room = window.innerWidth - other - 360 - 90;   // 90 ≈ 页面内边距 + 四条栏间距
    const max = Math.max(c.min, Math.min(c.max, room));
    const v = Math.round(Math.max(c.min, Math.min(max, px)));
    if (prefs[key] === v) return;
    prefs[key] = v;
    rootEl.style.setProperty(c.prop, v + 'px');
  }

  function resetColWidth(key) {
    delete prefs[key];
    rootEl.style.removeProperty(COLS[key].prop);
    savePrefs();
    resize2d();
    resize3d();
  }

  /** 拖拽条：按住左右拖、双击恢复默认、方向键微调（Shift 加大步长）。 */
  function bindGrips() {
    for (const g of document.querySelectorAll('.gutter .grip')) {
      const key = g.parentElement.dataset.col;
      const c = COLS[key];
      if (!c) continue;
      g.addEventListener('pointerdown', (ev) => {
        if (ev.button !== 0 || isFolded(key)) return;   // 折叠成竖条时不拖宽
        ev.preventDefault();
        const startX = ev.clientX;
        const base = colWidthNow(key);
        g.classList.add('drag');
        g.setPointerCapture(ev.pointerId);
        document.body.classList.add('col-resizing');
        const move = (e) => setColWidth(key, base + (e.clientX - startX) * c.dir);
        const done = () => {
          g.classList.remove('drag');
          document.body.classList.remove('col-resizing');
          g.removeEventListener('pointermove', move);
          savePrefs();
          resize2d();   // 拖动中靠 ResizeObserver，收尾再同步量一次，免得停在半帧旧尺寸
          resize3d();
        };
        g.addEventListener('pointermove', move);
        g.addEventListener('pointerup', done, { once: true });
        g.addEventListener('pointercancel', done, { once: true });
      });
      g.addEventListener('dblclick', () => resetColWidth(key));
      g.addEventListener('keydown', (ev) => {
        const step = ev.shiftKey ? 48 : 12;
        if (ev.key === 'ArrowLeft') setColWidth(key, colWidthNow(key) - step * c.dir);
        else if (ev.key === 'ArrowRight') setColWidth(key, colWidthNow(key) + step * c.dir);
        else if (ev.key === 'Home' || ev.key === 'Delete') { resetColWidth(key); ev.preventDefault(); return; }
        else return;
        ev.preventDefault();
        savePrefs();
      });
    }
  }

  /* ───────────────────── 全屏（focus） ───────────────────── */

  // 全屏 = 两侧整栏收起 + 把「2D 成品」搬进视口左下角当悬浮卡：一边转 3D 拆解，一边对照成品。
  // 它是叠在「整栏折叠」之上的一层状态，只写 <html data-focus>，不动 data-lfold / data-rfold，
  // 退出全屏就回到用户原来的折叠与栏宽。卡片的位置尺寸和栏宽存在同一个偏好键里。
  const FLOAT_MIN = { w: 200, h: 130 };
  const block2d = $('block-2d');
  const panelLeft = $('panel-left');
  const block2dAnchor = block2d ? block2d.nextSibling : null;   // 搬走之前记住原位，退出时插回去
  let focusMode = false;
  let floatDragged = false;    // 刚拖完卡片：落在标题栏上的这一下不该被当成「折叠」

  /** 悬浮卡默认尺寸：按当前图的长宽比给，宽图不会被塞进方框里。 */
  function floatFit() {
    const ar = state.page.w / Math.max(1, state.page.h);
    const w = 340;
    return { w, h: Math.round(Math.max(FLOAT_MIN.h, Math.min(430, w / ar + 30))) };
  }

  /** 偏好里的位置尺寸 + 视口夹取。x / y 是卡片到视口左边、下边的距离（贴左下角，窗口变高也不跑位）。 */
  function floatGeom() {
    const p = prefs.float2d || {};
    const f = floatFit();
    const box = viewport.getBoundingClientRect();
    const w = Math.max(FLOAT_MIN.w, Math.min(Math.max(FLOAT_MIN.w, box.width - 8), p.w || f.w));
    const h = Math.max(FLOAT_MIN.h, Math.min(Math.max(FLOAT_MIN.h, box.height - 8), p.h || f.h));
    const x = Math.min(Math.max(4, p.x === undefined ? 18 : p.x), Math.max(4, box.width - w - 4));
    const y = Math.min(Math.max(4, p.y === undefined ? 18 : p.y), Math.max(4, box.height - h - 4));
    return { w, h, x, y };
  }

  function applyFloat() {
    if (!focusMode) return;
    const g = floatGeom();
    block2d.style.setProperty('--fw', g.w + 'px');
    block2d.style.setProperty('--fh', g.h + 'px');
    block2d.style.setProperty('--fx', g.x + 'px');
    block2d.style.setProperty('--fy', g.y + 'px');
  }

  /** 进出全屏：卡片是「搬家」而不是「复制」，canvas 与其 ResizeObserver 都跟着 DOM 节点走。 */
  function setFocus(on) {
    on = !!on;
    if (on === focusMode || !block2d) return;
    focusMode = on;
    rootEl.dataset.focus = on ? '1' : '';
    if (on) {
      viewport.appendChild(block2d);
      block2d.classList.add('is-float');
      if (isFolded('2d')) toggleFold('2d', false);   // 全屏就是为了看成品，别停在折叠态
      applyFloat();
    } else {
      block2d.classList.remove('is-float');
      for (const v of ['--fw', '--fh', '--fx', '--fy']) block2d.style.removeProperty(v);
      panelLeft.insertBefore(block2d, block2dAnchor);
    }
    const btn = $('btn-focus');
    btn.classList.toggle('on', on);
    $('focus-text').textContent = on ? '退出全屏' : '全屏';
    btn.title = on ? '退出全屏，恢复左右两栏（Esc）' : '全屏：收起两侧，2D 成品悬浮在视口左下角（Esc 退出）';
    resize2d();
    resize3d();
  }

  /** 悬浮卡交互：拖标题栏挪位置，拖右下角改大小，✕ 退出全屏。松手才写 localStorage。 */
  function bindFloat() {
    if (!block2d) return;
    const start = (ev, mode) => {
      if (!focusMode || ev.button !== 0 || (ev.target.closest && ev.target.closest('.fx'))) return;
      ev.preventDefault();
      const g = floatGeom();
      const sx = ev.clientX, sy = ev.clientY;
      let moved = false;
      block2d.classList.add('dragging');
      document.body.classList.add(mode === 'move' ? 'float-moving' : 'float-sizing');
      block2d.setPointerCapture(ev.pointerId);
      const move = (e) => {
        const dx = e.clientX - sx, dy = e.clientY - sy;
        if (!moved && Math.abs(dx) + Math.abs(dy) < 4) return;
        moved = true;
        prefs.float2d = mode === 'move'
          ? { x: g.x + dx, y: g.y - dy, w: g.w, h: g.h }      // y 是「到下边的距离」，所以向下拖要取负
          : { x: g.x, y: g.y, w: g.w + dx, h: g.h - dy };     // 右下角向右下拖 = 变宽变高
        applyFloat();
        if (mode === 'size') resize2d();
      };
      const done = () => {
        block2d.classList.remove('dragging');
        document.body.classList.remove('float-moving', 'float-sizing');
        block2d.removeEventListener('pointermove', move);
        if (moved) {
          floatDragged = true;   // 压掉紧随其后的 click，否则拖一下就把卡片折叠了
          savePrefs();
          resize2d();
          setTimeout(() => { floatDragged = false; }, 0);
        }
      };
      block2d.addEventListener('pointermove', move);
      block2d.addEventListener('pointerup', done, { once: true });
      block2d.addEventListener('pointercancel', done, { once: true });
    };
    block2d.querySelector('h2.head').addEventListener('pointerdown', (ev) => start(ev, 'move'));
    block2d.querySelector('.fresize').addEventListener('pointerdown', (ev) => { ev.stopPropagation(); start(ev, 'size'); });
    $('btn-unfocus').addEventListener('click', (ev) => { ev.stopPropagation(); setFocus(false); });
    window.addEventListener('resize', () => { if (focusMode) { applyFloat(); resize2d(); } });
  }

  /* ───────────────── 图元绘制（2D 与 3D 纹理共用） ───────────────── */

  /**
   * 图元绘制（2D 画布与 3D 纹理共用）。
   * 页面 npc 中的 bbox(bx,by,bw,bh) 映射到 ctx 的 (0,0,W,H)。
   *   sx/sy  = 每 1 npc 对应多少画布像素
   *   fx/fy  = 每 1「72dpi 物理像素」对应多少画布像素（lwd / size / 字号都用物理像素）
   * 图元 schema 见 Scripts/export_gtable.R：
   *   rect {x,y,w,h,fill,fill_alpha,stroke,stroke_alpha,lwd}
   *   seg  {xy:[x0,y0,x1,y1,…] 两两成段, color,alpha,lwd,dash,cap?}
   *   line {xy:[…连续折线],     color,alpha,lwd,dash,cap?,join?}
   *   poly {xy:[…连续顶点,闭合], fill,fill_alpha,stroke,stroke_alpha,lwd,dash}
   *   pts  {xy:[…], size=直径, color,alpha,fill,fill_alpha}
   *   text {s,x,y,size,color,alpha,rot,hjust,vjust,bold,italic}
   * cap/join 只在非默认值（butt/miter）时出现，取自 grid 的 gp$lineend / gp$linejoin。
   * 颜色为 null / 非字符串（旧导出的 {}）一律视为「不上色」。
   */
  function drawPrims(ctx, prims, W, H, bbox, page) {
    const css = (v) => (typeof v === 'string' && v && v !== 'NA' ? v : null);
    // 线宽：grid 的 gp$lwd 单位是 pt，导出层按 72dpi 原样存成「物理像素」，这里只换算不抬高。
    // 以前兜底成「至少 0.6px」，可 ggtree 这类图的枝干 lwd 只有 0.085pt —— R 里那就是
    // 不到一个像素的淡发丝线，硬抬到 0.6px 会让整张图比 R 深四成（墨量实测 1.42 倍）。
    const lw = (p, k) => Math.max(0.02, (p.lwd || 1) * k);
    const [bx, by, bw, bh] = bbox;
    const sx = W / bw, sy = H / bh;
    const fx = sx / page.w, fy = sy / page.h;
    const X = (x) => (x - bx) * sx;
    const Y = (y) => (by + bh - y) * sy;   // npc 的 y 向上 → 画布 y 向下

    for (const p of prims) {
      const a = p.alpha == null ? 1 : p.alpha;
      if (p.t === 'rect') {
        const x = X(p.x), y = Y(p.y + p.h), w = p.w * sx, h = p.h * sy;
        const fill = css(p.fill), stroke = css(p.stroke);
        if (fill) {
          ctx.globalAlpha = p.fill_alpha == null ? a : p.fill_alpha;
          ctx.fillStyle = fill;
          ctx.fillRect(x, y, w, h);
        }
        if (stroke) {
          ctx.globalAlpha = p.stroke_alpha == null ? a : p.stroke_alpha;
          ctx.strokeStyle = stroke;
          ctx.lineWidth = lw(p, fx);
          ctx.strokeRect(x, y, w, h);
        }
        ctx.globalAlpha = 1;
      } else if (p.t === 'seg' || p.t === 'line' || p.t === 'poly') {
        const c = p.xy || [];
        if (c.length < 4) continue;
        if (p.dash === null) continue;   // lty = "blank"：grid 里根本不画
        const stroke = css(p.color) || (p.t === 'poly' ? css(p.stroke) : null);
        const fill = p.t === 'poly' ? css(p.fill) : null;
        ctx.globalAlpha = a;
        if (fill || stroke) {
          if (p.dash) ctx.setLineDash([5 * fx, 3.5 * fx]);
          ctx.beginPath();
          if (p.t === 'seg') {
            for (let i = 0; i + 3 < c.length; i += 4) {   // 每 4 个数 = 一条独立线段
              ctx.moveTo(X(c[i]), Y(c[i + 1]));
              ctx.lineTo(X(c[i + 2]), Y(c[i + 3]));
            }
          } else {
            ctx.moveTo(X(c[0]), Y(c[1]));
            for (let i = 2; i + 1 < c.length; i += 2) ctx.lineTo(X(c[i]), Y(c[i + 1]));
            if (p.t === 'poly') ctx.closePath();
          }
          if (fill) {
            ctx.globalAlpha = p.fill_alpha == null ? a : p.fill_alpha;
            ctx.fillStyle = fill;
            ctx.fill();
            ctx.globalAlpha = a;
          }
          if (stroke) {
            ctx.strokeStyle = stroke;
            ctx.lineWidth = lw(p, fx);
            // grid 的 lineend / linejoin：默认 butt + miter 与 canvas 相同，导出器只在非默认时写进 JSON
            // （ggtree 的枝干是 round 端头，按 butt 画整棵树会比 R 淡 4~14%）
            if (p.cap) ctx.lineCap = p.cap;
            if (p.join) ctx.lineJoin = p.join;
            ctx.globalAlpha = p.stroke_alpha == null ? a : p.stroke_alpha;
            ctx.stroke();
            if (p.cap) ctx.lineCap = 'butt';
            if (p.join) ctx.lineJoin = 'miter';
          }
          if (p.dash) ctx.setLineDash([]);
        }
        ctx.globalAlpha = 1;
      } else if (p.t === 'pts') {
        const c = p.xy || [];
        const r = Math.max(0.02, (p.size || 1.5) / 2 * fx);   // 同 lw()：直径按 pt 原样换算，不抬高
        const stroke = css(p.color) || '#1a1a1a';
        const fill = css(p.fill) || stroke;   // grid 的 pch 19：fill 缺省时用描边色实心填充
        ctx.globalAlpha = a;
        ctx.beginPath();
        for (let i = 0; i + 1 < c.length; i += 2) {
          const px = X(c[i]), py = Y(c[i + 1]);
          ctx.moveTo(px + r, py);
          ctx.arc(px, py, r, 0, Math.PI * 2);
        }
        ctx.fillStyle = fill;
        ctx.globalAlpha = p.fill_alpha == null ? a : p.fill_alpha;
        ctx.fill();
        ctx.globalAlpha = 1;
      } else if (p.t === 'text') {
        if (!p.s) continue;
        const fs = Math.max(3, (p.size || 12) * fy);
        ctx.globalAlpha = a;
        ctx.font = (p.bold ? 'bold ' : '') + (p.italic ? 'italic ' : '') +
          fs + 'px "Helvetica Neue", Helvetica, Arial, "Noto Sans SC", sans-serif';
        ctx.fillStyle = css(p.color) || '#1a1a1a';
        const hj = p.hjust == null ? 0.5 : p.hjust, vj = p.vjust == null ? 0.5 : p.vjust;
        ctx.textAlign = hj < 0.25 ? 'left' : hj > 0.75 ? 'right' : 'center';
        ctx.textBaseline = 'middle';
        ctx.save();
        ctx.translate(X(p.x), Y(p.y));
        if (p.rot) ctx.rotate(-p.rot * Math.PI / 180);
        // grid 的 vjust：0 = 文字在锚点上方，1 = 在下方
        ctx.fillText(String(p.s), 0, -(0.5 - vj) * fs);
        ctx.restore();
        ctx.globalAlpha = 1;
      }
    }
  }

  /* ───────────────────────── 2D 视图 ───────────────────────── */

  let ctx2d = null, octx = null, size2d = { w: 0, h: 0 };

  function resize2d() {
    const box = canvas2d.parentElement.getBoundingClientRect();
    const pad = 26;
    const availW = Math.max(80, box.width - pad), availH = Math.max(80, box.height - pad);
    const ar = state.page.w / state.page.h;
    let w = availW, h = w / ar;
    if (h > availH) { h = availH; w = h * ar; }
    const dpr = window.devicePixelRatio || 1;
    size2d = { w, h };
    for (const cv of [canvas2d, overlay2d]) {
      cv.width = Math.round(w * dpr);
      cv.height = Math.round(h * dpr);
      cv.style.width = w + 'px';
      cv.style.height = h + 'px';
    }
    canvas2d.style.left = (box.width - w) / 2 + 'px';
    canvas2d.style.top = (box.height - h) / 2 + 'px';
    overlay2d.style.left = canvas2d.style.left;
    overlay2d.style.top = canvas2d.style.top;
    ctx2d = canvas2d.getContext('2d');
    octx = overlay2d.getContext('2d');
    ctx2d.setTransform(dpr, 0, 0, dpr, 0, 0);
    octx.setTransform(dpr, 0, 0, dpr, 0, 0);
    render2d();
  }

  function render2d() {
    if (!ctx2d || !state.data) return;
    const { w, h } = size2d;
    ctx2d.setTransform(window.devicePixelRatio || 1, 0, 0, window.devicePixelRatio || 1, 0, 0);
    ctx2d.clearRect(0, 0, w, h);
    ctx2d.fillStyle = '#ffffff';
    ctx2d.fillRect(0, 0, w, h);
    const hasSel = state.selected.size > 0;
    for (const n of state.leaves) {
      if (state.isolate && hasSel && !state.selected.has(n.id)) continue;
      // 2D 画布覆盖整页，映射框恒为全页 bbox；bbox 只用于 3D 平面与高亮框
      drawPrims(ctx2d, n.prims, w, h, [0, 0, 1, 1], state.page);
    }
    drawOverlay();
  }

  function drawOverlay() {
    if (!octx) return;
    const { w, h } = size2d;
    octx.clearRect(0, 0, w, h);
    const paint = (n, color, fillA, lineW, dash) => {
      const [bx, by, bw, bh] = n.bbox;
      const xx = bx * w, ww = bw * w;
      const top = (1 - (by + bh)) * h, hh = bh * h;
      octx.save();
      if (fillA) {
        octx.globalAlpha = fillA;
        octx.fillStyle = color;
        octx.fillRect(xx, top, ww, hh);
      }
      octx.globalAlpha = 1;
      octx.strokeStyle = color;
      octx.lineWidth = lineW;
      if (dash) octx.setLineDash([5, 3]);
      octx.strokeRect(xx, top, ww, hh);
      octx.restore();
    };
    for (const id of state.selected) {
      const n = state.byId.get(id);
      // 2D 画布永远是白的，kindInfo 已按主题压暗，描边才读得出来
      if (n) paint(n, kindInfo(n.kind).color, 0.18, 2, false);
    }
    if (state.hover && !state.selected.has(state.hover)) {
      const n = state.byId.get(state.hover);
      if (n) paint(n, themeColors.hlHover, 0.08, 1.5, true);
    }
  }

  /* ───────────────────────── 3D 视图 ───────────────────────── */

  let renderer, scene, camera, controls, raycaster, group, labelCanvas, lctx, frame3d;
  const highlighters = new Map(); // id → THREE.LineSegments

  const worldW = () => state.page.w / 72;   // 世界单位 = 物理英寸（7×5）
  const worldH = () => state.page.h / 72;
  const zSpread = () => 2.2;
  // Z 用 minDraw 归一化：让最底层（plot.background，通常 draw 最小）正好落在 z=0 的画布边框上。
  // 若写成 d / maxDraw，背景片会浮在边框上方一截，3D 斜视时白色画布与灰色边框错开，看着就是"画布没对齐"。
  const zOf = (d) => ((d - state.minDraw) / Math.max(1, state.maxDraw - state.minDraw)) * zSpread() * state.explode;

  function init3d() {
    renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setPixelRatio(window.devicePixelRatio || 1);
    renderer.domElement.style.position = 'absolute';
    renderer.domElement.style.inset = '0';
    viewport.appendChild(renderer.domElement);

    scene = new THREE.Scene();
    // 正交相机：俯视时是严格正射投影，2D 形状不会变形；3D 则像工程爆炸图
    camera = new THREE.OrthographicCamera(-5, 5, 5, -5, -200, 400);
    controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.12;
    controls.rotateSpeed = 0.9;
    controls.zoomSpeed = 1.1;

    raycaster = new THREE.Raycaster();

    group = new THREE.Group();
    scene.add(group);

    labelCanvas = document.createElement('canvas');
    labelCanvas.style.cssText = 'position:absolute;inset:0;pointer-events:none;';
    viewport.appendChild(labelCanvas);
    lctx = labelCanvas.getContext('2d');

    renderer.domElement.addEventListener('pointermove', onPointerMove);
    renderer.domElement.addEventListener('pointerdown', onPointerDown);
    // 选中改在 pointerup 判定。OrbitControls 在 pointerdown 时 setPointerCapture，
    // 抬起事件会被重定向到 canvas，所以听同一个元素就收得到（拖出视口再松手也一样）。
    renderer.domElement.addEventListener('pointerup', onPointerUp);
    renderer.domElement.addEventListener('pointercancel', () => { downPt = null; });
    renderer.domElement.addEventListener('pointerleave', () => setHover(null));
  }

  function makeTexture(node) {
    const [bx, by, bw, bh] = node.bbox;
    const tw = Math.min(TEX_MAX, Math.max(TEX_MIN, Math.round(bw * state.page.w * TEX_Q)));
    const th = Math.min(TEX_MAX, Math.max(TEX_MIN, Math.round(bh * state.page.h * TEX_Q)));
    const cv = document.createElement('canvas');
    cv.width = tw; cv.height = th;
    drawPrims(cv.getContext('2d'), node.prims, tw, th, node.bbox, state.page);
    const tex = new THREE.CanvasTexture(cv);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.anisotropy = 4;
    tex.needsUpdate = true;
    return tex;
  }

  function clear3d() {
    for (const o of group.children.slice()) {
      if (o.material) { if (o.material.map) o.material.map.dispose(); o.material.dispose(); }
      if (o.geometry) o.geometry.dispose();
      group.remove(o);
    }
    highlighters.clear();
    state.meshOf.clear();
  }

  function build3d() {
    clear3d();
    group.position.set(-worldW() / 2, -worldH() / 2, 0);

    // 画布边界框（整张页面 7×5）
    // 注意：PlaneGeometry 是"以本地原点为中心"的，而 group 已经把页面 (0,0) 挪到了 group 原点，
    // 所以边框必须平移到页面中心 (W/2, H/2)，否则它会整体偏左下半个页面（只压住画布的左下四分之一）。
    const frame = new THREE.LineSegments(
      new THREE.EdgesGeometry(new THREE.PlaneGeometry(worldW(), worldH())),
      new THREE.LineBasicMaterial({ color: new THREE.Color(themeColors.frame), transparent: true, opacity: 0.6 })
    );
    frame.position.set(worldW() / 2, worldH() / 2, 0);
    frame.renderOrder = 9999;
    group.add(frame);
    frame3d = frame;

    for (const n of state.leaves) {
      const [bx, by, bw, bh] = n.bbox;
      const w = Math.max(1e-4, bw * worldW()), h = Math.max(1e-4, bh * worldH());
      const geo = new THREE.PlaneGeometry(w, h);
      const mat = new THREE.MeshBasicMaterial({
        map: makeTexture(n), transparent: true, side: THREE.DoubleSide, depthWrite: false,
      });
      const mesh = new THREE.Mesh(geo, mat);
      mesh.position.set((bx + bw / 2) * worldW(), (by + bh / 2) * worldH(), zOf(n.draw));
      mesh.userData.id = n.id;
      mesh.renderOrder = n.draw;
      group.add(mesh);
      state.meshOf.set(n.id, mesh);

      const hl = new THREE.LineSegments(
        new THREE.EdgesGeometry(geo),
        new THREE.LineBasicMaterial({ color: new THREE.Color(kindInfo(n.kind).color), transparent: true, opacity: 0.95 })
      );
      hl.position.set(mesh.position.x, mesh.position.y, mesh.position.z + 0.002);
      hl.visible = false;
      hl.renderOrder = 20000 + n.draw;
      group.add(hl);
      highlighters.set(n.id, hl);
    }
    applyVisibility();
  }

  function updateZ() {
    for (const n of state.leaves) {
      const mesh = state.meshOf.get(n.id);
      if (!mesh) continue;
      const z = zOf(n.draw);
      mesh.position.z = z;
      const hl = highlighters.get(n.id);
      if (hl) hl.position.z = z + 0.002;
    }
  }

  function applyVisibility() {
    const hasSel = state.selected.size > 0;
    for (const n of state.leaves) {
      const mesh = state.meshOf.get(n.id);
      if (!mesh) continue;
      const on = !(state.isolate && hasSel && !state.selected.has(n.id));
      mesh.visible = on;
      mesh.material.opacity = on && (!state.isolate || !hasSel || state.selected.has(n.id)) ? 1 : 0.22;
      const hl = highlighters.get(n.id);
      if (hl) {
        hl.visible = on && (state.selected.has(n.id) || state.hover === n.id);
        hl.material.color.set(state.hover === n.id && !state.selected.has(n.id) ? themeColors.hlHover : kindInfo(n.kind).color);
      }
    }
    render2d();
  }

  function resize3d() {
    if (!renderer) return;
    const w = viewport.clientWidth, h = viewport.clientHeight;
    if (w < 2 || h < 2) return;
    const dpr = window.devicePixelRatio || 1;
    // 必须让 three 同时写 CSS 尺寸（第三个参数不能是 false）：
    // canvas 只有 position:absolute;inset:0，没有 width/height，
    // 一旦位图尺寸 ≠ CSS 尺寸，canvas 的 CSS 尺寸就退回"固有尺寸 = 位图尺寸 = w×dpr"，
    // 在 125%/150% 显示缩放下画布会比容器大一圈并贴住左上角 → 3D 画面整体偏移被裁切，拾取也错位。
    renderer.setPixelRatio(dpr);
    renderer.setSize(w, h);
    state.vpW = w; state.vpH = h;
    // 标签层同理：位图按 dpr 放大保证文字清晰，CSS 尺寸锁死为容器尺寸
    // （用 floor 与 three.js 的 setSize 取整方式保持一致，两层位图尺寸完全相同）
    labelCanvas.width = Math.floor(w * dpr);
    labelCanvas.height = Math.floor(h * dpr);
    labelCanvas.style.width = w + 'px';
    labelCanvas.style.height = h + 'px';
    lctx.setTransform(dpr, 0, 0, dpr, 0, 0); // 改尺寸会重置上下文状态，需重设变换
    updateFrustum();
  }

  function updateFrustum() {
    const w = Math.max(1, viewport.clientWidth), h = Math.max(1, viewport.clientHeight);
    const a = w / h;
    camera.left = -FRUSTUM_HALF * a; camera.right = FRUSTUM_HALF * a;
    camera.top = FRUSTUM_HALF; camera.bottom = -FRUSTUM_HALF;
    camera.updateProjectionMatrix();
  }

  // 把「画布盒子」（7×5 世界单位 × 当前爆炸高度）的 8 个角投影到 NDC，
  // 反推正交 zoom，使画布按 fill 比例铺进视口。
  // 比原来按 860/640 经验系数估 zoom 可靠：换窗口比例、换页面尺寸、换爆炸高度都不会跑偏。
  function fitZoom(fill) {
    const v = new THREE.Vector3();
    const zTop = zOf(state.maxDraw);
    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
    for (const cx of [0, worldW()]) for (const cy of [0, worldH()]) for (const cz of [0, zTop]) {
      v.set(cx - worldW() / 2, cy - worldH() / 2, cz).project(camera);
      if (v.x < x0) x0 = v.x; if (v.x > x1) x1 = v.x;
      if (v.y < y0) y0 = v.y; if (v.y > y1) y1 = v.y;
    }
    const z0 = camera.zoom;
    const zx = (z0 * 2 * fill) / Math.max(1e-6, x1 - x0);
    const zy = (z0 * 2 * fill) / Math.max(1e-6, y1 - y0);
    return Math.max(0.05, Math.min(6, Math.min(zx, zy)));
  }

  // 正交相机改 zoom / 位姿后必须先更新 matrixWorld，project() 才拿得到正确结果
  function applyZoom(fill) {
    controls.update();
    camera.updateMatrixWorld();
    camera.zoom = fitZoom(fill);
    camera.updateProjectionMatrix();
    controls.update();
  }

  // 用户最后一次手调的非零爆炸量：点 3D 时恢复它。和栏宽存在同一个偏好键里，刷新后还是他的习惯值。
  let lastExplode = typeof prefs.explode === 'number' && prefs.explode > 0 ? Math.min(3, prefs.explode) : 1;

  /**
   * 设爆炸量。remember=true 只给手调滑杆用——记下的必须是「手调值」而不是当前值，
   * 否则点一次俯视就把 0 记成偏好，3D 再也打不开。
   */
  function setExplode(v, remember) {
    const val = Math.max(0, Math.min(3, isFinite(v) ? v : 0));
    state.explode = val;
    rangeExplode.value = String(val);
    if (remember && val > 0) lastExplode = val;
    updateZ();
  }

  /* 俯视就是「看叠合后的成品」，所以爆炸量归零；点 3D 再把它恢复到上次手调的值。 */
  function viewTop() { setExplode(0); setTopView(); }
  function viewIso() { setExplode(lastExplode > 0 ? lastExplode : 1); setIsoView(); }

  function setTopView() {
    camera.up.set(0, 1, 0);
    camera.position.set(0, 0, 20);
    controls.target.set(0, 0, 0);
    applyZoom(0.94);
  }

  // 3D 默认机位：页面右上方、偏前。三个分量是单位方向 (0.577, 0.307, 0.757)，
  // 与参考截图量出来的一致（正交投影下页面四边形的形状唯一决定这个方向）：
  //   页面在屏幕上转掉约 37°（宽压到 0.80），纵向只压到 0.95，
  //   所以顶边向右下倾斜约 12.5°，左边远、右边近，爆炸层往「左下」散开。
  // 注意 y 必须是正的（相机在页面上方）。取 -y 会得到一模一样的四边形但爆炸
  // 方向翻到右上，整张图看起来就是「从桌子底下往上掀」，不是这个角度。
  function setIsoView() {
    camera.up.set(0, 1, 0);
    const r = 20;
    camera.position.set(r * 0.577, r * 0.307, r * 0.757);
    controls.target.set(0, 0, 0);
    applyZoom(0.82);
  }

  function focusSelected() {
    if (!state.selected.size) return;
    let cx = 0, cy = 0, k = 0;
    for (const id of state.selected) {
      const n = state.byId.get(id);
      if (!n) continue;
      cx += (n.bbox[0] + n.bbox[2] / 2) * worldW();
      cy += (n.bbox[1] + n.bbox[3] / 2) * worldH();
      k++;
    }
    if (!k) return;
    controls.target.set(cx / k - worldW() / 2, cy / k - worldH() / 2, 0);
    controls.update();
  }

  /* ───────────────────────── 3D 交互 ───────────────────────── */

  const pointer = new THREE.Vector2();

  function pick(ev) {
    const r = renderer.domElement.getBoundingClientRect();
    pointer.x = ((ev.clientX - r.left) / r.width) * 2 - 1;
    pointer.y = -((ev.clientY - r.top) / r.height) * 2 + 1;
    raycaster.setFromCamera(pointer, camera);
    const hits = raycaster.intersectObjects(group.children.filter((o) => o.isMesh && o.visible), false);
    return hits.length ? hits[0].object.userData.id : null;
  }

  function onPointerMove(ev) {
    const id = pick(ev);
    setHover(id);
    if (id) {
      const n = state.byId.get(id);
      const info = kindInfo(n.kind);
      tooltip.style.display = 'block';
      tooltip.style.left = (ev.clientX + 14) + 'px';
      tooltip.style.top = (ev.clientY + 14) + 'px';
      tooltip.innerHTML =
        '<b>' + escapeHtml(n.name || info.label) + '</b>' +
        '<span class="k" style="background:' + info.color + '22;color:' + info.color +
        ';border:1px solid ' + info.color + '55">' + info.label + '</span><br>' +
        '绘制顺序 #' + n.draw + ' · 嵌套深度 ' + n.depth + ' · ' + primSummary(n.prims);
    } else {
      tooltip.style.display = 'none';
    }
  }

  /**
   * 左键「按下即选中」是错的：OrbitControls 的旋转也是左键，
   * 于是每次转视角都会把用户选好的图层清掉。改成标准的手势判定——
   * 按下→抬起之间位移小于 CLICK_SLOP 才算点击选中，超过就是旋转/平移手势，不碰选中。
   */
  const CLICK_SLOP = 4;   // CSS px
  let downPt = null;

  function onPointerDown(ev) {
    if (ev.button !== 0) return;   // 右键=平移、中键=推拉，都不参与选中
    downPt = { x: ev.clientX, y: ev.clientY };
  }

  function onPointerUp(ev) {
    if (ev.button !== 0 || !downPt) return;
    const moved = Math.abs(ev.clientX - downPt.x) + Math.abs(ev.clientY - downPt.y);
    downPt = null;
    if (moved > CLICK_SLOP) return;   // 是拖动手势，别动选中
    const id = pick(ev);
    const additive = ev.shiftKey || ev.ctrlKey || ev.metaKey;
    if (id == null) { if (!additive) setSelection([]); return; }
    const ids = expandSelection(id);
    if (additive) {
      const next = new Set(state.selected);
      for (const i of ids) { if (next.has(i)) next.delete(i); else next.add(i); }
      setSelection([...next]);
    } else {
      setSelection(ids);
    }
    focusSelected();
  }

  /** 容器节点 → 其全部后代叶子；叶子 → 自身 */
  function expandSelection(id) {
    const n = state.byId.get(id);
    if (!n) return [];
    if (n.prims && n.prims.length) return [id];
    const out = [];
    (function walk(nid) {
      for (const c of state.childrenOf.get(nid) || []) {
        const cn = state.byId.get(c);
        if (!cn) continue;
        if (cn.prims && cn.prims.length) out.push(c);
        walk(c);
      }
    })(id);
    return out.length ? out : [id];
  }

  function setHover(id) {
    if (state.hover === id) return;
    state.hover = id;
    if (!id) tooltip.style.display = 'none';
    applyVisibility();
    syncTreeHover();
  }

  function setSelection(ids) {
    state.selected = new Set(ids.filter((i) => state.byId.has(i)));
    applyVisibility();
    syncTreeSelection();
    renderSelInfo();
    renderRpath();
  }

  /* ───────────────────────── 图层树 ───────────────────────── */

  function buildTree() {
    tree.innerHTML = '';
    for (const n of state.nodes) {
      if (n.parent == null && hasPrimsTree(n.id)) tree.appendChild(treeNode(n.id));
    }
  }

  function treeNode(id) {
    const n = state.byId.get(id);
    const kids = (state.childrenOf.get(id) || []).filter(hasPrimsTree);
    const li = document.createElement('div');
    li.className = 'node';
    const row = document.createElement('div');
    row.className = 'row';
    row.dataset.id = id;
    if (n.rpath) row.title = n.rpath;   // 悬停图层树也能直接看到 R 里的取值路径
    const info = kindInfo(n.kind);
    const isLeaf = !!(n.prims && n.prims.length);
    row.innerHTML =
      '<span class="badge" style="background:' + info.color + '22;color:' + info.color +
      ';border:1px solid ' + info.color + '55">' + info.label + '</span>' +
      '<span class="nm">' + escapeHtml(n.name || '(unnamed)') + '</span>' +
      (isLeaf ? '<span class="cnt">' + primSummary(n.prims) + '</span>' : '') +
      '<span class="z">#' + n.draw + '</span>';
    row.addEventListener('click', (ev) => {
      const ids = expandSelection(id);
      if (ev.shiftKey || ev.ctrlKey || ev.metaKey) {
        const next = new Set(state.selected);
        for (const i of ids) { if (next.has(i)) next.delete(i); else next.add(i); }
        setSelection([...next]);
      } else setSelection(ids);
      focusSelected();
    });
    row.addEventListener('dblclick', () => { setSelection(expandSelection(id)); focusSelected(); });
    row.addEventListener('mouseenter', () => setHover(id));
    row.addEventListener('mouseleave', () => setHover(null));
    li.appendChild(row);
    if (kids.length) {
      const ul = document.createElement('div');
      ul.className = 'kids';
      for (const c of kids) ul.appendChild(treeNode(c));
      li.appendChild(ul);
    }
    return li;
  }

  function hasPrimsTree(id) {
    const n = state.byId.get(id);
    if (!n) return false;
    if (n.prims && n.prims.length) return true;
    for (const c of state.childrenOf.get(id) || []) if (hasPrimsTree(c)) return true;
    return false;
  }

  function syncTreeSelection() {
    for (const el of tree.querySelectorAll('.row')) {
      const id = el.dataset.id;
      const own = state.selected.has(id);
      el.classList.toggle('sel', own);
      el.classList.toggle('desc', !own && [...state.selected].some((s) => isDescendant(s, id)));
    }
  }

  function syncTreeHover() {
    for (const el of tree.querySelectorAll('.row'))
      el.classList.toggle('hov', el.dataset.id === state.hover);
  }

  function isDescendant(id, ancestor) {
    let cur = state.byId.get(id);
    while (cur && cur.parent != null) {
      if (cur.parent === ancestor) return true;
      cur = state.byId.get(cur.parent);
    }
    return false;
  }

  function renderSelInfo() {
    if (!state.selected.size) {
      selInfo.innerHTML = '<div class="empty">未选择 — 在右侧 3D 中点击图层，或点击左侧图层树；Shift/Ctrl 点击可多选</div>';
      return;
    }
    const ids = [...state.selected].sort((a, b) => state.byId.get(a).draw - state.byId.get(b).draw);
    const rows = ids.slice(0, 14).map((id) => {
      const n = state.byId.get(id);
      const info = kindInfo(n.kind);
      return '<div class="item"><span class="dot" style="background:' + info.color + '"></span>' +
        '<b>#' + n.draw + '</b> ' + info.label + ' <span class="mut">' + escapeHtml(n.name || '') + '</span>' +
        '<div class="mut">bbox(x,y,w,h) = ' + n.bbox.map((v) => v.toFixed(3)).join(', ') +
        ' · 深度 ' + n.depth + ' · ' + primSummary(n.prims) + '</div>' +
        (n.rpath ? '<div class="rp" data-rp="' + escapeHtml(n.rpath) + '" title="点击复制">' +
          escapeHtml(n.rpath) + '</div>' : '') + '</div>';
    });
    if (ids.length > 14) rows.push('<div class="mut">… 共 ' + ids.length + ' 层</div>');
    selInfo.innerHTML = rows.join('');
  }

  /* ─────────────────── gtable 定位（R 取值路径）─────────────────── */

  /** 复制。file:// 不是 secure context，navigator.clipboard 不可用，所以留了 execCommand 兜底 */
  function copyText(text, btn) {
    const done = () => {
      if (!btn) return;
      const old = btn.textContent;
      btn.textContent = '已复制 ✓';
      setTimeout(() => { btn.textContent = old; }, 1200);
    };
    const fallback = () => {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.cssText = 'position:fixed;left:-9999px;top:0;';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); done(); } catch (e) { /* 忽略：复制失败不影响阅读 */ }
      document.body.removeChild(ta);
    };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, fallback);
    } else fallback();
  }

  /** Set 保持插入顺序，最后一个就是用户刚点进去的那个 */
  function primaryId() {
    let last = null;
    for (const id of state.selected) last = id;
    return last;
  }

  /** 根在前的 id 链（含自身） */
  function chainOf(id) {
    const out = [];
    let cur = state.byId.get(id);
    while (cur) { out.unshift(cur.id); cur = cur.parent != null ? state.byId.get(cur.parent) : null; }
    return out;
  }

  /** 把 $grobs / $children 与下标染色，学生一眼看清每层取的是第几个 */
  function hlPath(s) {
    return escapeHtml(s)
      .replace(/\$(grobs|children)/g, '<i>$$$1</i>')
      .replace(/\[\[(\d+)\]\]/g, '[[<i>$1</i>]]');
  }

  function renderRpath() {
    const id = primaryId();
    if (!id) {
      rpathBox.innerHTML = '<div class="empty">未选择 — 选中图层后，这里给出从根对象一层层取到它的 R 表达式</div>';
      return;
    }
    const n = state.byId.get(id);
    if (!n.rpath) {
      rpathBox.innerHTML = '<div class="empty">这个样例的 JSON 里没有定位路径 — 用新版 export_gtable.R 重新导出即可</div>';
      return;
    }
    const chain = chainOf(id);
    // 面包屑上的名字去掉末尾自增编号：那个数字每画一次图就变，留着会让学生以为要在 R 里找同名 grob
    const crumbs = chain.map((cid, i) => {
      const cn = state.byId.get(cid);
      const label = (cn.parent == null ? cn.rpath : (cn.name || cn.rseg || '?')).replace(/\.\d+$/, '');
      const sep = i === 0 ? '' :
        '<span class="cs" title="上一步取的是第 ' + cn.rseg + ' 个子元素">' + escapeHtml(cn.rseg) + '</span>';
      return sep + '<span class="crumb' + (cid === id ? ' here' : '') + '" data-id="' + cid +
        '" title="' + escapeHtml(cn.rpath) + '">' + escapeHtml(label) + '</span>';
    }).join('');

    const rv = (state.data.meta && state.data.meta.root_var) || 'tmp';
    const tail = n.rpath.indexOf('$') >= 0 ? n.rpath.slice(n.rpath.indexOf('$')) : '';
    const multi = state.selected.size > 1
      ? '共选中 <b>' + state.selected.size + '</b> 个，这里定位最后选中的那个；其余元素的路径在上方「选中元素」列表里。'
      : '';

    rpathBox.innerHTML =
      '<div class="crumbs">' + crumbs + '</div>' +
      '<div class="code-line"><code title="点击复制">' + hlPath(n.rpath) + '</code>' +
      '<button class="copy" type="button">复制</button></div>' +
      '<div class="note">' + multi +
      '粘进 R 就是同一个 grob：先 <code>g &lt;- ggplotGrob(' + escapeHtml(rv) + ')</code>，再写 <code>g' + escapeHtml(tail) + '</code>。' +
      '名字末尾的自增编号每画一次图就变一批，所以<b>按路径下标找，别按名字找</b>。</div>';

    rpathBox.querySelector('.copy').addEventListener('click', (ev) => copyText(n.rpath, ev.currentTarget));
    rpathBox.querySelector('code').addEventListener('click', () => copyText(n.rpath));
    for (const el of rpathBox.querySelectorAll('.crumb')) {
      el.addEventListener('click', () => {
        const cid = el.dataset.id;
        setSelection(expandSelection(cid));   // 容器 → 它的全部叶子，与图层树点击同一套语义
        focusSelected();
      });
    }
  }

  // 列表里的路径行：点一下复制。事件委托绑在容器上，innerHTML 换了也不用重绑
  selInfo.addEventListener('click', (ev) => {
    const el = ev.target.closest('.rp');
    if (!el || !el.dataset.rp) return;
    copyText(el.dataset.rp, null);
  });

  /* ───────────────────────── 图例 ───────────────────────── */

  function buildLegend() {
    const counts = {};
    for (const n of state.leaves) counts[n.kind] = (counts[n.kind] || 0) + 1;
    legend.innerHTML = '';
    for (const k of Object.keys(KIND)) {
      if (!counts[k]) continue;
      const el = document.createElement('div');
      el.className = 'li';
      el.innerHTML = '<span class="sw" style="background:' + kindInfo(k).color + '"></span>' +
        KIND[k].label + '<span class="c">' + counts[k] + '</span>';
      el.addEventListener('click', () => {
        setSelection(state.leaves.filter((n) => n.kind === k).map((n) => n.id));
        focusSelected();
      });
      legend.appendChild(el);
    }
  }

  /* ───────────────────────── 标签叠加层 ───────────────────────── */

  function drawLabels() {
    if (!lctx) return;
    // 上下文已带 dpr 变换，这里一律用 CSS 像素
    const w = state.vpW, h = state.vpH;
    lctx.clearRect(0, 0, w, h);
    if (!state.showLabels) return;
    const ids = state.selected.size ? [...state.selected] : (state.hover ? [state.hover] : []);
    if (!ids.length) return;
    const v = new THREE.Vector3();
    lctx.font = '11px "JetBrains Mono", Consolas, monospace';
    for (const id of ids) {
      const mesh = state.meshOf.get(id), n = state.byId.get(id);
      if (!mesh || !n) continue;
      v.set(mesh.position.x + group.position.x, mesh.position.y + group.position.y, mesh.position.z);
      v.project(camera);
      const x = (v.x * 0.5 + 0.5) * w, y = (-v.y * 0.5 + 0.5) * h;
      const text = kindInfo(n.kind).label + ' #' + n.draw;
      const tw = lctx.measureText(text).width + 11;
      lctx.fillStyle = themeColors.labelBg;
      lctx.fillRect(x, y - 23, tw, 17);
      lctx.strokeStyle = themeColors.labelBd;
      lctx.lineWidth = 1;
      lctx.strokeRect(x + .5, y - 22.5, tw, 17);
      lctx.fillStyle = kindInfo(n.kind).color;
      lctx.fillRect(x, y - 23, 3, 17);
      lctx.fillStyle = themeColors.labelFg;
      lctx.fillText(text, x + 8, y - 11);
    }
  }

  /* ───────────────────────── 数据加载 ───────────────────────── */

  async function loadSample(id) {
    state.sampleId = id;
    let json = window.__EMBEDDED__ && window.__EMBEDDED__[id];
    if (!json) {
      const res = await fetch('samples/' + id + '.json');
      json = await res.json();
    }
    state.data = json;
    const plot = json.meta.plot || {};
    state.page = {
      w: plot.width_px || json.meta.page_w_px || 504,
      h: plot.height_px || json.meta.page_h_px || 360,
    };
    // 兼容旧导出：根节点的 parent 可能是 NA / {} / 缺失
    state.nodes = json.nodes.map((n) => ({ ...n, parent: typeof n.parent === 'string' ? n.parent : null }));
    state.byId = new Map(state.nodes.map((n) => [n.id, n]));
    state.childrenOf = new Map();
    for (const n of state.nodes) {
      if (n.parent == null) continue;
      if (!state.childrenOf.has(n.parent)) state.childrenOf.set(n.parent, []);
      state.childrenOf.get(n.parent).push(n.id);
    }
    state.leaves = json.nodes.filter((n) => n.prims && n.prims.length).sort((a, b) => a.draw - b.draw);
    state.maxDraw = Math.max(1, ...json.nodes.map((n) => n.draw));
    state.minDraw = state.leaves.length ? state.leaves[0].draw : 0;
    state.selected = new Set();
    state.hover = null;

    $('sample-desc').textContent = (SAMPLES.find((s) => s.id === id) || {}).desc || '';
    $('stat-nodes').textContent = json.nodes.length;
    $('stat-leaves').textContent = state.leaves.length;
    $('stat-draw').textContent = state.maxDraw + 1;

    buildTree();
    buildLegend();
    build3d();
    renderSelInfo();
    renderRpath();
    // 全屏中换图：用户没手动拖过卡片的话，默认尺寸跟着新图的长宽比走
    if (focusMode && !(prefs.float2d && prefs.float2d.w)) applyFloat();
    resize2d();
    resize3d();
    viewTop();   // 换样例 = 回到「叠合的成品 + 俯视」，想看拆解再点 3D
  }

  /* ───────────────────────── 工具 ───────────────────────── */

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  const PRIM_NAME = { rect: '矩形', seg: '线段', line: '折线', poly: '多边形', pts: '点', text: '文字' };
  function primSummary(prims) {
    const c = {};
    for (const p of prims || []) c[p.t] = (c[p.t] || 0) + 1;
    return Object.keys(c).map((k) => (PRIM_NAME[k] || k) + '×' + c[k]).join(' ');
  }

  /* ───────────────────────── 样例清单 ───────────────────────── */

  // 下拉框内容：preview.html 用内嵌清单，http 下读 samples/index.json，
  // 都拿不到就退回 SAMPLES_FALLBACK（老检出/离线手改）
  async function loadSampleList() {
    let list = null;
    if (window.__EMBEDDED__ && Array.isArray(window.__EMBEDDED__.index)) {
      list = window.__EMBEDDED__.index;
    } else {
      try {
        const res = await fetch('samples/index.json', { cache: 'no-store' });
        if (res.ok) list = await res.json();
      } catch (e) { /* 没有清单 → 用内置兜底 */ }
    }
    if (!Array.isArray(list)) return;
    const clean = list.filter((s) => s && typeof s.id === 'string' && s.id !== 'index');
    if (!clean.length) return;
    SAMPLES = clean.map((s) => ({ id: s.id, name: s.name || s.label || s.id, desc: s.desc || '' }));
  }

  function fillSampleOptions() {
    const cur = select.value;
    select.textContent = '';
    for (const s of SAMPLES) {
      const o = document.createElement('option');
      o.value = s.id; o.textContent = s.name;
      select.appendChild(o);
    }
    if (SAMPLES.some((s) => s.id === cur)) select.value = cur;
  }

  /* ───────────────────────── 事件绑定 ───────────────────────── */

  function bindUI() {
    fillSampleOptions();
    select.addEventListener('change', () => loadSample(select.value));

    $('btn-top').addEventListener('click', viewTop);
    $('btn-iso').addEventListener('click', viewIso);
    $('btn-reset').addEventListener('click', () => {
      setSelection([]);
      chkIsolate.checked = false; state.isolate = false;
      lastExplode = 1; prefs.explode = 1; savePrefs();
      applyVisibility();
      viewTop();          // 重置 = 回到「叠合的成品 + 俯视」，滑杆也归零
    });
    rangeExplode.addEventListener('input', () => setExplode(parseFloat(rangeExplode.value), true));
    // change 要等松手才响一次：滑杆拖动过程中不写 localStorage
    rangeExplode.addEventListener('change', () => {
      if (lastExplode > 0) { prefs.explode = lastExplode; savePrefs(); }
    });
    chkIsolate.addEventListener('change', () => { state.isolate = chkIsolate.checked; applyVisibility(); });
    chkLabels.addEventListener('change', () => { state.showLabels = chkLabels.checked; });

    $('btn-theme').addEventListener('click', () => applyTheme(state.theme === 'light' ? 'dark' : 'light'));
    $('btn-focus').addEventListener('click', () => setFocus(!focusMode));

    // 折叠：单元标题栏、工具条、栏间把手、折叠后的竖条 —— 四处入口都汇到 toggleFold
    for (const h of document.querySelectorAll('h2.head')) {
      const owner = h.closest('[data-fold]');
      if (owner) h.addEventListener('click', () => { if (!floatDragged) toggleFold(owner.dataset.fold); });
    }
    $('btn-fold-toolbar').addEventListener('click', () => toggleFold('toolbar'));
    for (const b of document.querySelectorAll('.gutter .gbtn')) {
      b.addEventListener('click', () => toggleFold(b.parentElement.dataset.col));
    }
    for (const s of document.querySelectorAll('.col-strip')) {
      s.addEventListener('click', () => toggleFold(s.dataset.col));
    }
    $('btn-fold-all').addEventListener('click', toggleFoldAll);
    applyFold();   // 把上次存的折叠状态落到 DOM 上（<head> 里只预置了整栏，单元级在这里）

    // 栏宽：<head> 已经预置过一次（避免首帧跳宽），这里再落一次让 JS 成为唯一的写者，然后绑把手
    applyColWidths();
    bindGrips();
    bindFloat();   // 全屏悬浮卡：拖标题栏挪位置、拖右下角改大小、✕ 退出

    window.addEventListener('keydown', (ev) => {
      if (ev.target && /input|select|textarea/i.test(ev.target.tagName)) return;
      if (ev.target && ev.target.closest && ev.target.closest('.grip')) return;   // 拖拽条自己处理方向键
      if (ev.key === 'Escape') { if (focusMode) setFocus(false); else setSelection([]); }   // 全屏时 Esc 先退出全屏
      else if (ev.key === '1') viewTop();
      else if (ev.key === '2') viewIso();
      else if (ev.key === 't' || ev.key === 'T') applyTheme(state.theme === 'light' ? 'dark' : 'light');
      else if (ev.key === 'f' || ev.key === 'F') toggleFoldAll();
      else if (ev.key === 'i') {
        chkIsolate.checked = !chkIsolate.checked;
        state.isolate = chkIsolate.checked; applyVisibility();
      }
    });

    const ro = new ResizeObserver(() => { resize2d(); resize3d(); });
    ro.observe(canvas2d.parentElement);
    ro.observe(viewport);
  }

  /* ───────────────────────── 主循环与启动 ───────────────────────── */

  let lastDpr = window.devicePixelRatio || 1;
  function animate() {
    requestAnimationFrame(animate);
    const dpr = window.devicePixelRatio || 1;
    if (dpr !== lastDpr) { lastDpr = dpr; resize2d(); resize3d(); } // 换屏/改系统缩放
    controls.update();
    renderer.render(scene, camera);
    drawLabels();
  }

  // 调试钩子：供控制台排查与自动化测试使用
  window.__GTV__ = {
    state, render2d, drawPrims, loadSample, drawOverlay,
    resize2d, resize3d, zOf, setTopView, setIsoView,
    viewTop, viewIso, setExplode,
    camera: () => camera, renderer: () => renderer, group: () => group,
    applyTheme, themeColors, kindInfo, pickAt: (ev) => pick(ev),
    renderRpath, primaryId, chainOf, samplesList: () => SAMPLES,
    fold: { toggle: toggleFold, all: toggleFoldAll, apply: applyFold, state: () => foldState },
    colw: { apply: applyColWidths, set: setColWidth, reset: resetColWidth, now: colWidthNow, state: () => prefs },
    focus: { set: setFocus, is: () => focusMode, geom: floatGeom, block: () => block2d },
    explodeMemory: () => lastExplode,
  };

  init3d();
  bindUI();
  // 主题在 <head> 里已经落到 <html data-theme>，这里只是把 JS 侧的状态与 canvas/3D 颜色对齐
  applyTheme(document.documentElement.dataset.theme || 'light', true);
  animate();
  // 清单先到（决定下拉框内容），再加载第一个样例；清单拿不到时用的是内置兜底
  loadSampleList()
    .then(() => { fillSampleOptions(); return loadSample(SAMPLES[0].id); })
    .catch((e) => {
      $('sample-desc').textContent = '样例加载失败：' + e.message;
    });
})();
