# gtable 3D 拆解教学

把 ggplot2 画出的每一张图，沿 **gtable / grob** 结构拆成一层一层，用 3D 爆炸视图讲清楚「一张图到底是由哪些图层、按什么顺序叠出来的」。

纯静态站点：只有 HTML / CSS / JS / JSON，**没有后端、没有 WebR、不依赖 CDN**。R 只在离线阶段干一件事——把 `.rds` / `.RData` 导出成 JSON。

在线演示：把本目录推到 GitHub Pages 即可（见[上传到 GitHub Pages](#上传到-github-pages)）。本目录已经是可直接 push 的仓库根：带 `LICENSE`（MIT）、`.nojekyll`、`.gitignore`、`.gitattributes`，上传前跑一次 `Scripts\check_site.ps1` 自检。

---

## 快速开始

### 方式一：直接双击 `preview.html`（零依赖）

`preview.html` 是构建产物：Three.js、OrbitControls、`style.css`、main.js 和全部样例 JSON（含清单）全部内嵌在一个文件里，**双击就能看**，不需要服务器、不需要联网，也不会引用同目录的任何文件。

```powershell
# 只改了前端（main.js / 样式 / index.html）时，重建这一个文件就够
powershell -ExecutionPolicy Bypass -File Scripts/build_preview.ps1

# 用户自己丢进来的大图会把单文件版撑大；调前端时跳过超过 2 MB 的样例
powershell -ExecutionPolicy Bypass -File Scripts/build_preview.ps1 -MaxSampleMB 2

# 改了 rds/ 或导出器：双击 Scripts\run_all.bat（导出 → 校验 → 重建，见「一键重跑全部样例」）
```

### 方式二：本地起一个静态服务器

```powershell
powershell -ExecutionPolicy Bypass -File Scripts/serve.ps1                    # 默认 http://localhost:8080
powershell -ExecutionPolicy Bypass -File Scripts/serve.ps1 -Root ..           # 把父目录（整个仓库）当站点根
```

然后打开 `http://localhost:8080/`（正式版）或 `/preview.html`（单文件版）。`-Root ..` 那种用法是
为了在本机验证「从仓库根访问 → 跳转页落到 `gtableViewer/`」这条路（子目录部署就是这个形状）；
服务器会把目录请求补成 `index.html`。

> 为什么需要两种方式：`index.html` 用 ES module + `fetch()` 读 `samples/*.json`，浏览器不允许 `file://` 下的 `fetch`，所以 `index.html` 必须走 http；`preview.html` 把 JSON 内嵌了，才能双击打开。

### 方式三：只看数据

`samples/*.json` 是普通 JSON，可以直接用编辑器打开看结构。

---

## 界面与交互

```
┌──────────────┬───────────────────────────┬───────────────┐
│ 左：控制台   │ 中：3D 拆解视图           │ 右：图层树    │
│ 样例选择     │ 俯视 / 3D / 重置          │ gtable 嵌套   │
│ 2D 成品      │ 爆炸展开滑杆              │ 容器 + 叶子   │
│ 图层类别     │ 仅看选中 / 标签           │ 绘制步序      │
│ 选中元素     │ 鼠标：拖动旋转 · 滚轮缩放 │               │
│ gtable 定位  │                           │               │
└──────────────┴───────────────────────────┴───────────────┘
```

上面每一块都能单独折叠；栏与栏之间那条细把手可以**按住拖动改栏宽**（双击恢复默认），把手上的 `‹ ›` 按钮把整条左栏 / 右栏收起来；右上角「⤢ 全屏」一次收起两侧，并把 2D 成品变成视口左下角的悬浮卡（见下表最后几行）。

| 操作 | 效果 |
|---|---|
| 左侧选样例 | 加载对应的 `samples/<id>.json`，2D 成品 + 3D 图层同时重建 |
| 悬停 3D 图层 / 图层树条目 | 左侧 2D 成品上**高亮该图层的实际像素范围** |
| 点击图层 | 选中（Shift / Ctrl 多选，Esc 清空），2D 与 3D 双向联动。**按下后位移超过 4px 视为手势，不会改选中**——所以旋转视角不会把你选好的图层弄丢 |
| 右键拖动 / 中键拖动 | 平移 / 推拉缩放（`OrbitControls` 默认 `RIGHT: PAN`，右键菜单已被 preventDefault）；触屏单指旋转、双指捏合缩放 + 拖动平移 |
| 点击「图层类别」色块 | 整类选中（例如只看全部「刻度标签」） |
| 左栏「gtable 定位」 | 把选中元素在 gtable 里的位置一层层写出来：`ggplotGrob(tmp)$grobs[[6]]$children[[3]]`。面包屑**点任一级就跳到那一层**（容器会连带选中它的全部叶子），点路径或「复制」按钮把表达式拷进 R。「选中元素」列表里每个元素也各带一条路径，图层树条目悬停时同样能看到 |
| 爆炸展开滑杆 | 沿 Z 轴拉开层间距，`0` = 完全叠合成原图。手调到的非零值会被记住（`localStorage['gtv-view']`），下次点 3D 就回到它 |
| 俯视（快捷键 `1`） | 正交俯视，等价于 2D 成品；**同时把爆炸量归零**——俯视要看的本来就是叠合后的成品 |
| 3D（快捷键 `2`） | 默认机位在页面**右上方**（单位方向 `0.577, 0.307, 0.757`）：横向转掉约 37°、纵向几乎不压，顶边向右下倾斜约 13°，爆炸层往左下散开；**同时把爆炸量恢复成你上次手调的值**（没调过就是默认的 1） |
| 仅看选中 | 隐藏未选中图层 |
| 右上角「☀ 亮色 / ☾ 暗色」按钮（快捷键 `T`） | 切换明暗主题（默认白天）。只有真正点过切换才写 `localStorage['gtv-theme-v2']`，下次打开按它恢复；没点过就一直跟着默认走 |
| 点任一单元的**标题栏**（或标题栏左端的小箭头） | 折叠 / 展开这一块：样例、2D 成品、图层类别、选中元素、gtable 定位、右侧图层树、3D 工具条，七个功能单元各自独立 |
| 点栏间的 `‹ ›` **按钮** | 把**整条左栏 / 右栏**收成一条竖条，宽度全让给 3D 视口（1000px 宽的窗口实测：视口 320px → 626px，两栏都收 → 871px）。收起来以后点竖条上的「›控制台 / ‹图层树」就展开 |
| 拖栏间那条**细把手** | 改左栏 / 右栏宽度：左栏 240–720px、右栏 170–560px，并且始终给 3D 视口留够 360px，两栏不会一起把视口挤没。**双击**把手恢复默认宽度；Tab 聚焦后用方向键微调（`Shift` 加大步长）。宽度存 `localStorage['gtv-view']`，`<head>` 里的预置脚本负责刷新时不跳宽 |
| 右上角「⤢ 全屏」按钮（`Esc` 退出） | 收起左右两栏，3D 视口独占整页；「2D 成品」这块被搬进视口左下角当**悬浮卡**——拖标题栏挪位置、拖右下角改大小、卡上的 ✕ 退出全屏，位置与尺寸同样存进 `localStorage['gtv-view']`。全屏是叠在「整栏折叠」之上的一层状态（只写 `<html data-focus>`），退出就回到你原来的折叠与栏宽 |
| 右上角「⊟ 折叠全部」按钮（快捷键 `F`） | 一键收起 / 展开全部功能单元与左右两栏；按钮文字跟着变成「展开全部」 |

**折叠**：两级。**单元级**只收起标题栏下面的正文（`.block.folded .body { display: none }`，标题栏留在原地，箭头转 90°）；**栏级**把整条左栏 / 右栏收成 30px 竖条——列宽写在 `main` 的 `--w-left / --w-right` 变量上，`main.js` 只负责把状态落到 `<html data-lfold|data-rfold>`，改列宽的事全交给 CSS。状态存在 `localStorage['gtv-fold']`，`<head>` 里那段预置脚本会先把栏级状态落上去，刷新时不会「先展开再收起」跳一下。窗口窄于 1180px 时页面切成上下堆叠布局，栏级折叠没有意义，把手与竖条隐藏、已存的状态自动失效（单元级折叠仍然有效）。

**栏宽与全屏**：列宽变量分两层——`--w-*-set` 是用户拖出来的值（内联在 `<html>` 上，`:root` 那条只是默认值，内联优先），`--w-*` 是网格真正用的那个，整栏折叠时 CSS 把 `--w-*` 改成 30px，内联的 `--w-*-set` 原样留着，展开就回到他习惯的宽度。全屏（`<html data-focus="1">`）把 `main` 收成单列并隐藏两侧，再把 `#block-2d` **整个节点搬进 `#viewport`**（不是复制，`<canvas>` 和盯着它的 `ResizeObserver` 跟着节点走），加上 `.is-float` 让它变成 `position: absolute` 的悬浮卡，尺寸位置全走 `--fw/--fh/--fx/--fy` 四个变量（`x/y` 是到视口左边、下边的距离，所以窗口变高它也不会跑位）。悬浮卡拖标题栏挪位置时，落在标题栏上的那一下 `click` 会被 `floatDragged` 压掉，否则拖一次就把卡片折叠了。栏宽、悬浮卡位置、爆炸量记忆同存 `localStorage['gtv-view']`（折叠状态另存 `gtv-fold`，两者都是「阅读偏好」，不进事实层文件）。

**Z 轴的含义**：`z = (draw − minDraw) / (maxDraw − minDraw) × 2.2 × 爆炸系数`。`draw` 是 grob 在 gtable 里的实际绘制序号（按 `layout$z` 排序后的结果），所以从下往上看就是 R 真实的作画顺序；按 `minDraw` 归一化是为了让最底层正好落在 `z = 0` 的画布边框上；嵌套深度体现在图层树的缩进上。

**明暗主题**：颜色只有一份事实源——`style.css` 的 CSS 变量（`:root` 是亮色，也就是默认白天；`html[data-theme="dark"]` 整组覆盖）。canvas 和 WebGL 画不出 `var()`，所以 `main.js` 换主题时把 `--label-bg / --label-bd / --label-fg / --hl-hover / --frame-3d` 重读进 `themeColors`；类别色（`KIND`）只存原色，显示一律过 `kindInfo()`，亮色下自动压暗到 56% 亮度，否则淡黄、淡青这类色在白底上直接糊掉。**2D 成品画布永远是白的**，那是 ggplot 的 `plot.background`，不跟主题走。

**从网站回到 R 代码**（这个功能存在的理由）：在 boxplot 样例里点一层「主网格线」，左栏给出 `ggplotGrob(tmp)$grobs[[6]]$children[[1]]$children[[3]]`，于是课堂上可以直接改给学生看：

```r
g  <- ggplotGrob(tmp)
gr <- g$grobs[[6]]$children[[1]]$children[[3]]   # panel.grid.major.y
gr$gp$lwd <- 2                                   # 网站上看到的就是这一层
g$grobs[[6]]$children[[1]]$children[[3]] <- gr
grid::grid.newpage(); grid::grid.draw(g)
```

（上面这段是实测跑通的：取到的确实是 `panel.grid.major.y..polyline`，`lwd` 从 1.42 变成 2。）

---

## 目录结构

```
gtableViewer/                 # ← 这个目录本身就是仓库根，可直接推成 GitHub Pages
├── index.html              # 正式入口（ES module + import map）
├── style.css
├── main.js                 # 2D 复现 + 3D 场景 + 联动，全部逻辑
├── preview.html            # 构建产物：单文件、可 file:// 双击（已被 .gitignore 忽略）
├── LICENSE                 # MIT
├── .nojekyll               # 让 Pages 跳过 Jekyll 构建
├── .gitignore              # 挡 preview.html / Rplots.pdf 等产物
├── .gitattributes          # 锁行尾与二进制：.bat=CRLF、.R=LF、.rds=binary
├── lib/                    # Three.js r170 本地化（three.module.js + OrbitControls.js）
├── rds/                    # 源数据：.rds（ggplot / gtable）或 .RData（图束），想加图就往这里丢
├── samples/                # 前端消费的 JSON（由 rds 导出）
│   └── index.json          # 样例清单：下拉框读它，由 export_all.R 生成
└── Scripts/                # 可复现的全部脚本（供他人/其他模型重跑）
    ├── run_all.bat         # ← 双击这个：一键把 rds/ 全部转成可展示数据
    ├── run_all.ps1         # 上面那个的实体（自动找 Rscript，串起下面几步）
    ├── make_samples.R      # 生成 rds/*.rds 四个内置样例
    ├── export_all.R        # 扫描 rds/ 全部输入 → samples/*.json + index.json
    ├── export_gtable.R     # 导出器本体（也能单独当 CLI 跑，见「用自己的图」）
    ├── ref_grid.R          # 生成「R 真实渲染」的参考亮度网格
    ├── check_render.js     # 浏览器端定量比对（MAE）
    ├── check_rpath.R       # 校验每个节点的 rpath 在 R 里真能取到那个 grob
    ├── check_loaders.R     # 钉死「.rds / .RData 怎么认图、怎么取 Size」（14 例）
    ├── check_math_label.R  # 钉死 plotmath 标签的降级结果（15 例，含 bold/italic/边界）
    ├── check_site.ps1      # 上传 Pages 前的站点自检（路径/清单/编码，不碰 R）
    ├── build_preview.ps1   # 构建单文件 preview.html
    ├── serve.ps1           # 本地静态服务器
    └── .ref/               # 参考亮度网格（校验基准，行列数随画布比例推断）
```

---

## 用自己的图

**最短路径**：把图存进 `rds/` → 双击 `Scripts\run_all.bat` → 刷新页面，下拉框里就有它了。生成的只有两样东西：`samples/<id>.json`（前端读的数据）和 `samples/index.json` 里多出来的一条（下拉框的内容），**前端代码一行都不用改**。`run_all.bat` 顺带重建 `preview.html`、跑三项 R 回归和站点自检；只要数据就跑 `Rscript Scripts/export_all.R` 这一条。

丢文件之前先看三条，踩中任何一条都会「脚本跑完了，下拉框里却没有」：

| 注意 | 说明 |
|---|---|
| **文件名就是样例 id**，非 `[A-Za-z0-9_.-]` 的字符一律洗成 `_` | 所以用 ASCII 名（`myplot.rds` → id `myplot`）。`我的图.rds` 会变成 id `___`，写出的文件叫 `samples/___.json`，**而且 sidecar 也得跟着叫 `rds/___.meta.txt`**（叫 `我的图.meta.txt` 读不到，下拉框里就显示 `___`）。中文留给 sidecar 的 `name=` |
| 放在 `rds/` **顶层** | `.rds` / `.RData` / `.rda` 都收；不扫子目录 |
| 一个 id 只能有一个源文件 | `foo.rds` 与 `foo.RData` 同时存在时只导先扫到的那个，另一个打印「跳过（id 重名）」；`--list` 可以先看清楚 |

下面三步展开说。

### 1. 在 R 里把图存下来

存干净的 ggplot 对象（最常见）：

```r
tmp <- ggplot(mpg, aes(displ, hwy, colour = class)) + geom_point()
saveRDS(tmp, "rds/myplot.rds")      # 存进 gtableViewer/rds/
```

也可以丢一个**图束**进来——`save(plot, Size, file = "fig.RData")` 那种：

```r
plot <- ggplot(mpg, aes(displ, hwy)) + geom_point()
Size <- c(7, 5)                     # 画布尺寸（英寸），当初 ggsave 用的那个
save(plot, Size, file = "rds/fig.RData")
```

`.rds` 和 `.RData` **收的是同一套东西**，不按扩展名分叉：一个 ggplot / gtable，或一个 `list(Plot = <图>, Size = <画布>)` 图束（`.rds` 里存图束也认）。装载时统一按这个顺序认：

1. sidecar 里写了 `plot=`（对象名，或 `fig.Merged$Plot` 这种取值路径）就用它；
2. 否则找图束：`list(Plot = ...)` 里那个 `Plot`；
3. 否则找名字就叫 `Plot` 的可绘制对象；
4. 否则找**唯一**的那个 ggplot / gtable —— 有多个就报错让你用 sidecar 指认。

画布尺寸同理：sidecar 的 `size=` > 图束里的 `$Size` > 工作区里叫 `Size` 的对象 > 默认 `7×5` 英寸。**`Size` 只决定比例与相对大小**，网页按它的宽高比铺画布，参考图按 `Size` 英寸 + `res = 200` 光栅化（对应 R 里 `repr.plot.width/height/res` 那一组设置）。

> 拼出来的图（ggtree / patchwork 拼过多个 panel）**必须**带 `Size`：那种 gtable 的宽高整列都是 `null` 单位，它自己没尺寸。导出器遇到「没有 Size 又整列 null」会打印一条 `note` 提醒（按默认 7×5 画多半不对），不会闷头画错。

变量名随便起，但要和第 2 步 sidecar 里的 `root` 对上——网站上「gtable 定位」显示的就是 `ggplotGrob(<root>)$...`，学生照抄就能在自己的 R 会话里求值。（`.rds` 没处记变量名，一律按 `tmp` 处理。）

### 2.（可选）放一个同名 sidecar 写显示名

`rds/myplot.meta.txt`，UTF-8 **无 BOM**，一行一个 `key=value`，`#` 开头是注释：

```
name=我的散点图
desc=一句话说明这张图值得看什么
label=ggplot(mpg) + geom_point()
root=tmp
```

`name` 是下拉框里的文字，`desc` 是选中后显示的一行说明，`label` 写进 JSON 的 `meta.label`（`name` 缺省时拿它顶上），`root` 就是第 1 步那个变量名。四个键全能省——全省时下拉框直接显示文件名、根变量按 `tmp` 处理。

`.RData` 图束还可以多写三个键，用来指定「拿哪个变量、按哪个尺寸画」（不写就自动探测；`.rds` 里的图束也认这几个键）：

```
plot=fig.Merged$Plot      # 图所在的取值表达式
size=7x6.1111             # 画布宽高（英寸），写成 WxH
size_unit=cm              # in（默认）/ cm / mm / px
```

### 3. 双击 `Scripts\run_all.bat`

它会把 `rds/` 下**所有** `.rds` / `.RData` 重导成 `samples/*.json`、把清单 `samples/index.json` 刷新、跑 R 侧三项回归（装载层 / 标签降级 / rpath）、再重建单文件 `preview.html`，最后跑一遍 `check_site.ps1` 站点自检（路径写法 / 清单一致性 / 脚本编码与行尾，几秒钟）。回到浏览器刷新，下拉框里就有这张图了——**不用改前端代码**，下拉框的内容本来就是从清单读的。

不想碰 bat 的话，手工等价物（都在 `gtableViewer/` 下）：

```powershell
Rscript Scripts/export_all.R                                # rds/ 全部重导 + 刷新清单
Rscript Scripts/export_all.R --only=myplot                  # 只重导指定 id（逗号分隔）
Rscript Scripts/export_all.R --skip-fresh                   # 只导「rds 比 json 新」的
Rscript Scripts/export_all.R --clean                        # 顺带删掉没有对应 rds 的 json
Rscript Scripts/export_all.R --list                         # 只看会做什么，不动文件
```

清单永远按「`rds/` 里现有的 ∩ `samples/` 里已存在的」全量生成，所以 `--only` 局部重导不会把别的样例从下拉框里抹掉。

调试导出器本身时可以用底层单文件 CLI：

```powershell
Rscript Scripts/export_gtable.R rds/myplot.rds samples/myplot.json myplot "我的图" tmp
Rscript Scripts/export_gtable.R fig.RData samples/fig.json fig "图束" --plot=fig.Merged$Plot --size=7x6.11
```

参数依次是：输入文件（`.rds` / `.RData` / `.rda`）、输出 json、样例 id（默认取文件名）、样例显示名（默认取 id）、**根变量名**（默认 `tmp`）；`--plot=` / `--size=` / `--size-unit=` 用来覆盖自动探测。

> 画布：`.rds` 默认按 `7 × 5` 英寸（72dpi 下 504×360）解析所有相对单位，`.RData` 里的 `Size` 会顶掉这个默认值。导出器开的那台 png 设备**只用来量布局**，参数与 `ref_grid.R` 的参考图逐字一致（cairo、`res = 200`）——文字度量随设备和分辨率变（11pt 行高在 pdf / cairo@200 / cairo@72 / windows@72 下分别是 0.10969 / 0.11000 / 0.11111 / 0.12500 英寸），量错设备面板就比参考图矮两三 pt，柱子整体错位。要换测量分辨率就 `options(gtv.ref.res = ...)`，并同步重跑 `ref_grid.R`。

### 4. 增删改一张图：常见情况

| 你干了什么 | 怎么出结果 |
|---|---|
| 新丢进 `rds/myplot.rds` | 双击 `Scripts\run_all.bat`，或 `Rscript Scripts/export_all.R` → 刷新页面 |
| 只想重导新加的这一个 | `Rscript Scripts/export_all.R --only=myplot`（清单仍按全量生成，别的样例不会从下拉框里掉） |
| 改了已有 `rds/` 文件的内容（文件名没变） | 再跑一次导出，覆盖 `samples/myplot.json`；`--skip-fresh` 会跳过「json 已经比 rds 新」的 |
| 删掉 `rds/myplot.rds` | `Rscript Scripts/export_all.R --clean`：删掉孤儿 json 并从清单去掉。**五个内置样例永不删**（源文件丢了也留着成品 json） |
| 导出报「…里有多个可绘制对象（A, B），请用 sidecar 指定 `plot=`」 | 在 `rds/myplot.meta.txt` 里写 `plot=A`；`fig.Merged$Plot` 这种 `$` 路径也认 |
| 拼出来的图（ggtree / patchwork）比例不对 | 让它带上 `$Size`，或 sidecar 写 `size=7x6.11`（可选 `size_unit=cm/mm/px`）。「整列都是 null 又没 `Size`」时导出器会打印 `note`，不会闷头按 7×5 画 |
| 想知道它在 R 里渲染长什么样、好做定量比对 | `powershell -File Scripts\run_all.ps1 -Ref`（或 `Rscript Scripts/ref_grid.R myplot`）生成 `Scripts/.ref/myplot.grid.txt`。**没做基准的样例会被 `check_render.js` 自动跳过**，不会算成失败 |
| 新图 JSON 很大（几百 KB 到 MB） | 导出照常；`Scripts\run_all.bat -MaxSampleMB 2` 让单文件版 `preview.html` 跳过超限样例（内嵌清单一起裁）。网页版 `index.html` 按需 fetch，不受影响 |
| 想先看会被导成什么 id、扫不扫得到 | `Rscript Scripts/export_all.R --list`（只打印计划，不动文件） |

**要把这张新图一起发布**，在 `gtableViewer/` 下提交这几样：

- `rds/<源文件>`，外加可选的 `rds/<id>.meta.txt` —— `.RData` 已被 `.gitignore` 放行（`!rds/*.RData`），`.gitattributes` 里也标了二进制，不会被换行改写；
- `samples/<id>.json` 与刷新后的 `samples/index.json`（`check_site.ps1` 会核对两者是否一致）；
- 想让页面上的 MAE 校验也覆盖它，再带上 `Scripts/.ref/<id>.grid.txt`。

只想在线展示、不想公开源文件也可以：清单不要求 `rds/` 里有同名源文件，只提交 `samples/*.json` + `samples/index.json` 就能上线——代价是别人 clone 下来没法重新导出这张图（顺带一提，`--clean` 也不会删它）。

---

## 一键重跑全部样例

**双击 `Scripts\run_all.bat`**（会 `pause`，出错看得见）。它按顺序跑：`make_samples.R`（只在 `rds/` 空时）→ `export_all.R` → `check_loaders.R` → `check_math_label.R` → `check_rpath.R` → `build_preview.ps1` → `check_site.ps1`，任何一步非零退出就停下并报告是哪一步。

Rscript 不在 PATH 里也能跑：脚本会依次试 PATH → 注册表 `R-core\R`（HKLM / HKCU / WOW6432Node）→ `C:\Program Files\R\R-*` 按版本降序。

参数（PowerShell 里 `powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/run_all.ps1 -Samples -Ref`，bat 会把参数原样转给 ps1）：

| 参数 | 作用 |
|---|---|
| `-Samples` | 先用 `make_samples.R` 重建 `rds/*.rds`（默认只在 `rds/` 没有 rds 时才建） |
| `-Ref` | 重跑 `ref_grid.R` 生成 R 渲染基准（改了导出器、或加了新样例要做基准时） |
| `-Only scatter,hist` | 只重导指定样例 |
| `-Clean` | 删掉没有对应 rds 的孤儿 json |
| `-SkipFresh` | 只导「rds 比 json 新」的 |
| `-SkipCheck` / `-SkipPreview` / `-SkipSite` | 跳过 R 侧三项校验（`check_loaders.R` + `check_math_label.R` + `check_rpath.R`）/ 跳过构建 `preview.html` / 跳过站点自检 |
| `-MaxSampleMB 2` | 构建 `preview.html` 时跳过超过 2 MB 的样例（连清单一起裁），免得单文件版膨胀到十几 MB |
| `-Rscript <路径>` | 手动指定 `Rscript.exe` |

## 定量校验（不是"看着像"，是算出来的）

`Scripts/ref_grid.R` 用 R 把同一张图渲染成 PNG（画布 = `Size` 英寸 @ `res = 200`，也就是 1400×1000 / 1400×1222 这种），再按 72dpi 空间「每格约 6.4 px」压成**平均亮度网格**（白底，行 0 = 顶部）存进 `Scripts/.ref/`。网格行列数由画布比例决定，不写死：504×360 的样例是 79×57，216×216 的是 34×34。它默认给 `rds/` 里**所有**样例生成基准（也可以 `Rscript Scripts/ref_grid.R scatter facet` 只重做几个）。浏览器端 `Scripts/check_render.js` 加载同一份 JSON、把 2D 容器伪成同一像素预算（长边 1400）后画到 `canvas-2d`、用同样的网格采样，逐格算平均绝对误差；要查哪些样例是读 `samples/index.json` 再逐个探有没有基准，所以新加的图没做基准时会被自动跳过。

在 http 打开的页面上执行（DevTools Console，或用自动化注入）：

```js
fetch('./Scripts/check_render.js').then(r => r.text()).then(t => eval(t))
```

返回每个样例的 `mae`、误差超过 40 的格子数和热点位置。想分批跑就先设 `window.__CHECK_IDS__ = ['RepresentativeTree']` 再执行上面那句。

**判据**：`MAE ≤ 1.5` 视为与 R 渲染一致，`> 3` 说明有图元缺失或错位。

当前五个样例的实测值（0–255 尺度，`index.html` 与 `preview.html` 数值一致；`devicePixelRatio` 取 1 / 1.25 / 2 三档实测差 ≤ 0.2）：

| 样例 | 节点 / 叶子 | MAE | 误差 > 40 的格子 |
|---|---|---|---|
| scatter | 26 / 14 | 1.05 | 1 |
| boxplot | 77 / 47 | 0.79 | 0 |
| facet | 169 / 95 | 1.17 | 0 |
| hist | 23 / 11 | 1.40 | 17 |
| RepresentativeTree | 22 / 7 | 0.87 | 0 |

同一份 JSON 连跑两次数值是稳的（±0.05 以内的文字抗锯齿抖动）。但**刚打开的标签页里第一次测量会偏高约 0.15**（首帧字体度量还没稳定，之后落回真值），别把它当成回归。

四个教学样例的剩余误差几乎全部来自**字体渲染的系统差异**（R 用 cairo + DejaVu Sans，浏览器用系统字体，字宽和笔画粗细不同）以及个别文字 1–4px 的位置偏移，不是几何缺失。

`RepresentativeTree` 是用户自己丢进来的 `.RData` 图束（环状进化树，ggtree），它是**唯一一个把「MAE 高」和「有 bug」两件事同时演了一遍**的样例，值得留着当回归靶子：

- **它刚进来时 MAE 3.71 / 8 个坏格**。当时把图元按 grob 分层各算了一次墨量（同一 34×34 网格 Total ink 之比，600×600 像素预算）：整图 **1.166 倍**，其中枝干层 0.96 / 0.86、彩色环那一层 **1.317 倍**，误差全部落在环上。两个根因都在导出器：
  1. **折线的 `gp` 是按「第几条折线」回收的，不是按点**。ggtree 把 967 条环折线塞进**一个** `polylineGrob`，`gp$col` 是 967 个值（68 种颜色）；导出器整批取 `gp$col[1]`，于是所有环都变成同一种深绿（亮度 86，而 68 色的平均亮度 128）——单这一条就把整图墨量顶高三成。`segments` / `polygon` 分支早就是按组取的，只有 `polyline` 分支漏了。
  2. **丢掉了 `gp$lineend` / `gp$linejoin`**。枝干是 `lineend = "round"`，canvas 默认 `butt`，短线段的半圆帽占面积比例很大，于是枝干层反而偏淡 4~14%。图元里新增可选字段 `cap` / `join`，只在非默认值时出现。
- 两条修完：**MAE 0.87 / 0 个坏格**，五个样例全部落在 `≤1.5` 内。整图墨量比也从 1.166 回到 **1.000**（6,392,559 vs R 的 6,395,094，差 0.04%）；按 grob 分层看：彩色环 1.317 → **1.007**，枝干 0.96 → 0.984，文字 1.119（字体差异，见上）。

（历史对照，免得下次误判）改之前这一格是另一个输入：3.0 MB、96,666 条细线的 arrange 拼图，MAE 3.4，当时把格子按「含文字 / 纯线条」分开量墨量（0.978 / 1.214）判定为 **cairo 与 Skia 对亚像素线的摊墨方式差异**，不是缺图元。同一招数这次量出来的却是真 bug。**所以 MAE 偏高不能直接定性，要按 grob 逐层量墨量**：均匀偏高多半是线宽/颜色，局部偏高才是缺失或错位。


### 路径校验：`Scripts/check_rpath.R`

「gtable 定位」给出的每条 `rpath` 都必须**在 R 里真能取到网站上显示的那个 grob**，所以这项校验在 R 侧做：

```powershell
Rscript Scripts/check_rpath.R
```

对每个节点查三件事：① `rseg` 能拼回 `rpath`（`rpath == 父 rpath .. rseg`），面包屑才不会骗人；② 沿路径逐层 `[[` 取到的对象，名字（去掉末尾自增编号）和类名都与 JSON 一致；③ 抽查若干节点，把完整 `rpath` 字符串交给 `eval(parse(text = ))` 求值——这才是学生真正会做的事。当前 5 个样例 **317 个节点全部 PASS**。

---

## 上传到 GitHub Pages

这个目录**本身就是仓库根**，没有构建步骤：推上去就能开。

### 1. 上传前自检（几秒钟，不碰 R、不联网）

```
powershell -NoProfile -ExecutionPolicy Bypass -File Scripts\check_site.ps1
```

它替你踩一遍 Pages 上最容易翻车的坑：

- 站点必需文件齐不齐（含 `LICENSE`、`.nojekyll`）
- `samples/index.json` 收录的每条都能在磁盘上找到、能解析、节点数没过期（清单过期 = 下拉框 404）
- `index.html` 的 `src`/`href` 和 `main.js` 的 `fetch` 全是相对路径：不能出现 `/` 开头的根绝对路径（子路径部署会 404）、不能出现 `http(s)://`（等于吊着一条 CDN）
- 引用名与磁盘上的真实文件名**大小写完全一致**（Pages 是 Linux，`Main.js` ≠ `main.js`）
- import map 指向本地 `lib/`，且 `three.module.js` 体积正常（防半份拷贝）
- 脚本编码约定：`.ps1` 带 BOM、`.R` 不带 BOM、`.bat` 纯 ASCII + CRLF（换台机器还能跑）
- 行尾约定与 `.gitattributes` 一致：`.ps1` / `.bat` 是 CRLF，`.R` / 站点文件 / `samples/*.json` / `.ref/*.grid.txt` 是 LF（不一致的话 git 里会整篇显示成改动，跨平台重跑字节也不同）
- 有没有把 `Rplots.pdf`、`.Rhistory`、`rds/*.RData` 这类临时产物一起带上

全绿、退出码 0 再 push（警告不拦你，但值得看一眼）。（`run_all.bat` 的最后一步已经自动跑它，`-SkipSite` 才跳过。）

### 2. 推上去

```
cd gtableViewer
git init
git add .
git commit -m "gtable 3D 拆解教学"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin HEAD:main
```

Settings → Pages → Source 选 `Deploy from a branch`，分支 `main` + 目录 `/ (root)`。
约一分钟后：`https://<你的用户名>.github.io/<仓库名>/`

要跟别的小工具共用一个仓库也行：整包放进 `docs/` 或 `gtableViewer/` 子目录，
URL 变成 `https://<用户名>.github.io/<仓库名>/gtableViewer/`——所有引用都是相对路径，不用改任何配置。

比如本仓库的上级目录（`AIBook/`）就是这种「一个大仓库 + 多个子引擎」的结构：`gtableViewer/`、`Novel/`、
`TopicSeeker/` 各自独立。那种情况下仓库根再放一个**只做跳转的 `index.html`**（`meta refresh` +
`location.replace`，无依赖），访问 `https://<用户名>.github.io/<仓库名>/` 就会落到本站；根目录
的 `.nojekyll` 让 Pages 不处理整棵仓库。这两份文件在上级目录里已经备好，`gtableViewer/` 自己
推成独立仓库时它们不参与，互不影响。

> 从仓库根发布 = 把整个仓库公开（`.nojekyll` 之后 Jekyll 不再筛文件名，同级目录也一并可访问）。
> 介意 `Novel/`、`TopicSeeker/` 之类一起见光的话，就把 `gtableViewer/` 单独推一个仓库，
> 或者确认只有本站这一个子目录是你愿意公开的。

### 3. 已经备好的配套文件

| 文件 | 为什么需要 |
|---|---|
| `.nojekyll` | 让 Pages 跳过 Jekyll 阶段：纯静态站用不上它，还省得下划线开头的文件被丢掉 |
| `.gitignore` | 挡住 `preview.html`（1.5 MB 构建产物）、`Rplots.pdf`、`.Rhistory`、系统垃圾 |
| `.gitattributes` | 锁行尾与二进制：`.bat` 必须 CRLF、`.R`/站点文件必须 LF、`.rds` 按二进制处理（换行符转换会直接搞坏 rds） |
| `LICENSE` | MIT，Copyright (c) 2026 Shanjun Deng |

`preview.html` 故意没进仓库——它是 three.js 的第二份拷贝。别人 clone 之后想要，跑一次
`Scripts\build_preview.ps1` 就有；确实想连它一起发布，用 `git add -f preview.html`。

**授权范围**：代码与文档按 MIT。四个样例只用 R / ggplot2 自带数据集（`mpg`、`ToothGrowth`、
`faithful`），第五个 `RepresentativeTree.RData` 是一份 ggtree 环状进化树图束（用来演示
「图束 `list(Plot=, Size=)` + 拼出来的 gtable」这条装载路径）；`rds/` 与 `samples/*.json`
是它们的几何导出结果，随仓库一并开放。
Three.js 保持其自身 MIT 许可，随 `lib/` 原样分发。

---

## 技术要点

### JSON 结构

```jsonc
{
  "meta":   { "id": "scatter", "label": "...", "ggplot2": "4.0.3", "root_var": "tmp",
              "plot": { "width_px": 504, "height_px": 360 } },
  "nodes": [
    {
      "id": 12, "parent": 3, "name": "GRID.points.43",
      "kind": "data",                  // 图层类别，见 main.js 的 KIND
      "gclass": "points",              // grid 的 grob 类名（容器统一记作 gTree）
      "depth": 4,
      "path": "layout / panel / PANEL / geom_point.points.2",
      "rpath": "ggplotGrob(tmp)$grobs[[6]]$children[[3]]",   // 粘进 R 就能取到这个 grob
      "rseg":  "$children[[3]]",       // 相对父节点的那一步，前端用它拼面包屑
      "bbox": [x, y, w, h],            // 页面 npc，x 向右、y 向上
      "draw": 17,                      // 绘制序号，决定 Z 轴
      "prims": [ ... ]                 // 叶子才有；长度 > 0 即为叶子
    }
  ]
}
```

`rpath` 的构造规则：根是 `ggplotGrob(<root_var>)`，往下每层是 `$grobs[[i]]`（gtable 的第 i 个子 grob，`i` 取自 `layout$grob`）或 `$children[[i]]`（gTree 的第 i 个子节点）。`Scripts/check_rpath.R` 会逐节点验证它真的取到同一个对象。

样例清单 `samples/index.json` 是同一次导出的另一个产物：前端启动时先读它，再决定下拉框里有哪些样例（读不到就退回 `main.js` 里内置的兜底列表，`preview.html` 则用内嵌的那份）。

```jsonc
[
  { "id": "scatter", "name": "散点图 + 图例", "desc": "单个 panel：数据层、网格线、刻度、图例键",
    "file": "scatter.json", "nodes": 26, "leaves": 14, "kb": 14 }
]
```

`name` / `desc` 来自 sidecar 或 `export_all.R` 里的内置表；`nodes` / `leaves` / `kb` 只是给人看的体检数字，前端不读。

图元（`prims` 元素）共六种，坐标一律是**页面 npc**（0~1，y 向上）：

| `t` | 字段 | 说明 |
|---|---|---|
| `rect` | `x y w h fill fill_alpha stroke stroke_alpha lwd` | 矩形 |
| `seg`  | `xy… color alpha lwd dash cap?` | 独立线段，`xy` 两两成段 |
| `line` | `xy… color alpha lwd dash cap? join?` | 连续折线 |
| `poly` | `xy… fill stroke lwd dash` | 闭合多边形（箱体、ribbon） |
| `pts`  | `xy… size color alpha fill fill_alpha` | 点，`size` 是直径 |
| `text` | `s x y size color alpha rot hjust vjust bold italic w h` | 文字 |

`cap` / `join` 对应 grid 的 `gp$lineend` / `gp$linejoin`，**只在非默认值（`butt` / `miter`）时出现**，前端直接喂给 `ctx.lineCap` / `ctx.lineJoin`。

`lwd`、`size`、字号都是 **72dpi 下的画布像素**。

### 坐标约定

页面归一化坐标：`x` 向右、`y` **向上**，取值 0~1。R 的 grid 也是 y 向上，所以导出时不需要翻转；前端画 canvas 时才做 `canvasY = (1 - y) * height`。

### 导出器踩过的坑（改脚本前先看这里）

- **grid 的 grob 类名是复数**：`rect` / `points` / `segments` / `polygon` / `text` / `polyline` / `lines`。`segmentsGrob` 的字段是 `x0 y0 x1 y1`，不是 `xend yend`。
- **`polyline` 的 `gp` 是按「第几条折线」回收的，不是按点**：`polylineGrob` 有几条折线（`length(unique(id))`），`gp$col` / `gp$lwd` / `gp$lty` 就有几个值，**第 i 条折线取第 i 个值**。整批取 `[1]` 在 ggplot2 的图上碰不到（一个图层一根折线，gp 长度就是 1），但 ggtree 这类把上千条线塞进一个 grob 的图会全灭：环状树 967 条环折线的 68 种颜色会被刷成同一种深绿，整图墨量 1.17 倍、那一层 1.32 倍（MAE 3.71）。`segments` / `polygon` 分支本来就按组取，只有折线分支漏了。
- **`gp$lineend` / `gp$linejoin` 要带过去**：grid 默认是 `butt` + `miter`，跟 canvas 默认一致，所以平时看不出来；但 ggtree 的枝干是 `round`，丢了之后整棵树比 R 淡 4~14%（短线段上半圆帽占的面积比例很大）。导出器只在非默认值时写 `cap` / `join` 字段。
- **`rect` 的锚点由 `just` 决定，不能一律按中心算**：`panel.background` 那种是默认的 `just = "centre"`（x/y 是矩形中心），而 **`geom_col` / `geom_bar` / `geom_histogram` / `geom_tile` 生成的是 `just = c("left", "top")`**——x 是**左边**、y 是**顶边**。按中心算的话每根柱子会整体上移半个高度，柱子越高错得越多：直方图实测 MAE 33，20 根柱子画成两根通顶的黑条。正确算法是 `x_left = x - hjust·w`、`y_bottom = y - vjust·h`，`just` 既可能是数字也可能是关键字（`left`/`centre`/`right`/`bottom`/`top`），见 `just_num()`。前三个样例里只有背景矩形是 rect（柱状图的箱子其实是 `polygon`），所以这个坑要靠第 4 个样例 `hist` 才压得住。
- **`samples/index.json` 是清单不是数据**：任何枚举 `samples/*.json` 的脚本（`check_rpath.R`、`--clean` 的孤儿判定）都得把它排除掉，否则 `check_rpath.R` 会在 `index.json` 上以「`$ operator is invalid for atomic vectors`」崩掉。`check_rpath.R` 现在的判据是「不是 index 且有同名 rds」，并且按 `meta.root_var` 在独立环境里建变量再 eval，sidecar 改根变量名也不会把脚本里的 `nd`/`g` 撞掉。注意 `list.files()` 拿到的是**去掉扩展名**的 `index`，写排除条件时别写成 `index.json`。
- **`--clean` 的「孤儿」只能按「有没有同名 rds」判定**：早先的实现拿本次任务列表当白名单，于是 `--clean --only=scatter` 把 boxplot / facet / hist 连根删掉、清单也跟着只剩一个——用户只是想重导一张图。现在的判据是 `setdiff(samples 里的 id, rds 里的 id ∪ index)`，与跑没跑别的样例无关。
- **grob 名字末尾的自增编号每画一次图就变一批**：`plot.background..rect.42` 这次是 42，重新 `ggplotGrob()` 一次可能变成 103——那是 grid 的全局计数器。所以「gtable 定位」必须给**下标路径**（`$grobs[[1]]`），不能让学生按名字找；`check_rpath.R` 比较名字时也要先把末尾的 `.NNN` 去掉。
- **gtable 里子 grob 的下标在 `layout$grob`**，不是 layout 的行号（ggplot 生成的恰好相等，但按 `lay$grob` 取才是 R 里那个对象，导出的 `rpath` 也必须用同一个下标，否则学生照抄会取到别的 grob）。
- **`linesGrob` 允许 x 和 y 长度不等**（图例 key 的箱须：x 一个、y 两个），必须按 grid 的 recycling 规则补齐，否则整条线会解析成 NA 而丢失。
- **点的直径在 `grob$size`（unit）+ `gp$fontsize`**，不在 `gp$pointsize`；而且**线、点、字用的不是同一个换算口径**。cairo png 设备实测（res=100/200/400 一致）：线 `lwd × res/96`、点径 `(size + lwd) × res/96`（都是 pt 口径的 3/4，描边那一圈也算进点径）、字 `fontsize × res/72`（正常不用动）。网页把 1pt 当成 1 个 72dpi 像素，所以导出时必须把 3/4 乘进 `lwd` / `size`；不乘就是线宽直接多 1/3，**任何图元的墨量都会比 R 高三成以上**（这个偏差是全局均匀的，量一次总墨量就能认出来）。系数由 `gtv_device_k()` 拿探针实测当前设备，不写死，换 R 版本 / 平台自适应；**它必须在打开主测量设备之前调用**（探针自己开关设备）。早先那个扫参出来的 `POINT_SIZE_RATIO = 0.86`（以及中间版 0.375）都是把这个关系当魔数硬凑，已废。
- **探针必须 `pushViewport()` 之后再画**：根 vp（`grid.newpage` 直接画）下 `grid.points` 画不出东西——沿中心线扫描墨量为 0，据此标出来的 3/8 是假的，会把所有散点和图例点画小一半。
- **grob 的 `$vp` 要逐层折算成页面坐标**：grid 画的时候是 `pushViewport()` 叠出来的，JSON 里只留页面坐标才画得对。`walk()` 顶部用 `vp_rect()` 把 vp 链折成一个仿射变换，再乘到 bbox 和每条图元上（当前这号环状树输入：95 个 grob 里 7 个带 `$vp`、其中 5 个的 vp 链不是恒等，4 个 `absoluteGrob`，嵌套到第 5 层）。不折算的话挂在 vp 里的内容全留在原地。R 4.6 的 grid 已经删了 `currentViewport` / `.getViewport`，没法拿 grid 自己的 vp 栈反推，只能自己维护这条链。
- **`pch` 允许是字符**（ggtree 用 `pch = "|"` 排「字符点阵」）：这种点 R 直接按同字号文字画，实测 `points(pch='|', size=1char, lwd=0.94)` 与 `text("|")` 墨量一致，所以导出时转成 `t:"text"` 图元，不能一律画成圆点。`pch = 1` / `46`（`.`）又是另一种：直径跟 size 无关，实测 `1.44·lwd` 与 `0.72`。
- **plotmath 标签降级成纯文本**：`expression(paste(...))` 这类 label 是语言对象，网页画不了。`gtv_math_label()` 按 `deparse` 拆成文本并保留 bold / italic 近似（希腊字母名转成 Unicode：`alpha` → α、`degree` → °），上下标摊平（`x^2` → `x2`、`"PM"[2.5]` → `PM2.5`）。15 个用例（`bold`/`italic` 嵌套、`paste`、`list()`、`bgroup()`、`^`、NULL/NA/空串）钉在 `Scripts/check_math_label.R`，改函数就得跟着改期望值。
- **gp 要沿 gTree 向下继承**：图例 key glyph 的颜色挂在父 `gTree` 上，子 grob 的 gp 是空的。
- **`lty` 的判据要用 `as.character` 比较**：grid 里可能是 `1L`，`identical(1L, 1)` 是 `FALSE`，直接比会把所有实线误判成虚线。
- **gtable 的单元格名在 `node$layout$name`**，不是 `node$name`（后者是 gTree 自己的名字）。gtable 的子节点走 `$grobs`，普通 gTree 走 `$children`。
- **R 4.6 的 `convertX/convertY` 只能相对当前 viewport**，所以 gtable 的轨道几何是脚本自己算的（`resolve_tracks()`），遇到 `unit(1, "absolute")` 这类无法解析的单位会按剩余空间分配。
- **`unit(lab, "string")` 在 R 4.6 会报 "Invalid unit"**，文字宽高改用估算（平均字宽 ≈ 0.55em）。
- **`Rscript` 跑 grid 函数会自己开一个默认 pdf 设备**：`pushViewport()` / `convertX()` 要求场上有设备，没有就现开一个，于是工作目录里每次多一个 `Rplots.pdf`。`export_gtable.R` 开头一句 `pdf(NULL)` 挡掉——设备类型没变，几何与 MAE 都不受影响，只是不再往仓库里掉垃圾文件。

### 前端踩过的坑（改 main.js 前先看这里）

- **canvas 一定要显式写 CSS 尺寸。** 3D 的 WebGL canvas 只有 `position:absolute; inset:0`，没有 `width/height`。这种元素在 CSS 里取"固有尺寸 = 位图尺寸"，而位图尺寸是 `容器 × devicePixelRatio`。所以 `renderer.setSize(w, h, false)`（第三个参数 false = 不写 style）在 125% / 150% 显示缩放下会让画布比容器大一整圈并贴住左上角——3D 画面整体偏移被裁切，鼠标拾取也跟着错位。正确写法是 `renderer.setSize(w, h)`，让 three 顺手写下 `style.width/height`；标签叠加层同理（位图按 dpr 放大保清晰，CSS 尺寸锁死为容器尺寸，绘制仍用 CSS 像素）。
- **Z 轴用 `minDraw` 归一化**：`z = (draw - minDraw) / (maxDraw - minDraw) × 展开量`。若写成 `draw / maxDraw`，最底层的「画布背景」会浮在灰色画布边框上方一截，3D 斜视时白色画布和边框明显错开。归一化后最底层正好落在 `z = 0` 的边框上。
- **显示器缩放会变**：把窗口拖到另一块屏、或改系统缩放，`devicePixelRatio` 变了但 `ResizeObserver` 不会触发。`animate()` 里每帧比对一次 dpr，变了就重跑 `resize2d() + resize3d()`。
- **`PlaneGeometry` 是以本地原点为中心的**，而 `group` 已经用 `position.set(-W/2, -H/2, 0)` 把页面 (0,0) 挪到了 group 原点。所以任何"以中心建几何"的对象都要再平移到页面中心：叶子平面用 `position = bbox 中心 × world` 顺手就对了，但**画布边框**当初直接放在 `position = (0,0,0)`，结果它整体偏左下**半个页面**，只压住画布的左下角——这就是"最外圈灰色画布边框错位"的原因。现在 `frame.position.set(W/2, H/2, 0)`，与 `plot.background` 平面的世界包围盒误差 0。
- **俯视 / 3D 视角的缩放用投影包围盒反推**（`fitZoom()`：把 7×5×爆炸高度这个盒子的 8 个角 `project()` 到 NDC，再按占视口的比例反算正交 `zoom`）。之前是按 `min(w/860, h/640)` 这类经验系数估的，窗口一竖（比如左栏宽、视口窄）画布就缩成中间一小块，看着就像"画布没铺进视口"。注意 `project()` 依赖 `camera.matrixWorld`，改完位姿要先 `controls.update() + camera.updateMatrixWorld()`。
- **3D 默认机位的 y 分量必须是正的。** 正交相机 + `up = (0,1,0)` 下，`(S, T, U)` 与 `(−S, −T, U)` 投影出来的**页面四边形一模一样**（宽、高、顶边倾斜全相同），差别只在爆炸方向 `+z` 落在屏幕哪一侧：`(0.577, 0.307, 0.757)` 图层往**左下**散，`(0.577, −0.307, 0.757)` 往**右上**散，后者看着像"从桌子底下往上掀"。所以照参考图调角度时光比页面轮廓不够，还得看层往哪边飘。反推：正交投影下 `宽压缩 = U/√(S²+U²)`、`高压缩 = √(S²+U²)`、`顶边斜率 = T·S·√(S²+U²)/U`，拿参考图量到的「屏幕宽高比」和「顶边斜率」两个数就能把方向解出来（剩一个正负号，由层飘的方向定）。

- **左键不能"按下即选中"。** `OrbitControls` 的旋转也是左键，如果 `pointerdown` 里直接 `pick() + setSelection()`，那么每次转视角都会先把用户选好的图层清掉或改掉（实测拖 90×50 px 之后选中集被换掉）。标准做法是手势判定：`pointerdown` 只记起点，`pointerup` 时位移 ≤ `CLICK_SLOP`（4 CSS px）才算点击选中，超过就什么也不碰。`pointerup` 要听在同一个 canvas 上——`OrbitControls` 在 `pointerdown` 时 `setPointerCapture`，抬起事件会被重定向到 canvas，拖出视口再松手也收得到。
- **主题颜色只能有一个事实源。** 明暗两套色全在 `style.css` 的 CSS 变量里（`:root` 亮、`html[data-theme="dark"]` 覆盖），JS 侧不复制色值：`readThemeColors()` 用 `getComputedStyle().getPropertyValue()` 把 `--label-*` / `--hl-hover` / `--frame-3d` 读进 `themeColors`，因为 canvas 2D 和 WebGL 都不认 `var()`。类别色 `KIND` 只存**原色**，所有显示出口统一走 `kindInfo()`，亮色下压暗到 56%——否则 `#facc15` 这种淡黄字在白底上直接消失。另外主题初始化脚本必须放在 `<head>` 里（早于首帧），否则刷新时会先闪一下默认色；`build_preview.ps1` 只剥 `<script type="importmap">`，所以这段内联脚本能原样进 `preview.html`。**「默认白天」写在三处**（`:root` 的亮色值、`main.js` 的 `state.theme = 'light'`、`<head>` 预置脚本的 `|| 'light'` 兜底），改默认要一起改，否则首帧会闪一下。
- **`getComputedStyle` 读到的过渡中间值不是最终值。** 样式加了 `transition: background-color .2s`，切换主题后立刻读计算样式会拿到半过渡的颜色（自动化校验里容易误判成"主题没生效"），要么等 200ms 以上，要么改读 `dataset.theme` 与 CSS 变量本身。
- **`file://` 不是 secure context**，`navigator.clipboard` 在 Chrome 里直接不存在，所以「复制 rpath」必须有 `textarea + document.execCommand('copy')` 的兜底分支，否则双击 `preview.html` 的人点了按钮什么也不会发生。
- **左栏原本是 `overflow: hidden`。** 加「gtable 定位」之前它刚好铺满窗口；再加一块，矮窗口里就会被裁掉而且滚不动。现在改成 `overflow-y: auto`：`.block.grow`（2D 画布）会先被压缩，压到 `min-height` 之后才轮到整栏滚动。
- **折叠要「标题栏 + `.body`」两块，别用兄弟选择器。** 想省事写 `h2 ~ *  { display: none }` 收起的是正文没错，但 `.block.grow`（2D 画布）折叠后仍然 `flex: 1`，整栏照样被它撑住，看着就像"折叠没反应"。现在每个单元都显式包一层 `.body`，折叠只 `display:none` 掉它，再补一条 `.block.grow.folded { flex: none; min-height: 0 }`。
- **折叠后画布会掉到下限，展开时必须重量一次。** `resize2d()` 对量到的容器尺寸取 `Math.max(80, …)`，2D 单元折叠时 `.canvas-wrap` 是 `display:none`（量出来 0），画布就被定在 80×80。`bindUI` 里的 `ResizeObserver` 展开后会补一次，但 `toggleFold()` 里仍同步再跑一遍 `resize2d() + resize3d()`，免得展开那一瞬间画布还是旧尺寸。**连带一个校验坑**：`check_render.js` 是按画布位图采样的，2D 单元处于折叠状态时画布只有 80×80，MAE 会从 1.7 直接跳到 10+ ——跑定量比对前先确认 `#canvas-2d` 的 CSS 宽度不是 80px（浏览器面板被挤窄时也会踩到，此时可临时伪造 `.canvas-wrap.getBoundingClientRect()` 再 `resize2d()`）。
- **栏间把手占的是一列 0 宽度网格。** `main` 现在是五列 `var(--w-left) 0px minmax(320px,1fr) 0px var(--w-right)`，把手按钮 `position:absolute` 居中在自己那一格——0 宽度的格子正好落在 20px 栏间距的正中，所以加把手之前之后三栏的宽度完全一致。要是真给把手分出 15px，三栏就凭空各窄一截，`fitZoom()` 也得跟着重算。
- **`build_preview.ps1` 一度漏内联 `style.css`。** `<link href="./style.css">` 在 `file://` 下也能读到同目录的文件，所以本地测试看不出问题——一旦把 `preview.html` 单独拷走发给学生，页面就直接裸奔。现在构建脚本会把它塞进 `<style>`，并在写出文件**之前**自查产物有没有 `src=` / `href=` 外部引用，有就直接报错不产出文件（`data:` URI 例外：内联 SVG 图标自带字节，不算外部引用）。拿到一个现成的 preview.html 也可以自己审一遍：

  ```powershell
  # data: 是内联图标，正常；除此之外任何 src/href 都说明有东西没内联进去
  Select-String -Path preview.html -Pattern '(src|href)="([^"]*)"' |
    Where-Object { $_.Matches[0].Groups[2].Value -notmatch '^data:' }
  ```

### 已知限制

- 文字宽度是估算值，所以长标签的换行、`hjust` 贴边在极端情况下会有几个像素的偏差。
- 只处理 ggplot2 / grid 的常见 grob 类型；自定义 grob（如 `rasterGrob`、`elementRender` 生成的罕见 glyph）会被跳过，不会报错，但图层树里看不到。
- 3D 视图里容器节点（gTree / gtable）只出现在图层树中，不生成 3D 平面——只有能画出像素的叶子才变成带纹理的平面。
- clip（面板裁剪）在 2D 里按矩形近似，超出面板的数据点会被裁掉，但裁剪边界与 R 的 panel clip 可能有 1px 出入。

---

## 环境

- R ≥ 4.3（实测 R 4.6.0），需要 `ggplot2`、`gtable`、`png` 包
- 浏览器需支持 ES module 与 import map（Chrome / Edge 89+、Firefox 108+、Safari 16.4+）
- Three.js r170（已本地化）
