#!/usr/bin/env Rscript
# ============================================================================
# export_gtable.R — 把 .rds / .RData 里的图离线导出为结构化 JSON
# ----------------------------------------------------------------------------
# 用法:
#   Rscript export_gtable.R <input.rds|RData> <output.json> [sample_id] [sample_label]
#   Rscript export_gtable.R fig.RData out.json                 # 画布取自 RData 里的 Size
#   Rscript export_gtable.R fig.RData out.json fig "图" --plot=fig.Merged$Plot --size=7x6.11
#
# 吃什么输入（详见下面「输入装载」）:
#   * .rds   : saveRDS(ggplot) / saveRDS(gtable) / saveRDS(list(Plot =, Size =))
#   * .RData : save(...) 的工作区快照。认 list(Plot =, Size =) 这种图束 ——
#              Plot 是画好的图（gtable 或 ggplot），Size 是画布尺寸（英寸）；
#              有 Size 就按 Size 画（拼出来的 gtable 自己常常整列 null，没有尺寸）。
#              一个文件里有多个对象时用 sidecar 的 plot=<对象名 或 fig$Plot> 指认。
#
# 设计原则（与网页端约定）:
#   * 不在浏览器里解析 .rds —— 所有 grob 树解析都发生在这里（R 端）。
#   * 输出 JSON 描述"一张 ggplot 图由哪些 gtable 单元格按什么绘制顺序叠起来"。
#   * 坐标归一化为画布 npc: x,y ∈ [0,1]，y 轴向上（0=底部）。
#   * 每个节点 = grob 树中的一个节点；叶子带 prims（可绘制图元）。
#     网页端按 draw 顺序即可在 2D 复现成品图，并以 draw 作为 3D 的 Z 轴。
#
# 几何引擎要点（R 4.6 / grid unit_v2）:
#   * convertX/convertY 到任何单位都是"相对当前 viewport"，拿不到绝对坐标。
#   * 因此容器矩形由本脚本自行按 gtable 算法解析：
#       具体列宽 = convertWidth(相对自身 vp 的 cm)；null 列按权重分配剩余空间。
#   * 叶子图元用 convertX 到 npc（相对其单元格 vp），再映射到画布绝对坐标。
# ============================================================================

suppressPackageStartupMessages({
  library(ggplot2)
  library(gtable)
  library(grid)
  library(jsonlite)
})

# Rscript 没有图形设备，而 pushViewport()/convertX() 这类 grid 函数要求场上有设备，
# 于是 R 自作主张开一个默认 pdf 设备，把 Rplots.pdf 丢进工作目录（每跑一次就多一个垃圾文件）。
# 显式开一个空设备挡掉它。设备类型仍是 pdf，度量与之前一致，导出的几何不会变（MAE 实测不变）。
pdf(NULL)

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
`%||%` <- function(a, b) if (is.null(a)) b else a
r4 <- function(v) round(as.numeric(v), 4)

# 单个 unit 是否为纯 null；返回权重（非 null 返回 0）
null_weight <- function(u) {
  tp <- tryCatch(unitType(u), error = function(e) NA_character_)
  if (!is.na(tp) && tp == "null") {
    w <- tryCatch(as.numeric(u)[1], error = function(e) 1)
    return(if (is.na(w) || w <= 0) 1 else w)
  }
  0
}

# 解析一组 track（列宽/行高）到 cm：具体值 + null 按权重分配剩余
# units: unit 向量；total_cm: 该 gtable 自身的绝对尺寸（cm）
resolve_tracks <- function(units, total_cm) {
  n <- length(units)
  if (n == 0) return(numeric(0))
  cc <- suppressWarnings(as.numeric(convertWidth(units, "cm", valueOnly = TRUE)))
  cc <- rep_len(if (length(cc)) cc else 0, n); cc[is.na(cc)] <- 0
  wt <- vapply(seq_len(n), function(i) null_weight(units[i]), numeric(1))
  remaining <- max(total_cm - sum(cc), 0)
  if (sum(wt) > 0) cc + wt / sum(wt) * remaining else cc
}

# 行高解析（用 convertHeight）
resolve_tracks_h <- function(units, total_cm) {
  n <- length(units)
  if (n == 0) return(numeric(0))
  cc <- suppressWarnings(as.numeric(convertHeight(units, "cm", valueOnly = TRUE)))
  cc <- rep_len(if (length(cc)) cc else 0, n); cc[is.na(cc)] <- 0
  wt <- vapply(seq_len(n), function(i) null_weight(units[i]), numeric(1))
  remaining <- max(total_cm - sum(cc), 0)
  if (sum(wt) > 0) cc + wt / sum(wt) * remaining else cc
}

# 当前 vp 内：unit -> npc 数值（相对当前 vp）
npc <- function(u, what = c("x", "y", "width", "height")) {
  if (is.null(u)) return(numeric(0))
  f <- switch(match.arg(what), x = convertX, y = convertY,
              width = convertWidth, height = convertHeight)
  tryCatch(as.numeric(f(u, "npc", valueOnly = TRUE)),
           error = function(e) rep(NA_real_, length(u)))
}

gp_at <- function(gp, field, i) {
  v <- gp[[field]]
  if (is.null(v) || length(v) == 0) return(NULL)
  v[[(i - 1) %% length(v) + 1]]
}

col_split <- function(v, default = NULL) {
  if (is.null(v)) return(list(color = default, alpha = 1))
  if (length(v) == 0 || is.na(v[1])) return(list(color = NA_character_, alpha = 1))
  m <- tryCatch(col2rgb(v[1], alpha = TRUE), error = function(e) NULL)
  if (is.null(m)) return(list(color = default, alpha = 1))
  list(color = sprintf("#%02X%02X%02X", m[1, 1], m[2, 1], m[3, 1]),
       alpha = round(m[4, 1] / 255, 3))
}

# grid 的 just 既可以是数字（0~1）也可以是关键字（"left"/"top"…）。这不是可选项：
# geom_col / geom_bar / geom_histogram / geom_tile 生成的 rectGrob 用的是
# just = c("left", "top")，也就是 x 是**左边**、y 是**顶边**；panel.background 那种
# 才是默认的 centre。按中心算就会把每根柱子整体往上挪半个高度（柱子越高错得越多）。
JUST_NUM <- c(left = 0, centre = 0.5, center = 0.5, right = 1, bottom = 0, top = 1)
just_num <- function(v, default = 0.5) {
  if (is.null(v) || length(v) == 0) return(default)
  if (is.function(v) || inherits(v, "unit")) return(default)   # ggplot2 不用这两种
  if (is.numeric(v)) return(as.numeric(v)[1])
  s <- tolower(as.character(v)[1])
  if (is.na(s)) return(default)
  if (s %in% names(JUST_NUM)) JUST_NUM[[s]] else default
}

# 点的直径（换算成「72dpi 像素」，与前端 fx 同一口径）：grob$size 是 unit。
# grid 里 "char" = 当前字号，ggplot2 走的是 size = unit(1, "char") + gp$fontsize 这条路。
#
# 系数来自设备实测（见 gtv_device_k）：cairo 设备画 pch 19 时
#   直径 = (size + lwd) × res/96
# 也就是「size 的 3/4，再加一圈同样口径的描边」。探针数据（px@72dpi，模型 0.75·size + 0.75·lwd）：
#   size=20 lwd=0 → 15.12（15.00）   size=40 lwd=2 → 31.68（31.50）   size=80 lwd=10 → 66.96（67.50）
# 早期版本用扫参扫出来的 0.86 是「把两件事混成一个系数」的产物，只在大点上接近巧合；
# 中间一版误标成 3/8，是因为探针画在根 vp 下（那里 grid.points 根本不出墨），把图例点画小了一半。
point_diam_pt <- function(grob, gp, k = NULL) {
  if (is.null(k)) k <- list(size = 0.75, lwd = 0.75)
  lwd <- (gp$lwd %||% 1)[1]
  if (length(lwd) == 0 || is.na(lwd)) lwd <- 1
  diam <- function(dp) dp * k$size + lwd * k$lwd
  fs <- (gp$fontsize %||% 12)[1]
  if (length(fs) == 0 || is.na(fs)) fs <- 12
  u <- grob$size
  if (is.null(u)) return(diam(fs))
  tp <- tryCatch(unitType(u)[1], error = function(e) NA_character_)
  v <- tryCatch(as.numeric(u)[1], error = function(e) NA_real_)
  if (is.na(tp) || is.na(v)) return(diam(fs))
  dp <- switch(tp,
    char      = v * fs,
    points    = v,
    mm        = v * 2.845276,
    cm        = v * 28.45276,
    inches    = v * 72,
    "in"      = v * 72,
    pc        = v * 12,
    vjust     = fs,
    hjust     = fs,
    sum       = fs,
    relative  = fs,
    native    = fs,
    fs
  )
  diam(dp)
}

# plotmath（expression 标签）在网页里排不出来：R 会排成上下标 / 希腊字母，而 as.character()
# 只能拿到 deparse 串，直接画就露出 bold("ZF 1") 这种字面。这里把表达式走一遍解析树，
# 降级成「纯文本 + 粗斜体」：样式包装转成 bold/italic，上下标直接接上，结构函数按顺序拼接，
# 希腊字母与运算符换成 Unicode。只在标签确实是 plotmath（本身是 expression，或 deparse 串
# 形如「函数("…"）」）时才动手，普通标签（如 "Dose (mg)"）原样放过。
gtv_math_label <- function(lab, force = FALSE) {
  if (is.expression(lab) && length(lab)) lab <- lab[[1]]
  s0 <- tryCatch(as.character(lab)[1], error = function(e) "")
  if (length(s0) == 0 || is.na(s0)) s0 <- ""
  is_lang <- is.name(lab) || is.call(lab)
  if (!isTRUE(force) && !is_lang) {
    if (!(grepl("^ *[a-zA-Z]+ *\\(", s0) && grepl('"', s0, fixed = TRUE)))
      return(list(s = s0, bold = FALSE, italic = FALSE))
    lab <- tryCatch(parse(text = s0)[[1]], error = function(e) NULL)
    if (is.null(lab)) return(list(s = s0, bold = FALSE, italic = FALSE))
  }
  sym <- list(alpha = "α", beta = "β", gamma = "γ", Gamma = "Γ", delta = "δ", Delta = "Δ",
    epsilon = "ε", zeta = "ζ", eta = "η", theta = "θ", Theta = "Θ", iota = "ι", kappa = "κ",
    lambda = "λ", Lambda = "Λ", mu = "μ", nu = "ν", xi = "ξ", Xi = "Ξ", pi = "π", Pi = "Π",
    rho = "ρ", sigma = "σ", Sigma = "Σ", tau = "τ", upsilon = "υ", phi = "φ", Phi = "Φ",
    chi = "χ", psi = "ψ", Psi = "Ψ", omega = "ω", Omega = "Ω", degree = "°", times = "×",
    cdot = "·", div = "÷", pm = "±", mp = "∓", infinity = "∞", partial = "∂", nabla = "∇",
    forall = "∀", exists = "∃", emptyset = "∅", ldots = "…", dots = "…", ldotsdot = "…",
    rightarrow = "→", leftarrow = "←", Rightarrow = "⇒", Leftrightarrow = "⇔",
    subset = "⊂", subseteq = "⊆", superset = "⊃", superseteq = "⊇", sqrt = "√")
  st <- new.env(parent = emptyenv()); st$bold <- FALSE; st$italic <- FALSE
  rec <- function(e) {
    if (is.null(e)) return("")
    if (is.character(e)) return(paste(e, collapse = ""))
    if (is.numeric(e)) return(format(e))
    if (is.name(e)) {
      n <- as.character(e)
      if (!nzchar(n)) return("")
      return(if (!is.null(sym[[n]])) sym[[n]] else n)
    }
    if (!is.call(e)) return(paste(as.character(e), collapse = ""))
    f <- tryCatch(as.character(e[[1]])[1], error = function(err) "")
    a <- as.list(e)[-1]
    one <- function(i) if (length(a) >= i) rec(a[[i]]) else ""
    all <- function(sep) paste(vapply(a, rec, character(1)), collapse = sep)
    switch(f,
      bold = { st$bold <- TRUE; one(1) },
      italic = { st$italic <- TRUE; one(1) },
      bolditalic = { st$bold <- TRUE; st$italic <- TRUE; one(1) },
      plain = one(1),
      paste = all(" "),
      paste0 = all(""),
      list = all(", "),
      group = , bgroup = , egroup = , `(` = one(1),
      `^` = , `_` = , script = , scripts = , supscript = , sup = , sub = , phantom =
        paste0(one(1), one(2)),
      `*` = paste0(one(1), one(2)),
      `~` = , `~~` = , `+` = paste0(one(1), " ", one(2)),
      `-` = if (length(a) == 1) paste0("-", one(1)) else paste0(one(1), " - ", one(2)),
      `==` = paste0(one(1), "=", one(2)),
      `<=` = paste0(one(1), "≤", one(2)),
      `>=` = paste0(one(1), "≥", one(2)),
      `!=` = paste0(one(1), "≠", one(2)),
      `/` = , over = , atop = paste0(one(1), "/", one(2)),
      sqrt = paste0("√(", one(1), ")"),
      all("")
    )
  }
  out <- tryCatch(rec(lab), error = function(err) s0)   # 解析不动就退回 deparse 原串
  if (length(out) != 1 || is.na(out) || !nzchar(out)) out <- s0
  list(s = gsub("\\s+", " ", trimws(out)), bold = isTRUE(st$bold), italic = isTRUE(st$italic))
}

# gp 继承：grid 的 gTree 可以带 gp，子 grob 的 gp 为空时向上继承
# （ggplot2 的图例 key glyph 就是这么上色的：GRID.gTree.N 带 col/fill，子 rect/lines 全空）
merge_gp <- function(parent_gp, gp) {
  if (is.null(parent_gp) || length(parent_gp) == 0) return(gp)
  if (is.null(gp) || length(gp) == 0) return(parent_gp)
  out <- gp
  for (nm in names(parent_gp)) if (is.null(out[[nm]])) out[[nm]] <- parent_gp[[nm]]
  out
}

lty_is_dash <- function(lty) {
  if (is.null(lty) || length(lty) == 0) return(FALSE)
  # grid 的 lty 可能是 integer 1L、numeric 1、"1"、"solid"、"blank"、"dashed"…
  s <- as.character(lty)[1]
  if (is.na(s)) return(FALSE)
  if (s %in% c("0", "blank")) return(NA)      # 不画
  if (s %in% c("1", "solid")) return(FALSE)   # 实线
  TRUE                                        # 其余按虚线
}

# 线端与拐角：grid 默认 lineend = "butt"、linejoin = "miter"，与 canvas 的默认值一致，
# 所以只有非默认值才写进 JSON。ggtree 的枝干是 round 端头 + round 拐角，按默认值画
# 会让整棵树比 R 淡 4~14%（短线段上半圆帽占的面积比例很大，实测墨量 0.86 倍）。
gtv_cap <- function(v) {
  if (is.null(v) || length(v) == 0) return(NULL)
  s <- tolower(as.character(v)[1])
  if (is.na(s) || s == "butt") NULL else if (s %in% c("round", "square")) s else NULL
}
gtv_join <- function(v) {
  if (is.null(v) || length(v) == 0) return(NULL)
  s <- tolower(as.character(v)[1])
  if (is.na(s) || s == "miter") NULL else if (s %in% c("round", "bevel")) s else NULL
}

# ---------------------------------------------------------------------------
# kind 分类
# ---------------------------------------------------------------------------
ctx_for_cell <- function(cell_name, parent_ctx) {
  kind <-
    if (grepl("^background", cell_name)) "background"
    else if (identical(cell_name, "panel")) "panel"
    else if (grepl("^axis", cell_name)) "axis"
    else if (grepl("^(xlab|ylab)", cell_name)) "axis-title"
    else if (grepl("^strip", cell_name)) "strip"
    else if (grepl("^guide", cell_name)) "legend"
    else if (identical(cell_name, "title")) "title"
    else if (identical(cell_name, "subtitle")) "subtitle"
    else if (identical(cell_name, "caption")) "caption"
    else if (identical(cell_name, "spacer")) "spacer"
    else parent_ctx$kind
  list(kind = kind)
}

leaf_kind <- function(ctx, grob_name, has_text) {
  g <- grob_name %||% ""
  switch(ctx$kind,
    panel = {
      if (grepl("panel\\.background", g)) "panel-bg"
      else if (grepl("panel\\.grid\\.major", g)) "grid-major"
      else if (grepl("panel\\.grid\\.minor", g)) "grid-minor"
      else if (grepl("panel\\.border", g)) "panel-border"
      else "data"
    },
    axis   = if (has_text) "tick-labels" else "axis-marks",
    legend = if (has_text) "legend-text" else "legend-key",
    strip  = if (has_text) "strip-text" else "strip-bg",
    ctx$kind
  )
}

# ---------------------------------------------------------------------------
# 设备标定：R 画「线」和「点」用的不是 1pt = res/72 px
# ---------------------------------------------------------------------------
# 实测（cairo png 设备，res=100 / 200 / 400 结果一致，且必须在 viewport 里画，见下）：
#   线   gp$lwd      → 设备像素 = lwd            × res/96   （pt 口径的 3/4）
#   点   size + lwd  → 设备像素 = (size + lwd)   × res/96   （同一个 3/4，描边那一圈也算进去）
#   字   gp$fontsize → 设备像素 = fontsize       × res/72   （正常，不用动）
# 点径实测（vp 内，px@72dpi，模型 = 0.75·size + 0.75·lwd）：
#   size=20 lwd=0 → 15.12（15.00）   size=40 lwd=2 → 31.68（31.50）   size=80 lwd=10 → 66.96（67.50）
# 网页端把 1pt 当成 1 个 72dpi 像素，所以导出时必须把这个系数乘进 lwd / size，
# 否则同一份 grob 在网页里会比 R 深四成：RepresentativeTree 用同一像素预算实测
# 墨量 1.41 倍（线 1.42、填充 1.46、文字 1.14），差异铺满整张图，不是几何错位。
#
# 【坑】探针必须 pushViewport 之后再画。根 vp（grid.newpage 直接画）下 grid.points
# 画不出东西 —— 实测沿中心线扫描墨量为 0，据此标出来的 3/8 是假的，会把所有散点
# 和图例点画小一半（图例点实测 R 24px、网页 13px，右上图例区墨量只剩 46%）。
# 系数不写死 —— 拿两个探针实测当前设备，换 R 版本 / 换平台能自适应；探针失败才兜底。
gtv_device_k <- function(res = 200L) {
  k <- list(lwd = 0.75, size = 0.75)    # 兜底值 = 本机 R 4.6 的实测值
  probe <- function(expr, axis, expect) {
    f <- tempfile(fileext = ".png")
    # 画布必须容得下探针：res=400 时 80pt 的圆有 444px 直径，小画布会把它裁掉
    side <- max(400L, round(3 * expect))
    dev_id <- NA_integer_
    got <- tryCatch({
      grDevices::png(f, width = side, height = side, res = res, bg = "white", type = "cairo")
      dev_id <- grDevices::dev.cur()
      grid.newpage(); pushViewport(viewport()); force(expr); popViewport()
      invisible(grDevices::dev.off())
      m <- png::readPNG(f)
      L <- 0.299 * m[, , 1] + 0.587 * m[, , 2] + 0.114 * m[, , 3]
      # 只数「穿过对象中心的那条线」上过半覆盖的像素：
      #   阈值 0.5 = 过半覆盖，累计长度正好等于几何宽度（抗锯齿两边各补一半）；
      #   走中心线而不是算总墨量，是因为线端帽（圆头 / 方头）会额外糊上一坨墨，
      #   实测把 lwd=20 的表观宽度从 41.7px 抬到 45.3px —— 那是端点，不是线宽。
      dark <- function(v) sum(v < 0.5)
      mid <- if (axis == "row") nrow(L) %/% 2 else ncol(L) %/% 2
      # 水平线：竖着切一刀数行数；实心圆：横着切一刀数列数。各取三刀平均压噪声。
      off <- c(-1, 0, 1)
      v <- if (axis == "row") mean(vapply(off, function(d) dark(L[, mid + d]), numeric(1)))
           else                mean(vapply(off, function(d) dark(L[mid + d, ]), numeric(1)))
      if (is.finite(v) && v > 0) v / expect else NA_real_
    }, error = function(e) NA_real_, finally = {
      # 只关探针自己开的那个设备。以前这里是一句无参 dev.off()，它会把文件开头
      # 那个 pdf(NULL) 也关掉 —— 非交互 Rscript 下「没有设备时画东西」会自动
      # 生成 Rplots.pdf，于是每跑一次导出就在仓库里掉一个垃圾文件。
      if (!is.na(dev_id) && dev_id %in% grDevices::dev.list())
        try(grDevices::dev.off(dev_id), silent = TRUE)
      if (!length(grDevices::dev.list())) pdf(NULL)   # 兜底：保证场上永远有无害设备
      unlink(f)
    })
    if (is.finite(got) && got > 0.05 && got < 2) got else NA_real_
  }
  # 探针 1：lwd=20 的水平线，按 pt 口径应有 20·res/72 px 粗（在 x=0.5 处竖切）
  k$lwd  <- probe(grid.segments(0.05, 0.5, 0.95, 0.5, gp = gpar(lwd = 20, col = "black")),
                  "col", 20 * res / 72)
  # 探针 2：size=80pt、不描边的实心圆，按 pt 口径应有 80·res/72 px 直径（在 y=0.5 处横切）
  k$size <- probe(grid.points(0.5, 0.5, pch = 19, size = unit(80, "points"),
                              gp = gpar(col = "black", fill = "black", lwd = 0)),
                  "row", 80 * res / 72)
  if (!is.finite(k$lwd))  k$lwd  <- 0.75
  if (!is.finite(k$size)) k$size <- 0.75
  k
}

# 「量布局」用的设备必须和参考图（Scripts/ref_grid.R）是同一台：文字度量随设备与
# 分辨率变。本机 R 4.6 实测 11pt 行高：pdf(NULL) 0.10969in、cairo@res200 0.11000in、
# cairo@res72 0.11111in、windows@res72 0.12500in；标题 "Old Faithful"@13.2pt 宽度
# cairo@200 比 pdf 宽 1.7%。gtable 的行高是文字撑出来的，量错设备面板就比参考图矮
# 2~3 pt、左边缩 1 pt，整块内容跟着错位（hist 的柱子底边差 3.7px@res200，MAE 虚高）。
gtv_ref_res <- function() as.integer(getOption("gtv.ref.res", 200L))

# ---------------------------------------------------------------------------
# 输入装载：.rds 与 .RData 走同一条路
# ---------------------------------------------------------------------------
# 学生交上来的东西只有两种形态：
#   A) 一个可绘制对象        .rds 里 saveRDS(ggplot) / saveRDS(gtable)
#   B) 一个图束 list         list(Plot = <画好的图>, Size = c(w, h))
#      ggtree / patchwork 拼过多 panel 之后基本都存成这样
#      （save(plot, Size, file = "fig.RData")）。画布尺寸只有 Size 知道：
#      拼出来的 gtable 宽高常常整列都是 null 单位，它自己没尺寸。
# 形态 A / B 在 .rds 和 .RData 里都可能出现（.rds 里存 list 的也不少），所以这里
# 不按扩展名分叉，统一成三步：
#   ① 把文件摊进一个环境（.RData = 整个工作区；.rds = 一项，名字固定 tmp）
#   ② 从环境里认出那张图：sidecar 的 plot= > 图束的 $Plot > 叫 Plot 的 > 唯一的可绘制对象
#   ③ 顺着同一份图束取 $Size；没有就看环境里叫 Size 的；再没有才用默认 7x5
#
# gtv_load_input() 返回 list(obj, kind, root_var, root_expr, size_in, size_src, source, bundle)
#   obj       : ggplot 对象，或已经画好的 grob/gtable
#   kind      : "ggplot"（还要 build）| "grob"（直接 grid.draw）
#   root_var  : 学生 R 会话里那个变量的名字（写进 meta.root_var）
#   root_expr : 学生能直接粘进 R 的根表达式，如 ggplotGrob(tmp)、fig.Merged$Plot
#   size_in   : 画布尺寸（英寸），c(w, h)
#   size_src  : "Size" | "Size(按 px 理解)" | "sidecar" | "default"
#   source    : "rds" | "rdata"
#   bundle    : 图束那个 list（$Size 的出处），不是图束就是 NULL
# ---------------------------------------------------------------------------

# 可绘制的东西：ggplot 对象，或者已经画好的 grob / gTree
is_drawing_obj <- function(x) inherits(x, c("ggplot", "grob", "gTree"))

# 图束：list(Plot = <可绘制对象>)。名字必须叫 Plot —— 不认 list(g = ...) 那种，
# 免得把 list(x = ..., y = ...) 之类的普通数据误当成一张图。
is_plot_bundle <- function(x) {
  is.list(x) && !is.null(names(x)) && "Plot" %in% names(x) && is_drawing_obj(x[["Plot"]])
}

# gtable 的宽/高里有没有「绝对单位」。拼出来的图（ggtree / patchwork）常常整列是
# null 单位：那种 gtable 没有 Size 就画不出正确大小，装载时要提醒一句。
# 注意必须按下标取（u[i]），不能直接 vapply(u, ...) —— 对 unit_v2 直接迭代时
# null_weight() 会对每个元素判成 0（实测 vapply(u,..) = 0,0 而 u[i] = 1,1），
# 于是「整列 null」会被误判成「有绝对尺寸」。
gtv_has_intrinsic_size <- function(g) {
  if (!inherits(g, "gtable")) return(TRUE)
  fixed <- function(u) length(u) > 0 &&
    any(vapply(seq_along(u), function(i) null_weight(u[i]), numeric(1)) == 0)
  fixed(g$widths) && fixed(g$heights)
}

# 单位 → 英寸（"in" 是 R 的关键字，所以这里用命名向量而不是 switch）
to_inches <- function(v, unit = "in") {
  u <- tolower(sub("\\.$", "", unit))
  k <- c(`in` = 1, inch = 1, inches = 1,
         cm = 1 / 2.54, mm = 1 / 25.4, m = 100 / 2.54,
         px = 1 / 72, dpi = 1 / 72, pt = 1 / 72, points = 1 / 72, pc = 1 / 12)
  if (!(u %in% names(k))) stop("不认识的 size_unit: ", unit, "（可用 in/cm/mm/px/pt）")
  as.numeric(v) * k[[u]]
}

# 把 Size 归一成英寸两位数。
# 自动兜底：数值大得离谱（>100）时按像素理解 —— 504x440 这种是 px，不是 504 英寸。
norm_size <- function(v, unit = "in", src = "Size") {
  # Size 有时是个 unit 对象（unit(c(3, 3), "in")）—— 那就用它自带的单位，比 sidecar 里的准
  if (inherits(v, "unit")) {
    u <- tryCatch(unitType(v)[1], error = function(e) NA_character_)
    if (length(u) == 1 && !is.na(u)) { unit <- u; v <- as.numeric(v) }
  }
  v <- suppressWarnings(as.numeric(unlist(v)))
  v <- v[is.finite(v)]
  if (length(v) < 2) return(NULL)
  v <- v[1:2]
  if (any(v <= 0)) return(NULL)
  if (tolower(sub("\\.$", "", unit)) == "in" && max(v) > 100) {
    v <- v / 72
    list(size = v, src = paste0(src, "(按 px 理解)"))
  } else {
    list(size = to_inches(v, unit), src = src)
  }
}

# sidecar 里写的 size="7x6.11" / "7,6.11" / "504 440"
parse_size_str <- function(s, unit = "in") {
  if (is.na(s) || !nzchar(s)) return(NULL)
  nums <- regmatches(s, gregexpr("[-+]?[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?", s))[[1]]
  if (length(nums) < 2) stop("size 需要两个数，例如 size=7x6.11（收到: ", s, "）")
  list(size = to_inches(as.numeric(nums[1:2]), unit), src = "sidecar")
}

# 从装载环境里认出「那张图」。plot 是 sidecar 里的指定（对象名，或 fig$Plot 这种 $ 路径）。
# 顺序：sidecar 指定 → 图束的 $Plot → 叫 Plot 的可绘制对象 → 唯一的可绘制对象。
# 返回 list(obj, expr, var, bundle)：bundle 是 $Size 可能所在的那层 list（没有就是 NULL）。
gtv_pick_plot <- function(e, nms, plot = NA_character_, what = "输入") {
  getv <- function(n) get(n, envir = e)
  if (!is.na(plot) && nzchar(plot)) {
    # 路径直接求值，所以 [[1]] 这种下标写法也能用
    o <- tryCatch(eval(parse(text = plot), envir = e), error = function(err) NULL)
    if (is.null(o))
      stop(what, " 里找不到 plot=", plot, "（文件里的对象有: ", paste(nms, collapse = ", "), "）")
    first <- strsplit(plot, "$", fixed = TRUE)[[1]][1]
    holder <- tryCatch(eval(parse(text = first), envir = e), error = function(err) NULL)
    return(list(obj = o, expr = plot, var = first,
                bundle = if (is_plot_bundle(holder)) holder else NULL))
  }
  # 1) 图束：list(Plot = <可画的>)，画布尺寸在同层的 $Size
  bundles <- Filter(function(n) is_plot_bundle(getv(n)), nms)
  if (length(bundles)) {
    n <- bundles[1]
    if (length(bundles) > 1)
      cat("   note: ", what, " 里有多个图束（含 $Plot 的 list）：", paste(bundles, collapse = ", "),
          "，取第一个 ", n, "；要换用 sidecar 的 plot=\n", sep = "")
    return(list(obj = getv(n)[["Plot"]], expr = paste0(n, "$Plot"), var = n, bundle = getv(n)))
  }
  # 2) 顶层就叫 Plot 的可绘制对象
  if ("Plot" %in% nms && is_drawing_obj(getv("Plot")))
    return(list(obj = getv("Plot"), expr = "Plot", var = "Plot", bundle = NULL))
  # 3) 唯一的 ggplot / grob
  drawables <- Filter(function(n) is_drawing_obj(getv(n)), nms)
  if (length(drawables) == 1L)
    return(list(obj = getv(drawables), expr = drawables, var = drawables, bundle = NULL))
  if (length(drawables) > 1L)
    stop(what, " 里有多个可绘制对象（", paste(drawables, collapse = ", "),
         "），请用 sidecar 指定 plot=<对象名或 $路径>")
  stop(what, " 里没有 ggplot / gtable 对象（对象有: ", paste(nms, collapse = ", "), "）")
}

# 画布尺寸：sidecar 的 size= > 图束里的 $Size > 环境里叫 Size 的对象 > NULL（交给默认值）
gtv_pick_size <- function(e, nms, bundle, size = NA_character_, size_unit = "in") {
  side <- parse_size_str(size, size_unit)
  if (!is.null(side)) return(side)
  if (!is.null(bundle) && !is.null(bundle[["Size"]])) {
    sz <- norm_size(bundle[["Size"]], size_unit, "Size")
    if (!is.null(sz)) return(sz)
  }
  if ("Size" %in% nms) {
    sz <- norm_size(get("Size", envir = e), size_unit, "Size")
    if (!is.null(sz)) return(sz)
  }
  NULL
}

gtv_load_input <- function(path, plot = NA_character_, size = NA_character_,
                           size_unit = "in", root_var = NULL) {
  if (!file.exists(path)) stop("输入文件不存在: ", path)
  # 调用方常用 NA 表示「没指定」，这里统一成 NULL，免得到处 %||% 漏掉 NA
  if (is.null(root_var) || (length(root_var) == 1 && is.na(root_var))) root_var <- NULL
  ext <- tolower(tools::file_ext(path))
  from_rdata <- ext %in% c("rdata", "rda", "image")
  what <- if (from_rdata) "RData" else basename(path)

  # 两种输入都先摊进一个环境：.RData 是整个工作区，.rds 只有一项（名字 tmp，
  # 跟学生 saveRDS 时用的变量名无关）。这样 .rds 里存 list(Plot=, Size=) 也认。
  e <- new.env(parent = globalenv())
  if (from_rdata) load(path, envir = e) else assign("tmp", readRDS(path), envir = e)
  nms <- ls(e, all.names = TRUE)

  hit <- if (from_rdata || !is.na(plot)) {
    gtv_pick_plot(e, nms, plot, what)
  } else tryCatch(gtv_pick_plot(e, nms, plot, what), error = function(err)
    stop("rds 里不是 ggplot / gtable 图束：", basename(path),
         "（class = ", paste(class(e$tmp), collapse = "/"), "）", call. = FALSE))

  # 选中图束时，顺带说一句还有别的可画对象可以换（学生手里的文件常常一堆中间产物）
  if (!is.null(hit$bundle)) {
    others <- setdiff(Filter(function(n) is_drawing_obj(get(n, envir = e)), nms), hit$var)
    if (length(others))
      cat("   note: ", what, " 里还有可绘制对象：", paste(others, collapse = ", "),
          "；要换用 sidecar 的 plot=\n", sep = "")
  }

  sz <- gtv_pick_size(e, nms, hit$bundle, size, size_unit)
  if (is.null(sz)) {
    # 没有 Size：默认 7x5 只对「自己就有绝对尺寸」的图成立。拼出来的 gtable 整列
    # 都是 null 单位，按默认画会明显不对，这种要提醒（安静地画错比报错更糟）。
    if (!gtv_has_intrinsic_size(hit$obj))
      cat("   note: ", what, " 里没找到 Size，而这张 gtable 的宽高全是 null 单位 —— ",
          "只能按默认 7x5 英寸画，多半不对；请让它带上 $Size，或用 sidecar 的 size=WxH\n", sep = "")
    sz <- list(size = c(7, 5), src = "default")
  }

  kind <- if (inherits(hit$obj, "ggplot")) "ggplot" else "grob"
  # ggplot 对象要 build；已经是 gtable 就直接用。根表达式就是学生手里的取值式。
  list(obj = hit$obj, kind = kind, root_var = root_var %||% hit$var,
       root_expr = if (kind == "ggplot") paste0("ggplotGrob(", hit$expr, ")") else hit$expr,
       size_in = sz$size, size_src = sz$src,
       source = if (from_rdata) "rdata" else "rds",
       bundle = hit$bundle)
}

# ---------------------------------------------------------------------------
# 主导出函数
# ---------------------------------------------------------------------------
export_gtable <- function(rds_path, json_path, sample_id = "plot",
                          sample_label = "ggplot", size_in = NULL, dpi = 72,
                          root_var = NULL, plot = NA_character_,
                          size = NA_character_, size_unit = "in") {
  src <- gtv_load_input(rds_path, plot = plot, size = size,
                        size_unit = size_unit, root_var = root_var)
  if (is.null(size_in)) size_in <- src$size_in
  size_in <- as.numeric(size_in)[1:2]

  # ggplot 要先 build；.RData 里那种 $Plot 已经是拼好的 grob 树，直接拆
  if (src$kind == "ggplot") {
    b <- ggplot_build(src$obj)
    g <- ggplot_gtable(b)
    panel_params <- b$layout$panel_params
  } else {
    g <- src$obj
    panel_params <- list()   # 成品 gtable 里没有 panel_params，前端也不用它
  }

  # 画布像素：Size 给的是英寸，72dpi 下 7 x 6.1111 就是 504 x 440（取整，前端按这个数摆画布）
  W_px <- round(size_in[1] * dpi)
  H_px <- round(size_in[2] * dpi)
  Wcm <- size_in[1] * 2.54
  Hcm <- size_in[2] * 2.54

  tmp_png <- tempfile(fileext = ".png")
  dev_k <- gtv_device_k()   # 必须在打开主设备之前标定：探针自己开关设备
  # 这台设备只用来「量」布局，不产出图片；参数必须与 ref_grid.R 的参考图逐字一致
  ref_res <- gtv_ref_res()
  dev_args <- list(file = tmp_png, width = round(size_in[1] * ref_res),
                   height = round(size_in[2] * ref_res), res = ref_res, bg = "white")
  if (isTRUE(capabilities("cairo"))) dev_args$type <- "cairo"
  do.call(grDevices::png, dev_args)
  on.exit({ grDevices::dev.off(); unlink(tmp_png) }, add = TRUE)
  grid.newpage()

  nodes <- list()
  n_counter <- 0L
  draw_counter <- 0L

  # rpath = 从根对象出发的完整 R 取值表达式（学生可直接粘进 R）
  # rseg  = 相对父节点的那一段，如 "$grobs[[15]]"，前端用它拼面包屑
  add_node <- function(name, kind, gclass, depth, parent, bbox, path, rpath, rseg, prims) {
    n_counter <<- n_counter + 1L
    draw_counter <<- draw_counter + 1L
    id <- paste0("n", n_counter)
    nodes[[id]] <<- list(
      id = id, parent = if (is.null(parent)) NA_character_ else parent, name = name %||% "", kind = kind,
      gclass = gclass, depth = depth, path = path, rpath = rpath, rseg = rseg,
      bbox = list(r4(bbox[1]), r4(bbox[2]), r4(bbox[3]), r4(bbox[4])),
      draw = draw_counter,
      prims = if (length(prims)) prims else list()
    )
    id
  }

  # ---- 图元提取：在当前 vp（= 叶子所在单元格）内把 unit 转 npc 再映射到画布 ----
  # cell = c(x, y, w, h) 画布绝对 npc
  extract_prims <- function(grob, cell, pgp = NULL) {
    prims <- list()
    gp <- merge_gp(pgp, grob$gp)
    if (is.null(gp)) gp <- gpar()
    cls <- class(grob)
    ax <- function(v) cell[1] + v * cell[3]
    ay <- function(v) cell[2] + v * cell[4]
    sc <- W_px / (size_in[1] * 72)  # pt -> px 画布比例（dpi=72 时为 1）
    # 线宽另乘设备系数：R 的 cairo 设备按 res/96 画线，网页按 res/72 画，不乘就比 R 粗 1/3
    sc_lwd <- sc * dev_k$lwd

    if ("rect" %in% cls) {
      xs <- npc(grob$x, "x"); ys <- npc(grob$y, "y")
      ws <- npc(grob$width, "width"); hs <- npc(grob$height, "height")
      # 锚点：hjust=0 表示 x 就是左边，vjust=1 表示 y 就是顶边（见 just_num 的注释）
      jh <- just_num(grob$hjust %||% grob$just[1])
      jv <- just_num(grob$vjust %||% grob$just[2])
      n <- max(length(xs), length(ys), 1)
      for (i in seq_len(n)) {
        x <- xs[[(i - 1) %% length(xs) + 1]]; y <- ys[[(i - 1) %% length(ys) + 1]]
        w <- ws[[(i - 1) %% length(ws) + 1]]; h <- hs[[(i - 1) %% length(hs) + 1]]
        if (is.na(x) || is.na(y) || is.na(w) || is.na(h)) next
        fill <- col_split(gp_at(gp, "fill", i), NULL)
        stroke <- col_split(gp_at(gp, "col", i), NULL)
        prims[[length(prims) + 1]] <- list(
          t = "rect", x = r4(ax(x - jh * w)), y = r4(ay(y - jv * h)),
          w = r4(w * cell[3]), h = r4(h * cell[4]),
          # col_split 在 gp 缺字段时返回 color=NULL；NA 经 na="null" 会变成 JSON null
          fill = fill$color %||% NA_character_, fill_alpha = fill$alpha,
          stroke = stroke$color %||% NA_character_, stroke_alpha = stroke$alpha,
          lwd = r4((gp_at(gp, "lwd", i) %||% 1) * sc_lwd)
        )
      }
    }
    # 点：直径来自 grob$size（unit，"char" 按 gp$fontsize 折算）；
    # 颜色按 gp$col / gp$fill 的循环下标分组，保留按映射着色的分组信息。
    if ("points" %in% cls) {
      xs <- npc(grob$x, "x"); ys <- npc(grob$y, "y")
      keep <- which(!is.na(xs) & !is.na(ys))
      if (length(keep)) {
        # pch 允许是字符（ggtree 的点位矩阵用 pch="|" 排出一片「字符点阵」）。这种点
        # R 直接按同字号文字画：实测 points(pch='|', size=1char, lwd=0.94) 与
        # text('|', 同字号) 的 bbox（0.36x3.06 px@72dpi）和墨量完全相同，size / lwd 都不参与。
        # 当成圆画会把它撑到 3px 直径 —— 885 个点就把右中那块墨量抬到 R 的 4.6 倍。
        pch_all <- if (is.null(grob$pch)) rep(19, length(xs)) else rep_len(as.character(grob$pch), length(xs))
        pch_k <- pch_all[keep]
        pch_num <- suppressWarnings(as.numeric(pch_k))
        is_glyph <- is.na(pch_num) & !is.na(pch_k) & nzchar(pch_k)
        if (any(is_glyph)) {
          fs <- (gp$fontsize %||% 12)[1]
          if (length(fs) == 0 || is.na(fs)) fs <- 12
          colv <- gp$col %||% "#000000"
          face <- (gp$fontface %||% "plain")[1]
          for (m in which(is_glyph)) {
            j <- keep[m]
            s <- col_split(colv[((j - 1) %% length(colv)) + 1], "#000000")
            prims[[length(prims) + 1]] <- list(
              t = "text", s = pch_k[m], x = r4(ax(xs[j])), y = r4(ay(ys[j])),
              size = r4(fs * sc), color = s$color %||% "#000000", alpha = s$alpha,
              rot = 0, hjust = 0.5, vjust = 0.5,
              bold = face %in% c("bold", "bold.italic"),
              italic = face %in% c("italic", "bold.italic"),
              w = r4(nchar(pch_k[m]) * fs * 0.55 / W_px), h = r4(fs * 1.2 / H_px)
            )
          }
        }
        keep <- keep[!is_glyph]
      }
      if (length(keep)) {
        # pch=1（点）与 pch=46（'.'）画的是跟 size 无关的小墨点：实测直径 = 1.44·lwd
        # 与恒定 0.72px（72dpi 口径），跟圆点模型差一个数量级，单独走一条分支。
        pch1 <- suppressWarnings(as.numeric(pch_k[1]))
        d <- if (!is.na(pch1) && pch1 == 1)      r4(1.44 * ((gp$lwd %||% 1)[1]) * sc)
             else if (!is.na(pch1) && pch1 == 46) r4(0.72 * sc)
             else                                 r4(point_diam_pt(grob, gp, dev_k) * sc)
        colv <- gp$col %||% "#000000"
        filv <- gp$fill
        idx <- seq_along(keep)
        ci <- (idx - 1) %% length(colv) + 1
        fi <- if (is.null(filv)) rep(NA_integer_, length(idx)) else (idx - 1) %% length(filv) + 1
        # 按「解析后的样式值」分组（不是按下标）：gp$col 长度等于点数但取值只有
        # 几种时，仍然应该合并成少数几个 pts 图元，否则节点数会爆炸。
        pcol <- pfil <- character(0); palpha <- pfilal <- numeric(0)
        for (m in idx) {
          s <- col_split(colv[ci[m]], "#000000")
          pcol[[m]] <- s$color %||% "#000000"; palpha[[m]] <- s$alpha
          t2 <- if (is.null(filv)) list(color = NULL, alpha = 1) else col_split(filv[fi[m]], NULL)
          pfil[[m]] <- t2$color %||% NA_character_; pfilal[[m]] <- t2$alpha
        }
        gkey <- paste(pcol, palpha, pfil, pfilal, sep = "|")
        for (k in unique(gkey)) {
          m <- which(gkey == k)
          sel <- keep[m]
          prims[[length(prims) + 1]] <- list(
            t = "pts",
            xy = r4(as.vector(t(cbind(ax(xs[sel]), ay(ys[sel]))))),
            size = d,
            color = pcol[[m[1]]], alpha = palpha[[m[1]]],
            fill = pfil[[m[1]]], fill_alpha = pfilal[[m[1]]]
          )
        }
      }
    }
    # 线段：grid 的 segmentsGrob 字段是 x0/y0/x1/y1（旧版是 x/y/xend/yend）
    if ("segments" %in% cls || "segment" %in% cls) {
      xs <- npc(grob$x0 %||% grob$x, "x"); ys <- npc(grob$y0 %||% grob$y, "y")
      xe <- npc(grob$x1 %||% grob$xend, "x"); ye <- npc(grob$y1 %||% grob$yend, "y")
      n <- max(length(xs), length(ys), length(xe), length(ye))
      if (n >= 1) {
        xs <- rep_len(xs, n); ys <- rep_len(ys, n)
        xe <- rep_len(xe, n); ye <- rep_len(ye, n)
      }
      if (n >= 1) {
        colv <- gp$col %||% "#000000"
        lwdv <- gp$lwd %||% 1
        ltyv <- gp$lty %||% 1
        cap1 <- gtv_cap(gp$lineend)
        i <- seq_len(n)
        ci <- (i - 1) %% length(colv) + 1
        li <- (i - 1) %% length(lwdv) + 1
        ti <- (i - 1) %% length(ltyv) + 1
        scol <- character(0); salpha <- numeric(0); slwd <- numeric(0); sdash <- character(0)
        for (q in i) {
          s <- col_split(colv[ci[q]], "#000000")
          scol[[q]] <- s$color %||% "#000000"; salpha[[q]] <- s$alpha
          slwd[[q]] <- r4(lwdv[li[q]] * sc_lwd)
          sdash[[q]] <- as.character(lty_is_dash(ltyv[ti[q]]))
        }
        gkey <- paste(scol, salpha, slwd, sdash, sep = "|")
        for (k in unique(gkey)) {
          j <- which(gkey == k)
          xy <- numeric(0)
          for (q in j) {
            if (any(is.na(c(xs[q], ys[q], xe[q], ye[q])))) next
            xy <- c(xy, ax(xs[q]), ay(ys[q]), ax(xe[q]), ay(ye[q]))
          }
          if (!length(xy)) next
          pr <- list(
            t = "seg", xy = r4(xy), color = scol[[j[1]]], alpha = salpha[[j[1]]],
            lwd = slwd[[j[1]]], dash = lty_is_dash(ltyv[ti[j[1]]])
          )
          if (!is.null(cap1)) pr$cap <- cap1
          prims[[length(prims) + 1]] <- pr
        }
      }
    }
    # 多边形：箱体 / ribbon / area 等；按 grob$id 切分闭合子多边形
    if ("polygon" %in% cls) {
      xs <- npc(grob$x, "x"); ys <- npc(grob$y, "y")
      n <- min(length(xs), length(ys))
      if (n >= 2) {
        ids <- grob$id
        if (is.null(ids) || length(ids) == 0) ids <- rep(1L, n)
        if (length(ids) == 1) ids <- rep(ids, n)
        colv <- gp$col %||% NA_character_
        filv <- gp$fill
        lwdv <- gp$lwd %||% 1
        ltyv <- gp$lty %||% 1
        i <- seq_len(n)
        ci <- (i - 1) %% length(colv) + 1
        fi <- if (is.null(filv)) rep(NA_integer_, n) else (i - 1) %% length(filv) + 1
        li <- (i - 1) %% length(lwdv) + 1
        ti <- (i - 1) %% length(ltyv) + 1
        for (gid in unique(ids)) {
          k <- which(ids == gid & !is.na(xs) & !is.na(ys))
          if (length(k) < 2) next
          col <- col_split(colv[ci[k[1]]], NULL)
          fl <- col_split(if (is.null(filv)) NULL else filv[fi[k[1]]], NULL)
          prims[[length(prims) + 1]] <- list(
            t = "poly",
            xy = r4(as.vector(t(cbind(ax(xs[k]), ay(ys[k]))))),
            fill = fl$color %||% NA_character_, fill_alpha = fl$alpha,
            stroke = col$color %||% NA_character_, stroke_alpha = col$alpha,
            lwd = r4(lwdv[li[k[1]]] * sc_lwd), dash = lty_is_dash(ltyv[ti[k[1]]])
          )
        }
      }
    }
    # 折线：polylineGrob 的类是 "polyline"，linesGrob（图例 key 的须/帽）的类是 "lines"
    if ("polyline" %in% cls || "lines" %in% cls) {
      xs <- npc(grob$x, "x"); ys <- npc(grob$y, "y")
      # grid 的 linesGrob 允许 x / y 长度不等（图例 key 的须：x 一个、y 两个），
      # 按 grid 的 recycling 规则补齐，否则第二个点会解析成 NA 而整条线丢失。
      n <- max(length(xs), length(ys))
      if (n >= 1) { xs <- rep_len(xs, n); ys <- rep_len(ys, n) }
      ids <- grob$id %||% rep(1, n)
      if (length(ids) == 1) ids <- rep(ids, n)
      # gp 是按「第几条折线」回收的，不是按点：polylineGrob 有几条折线，gp$col 就有几个值。
      # 整批取 [1] 是个真 bug —— ggtree 的彩色环 967 条有 62 种颜色，全存成第一种深绿之后，
      # 网页端这一层的墨量实测是 R 的 1.32 倍（深绿亮度 86，而 62 色的平均亮度 128）。
      gids <- unique(ids)
      cap1 <- gtv_cap(gp$lineend); join1 <- gtv_join(gp$linejoin)
      # grid::gridLines() 生成的 polyline 没有 id，但语义是「每两点一条独立线段」
      # （面板网格线）。判据：点数为偶、每对自身轴对齐、而相邻对之间的连线不轴对齐。
      # 满足则按 seg 导出，否则按连续折线 line 导出。
      is_pairs <- function(xv, yv) {
        n <- length(xv)
        if (n < 4 || n %% 2 != 0) return(FALSE)
        e <- 1e-6
        seg_ok <- all(vapply(seq(1, n, by = 2), function(i)
          abs(xv[i] - xv[i + 1]) < e || abs(yv[i] - yv[i + 1]) < e, logical(1)))
        conn_ok <- all(vapply(seq(2, n - 1, by = 2), function(i)
          abs(xv[i] - xv[i + 1]) >= e && abs(yv[i] - yv[i + 1]) >= e, logical(1)))
        seg_ok && conn_ok
      }
      for (gi in seq_along(gids)) {
        k <- which(ids == gids[gi] & !is.na(xs) & !is.na(ys))
        if (length(k) < 2) next
        lwdv <- gp_at(gp, "lwd", gi); if (is.null(lwdv) || is.na(lwdv)) lwdv <- 1
        ltyv <- gp_at(gp, "lty", gi); if (is.null(ltyv) || is.na(ltyv)) ltyv <- 1
        colg <- col_split(gp_at(gp, "col", gi), "#000000")
        type <- if (length(k) > 2 && is_pairs(xs[k], ys[k])) "seg" else "line"
        pr <- list(
          t = type, xy = r4(as.vector(t(cbind(ax(xs[k]), ay(ys[k]))))),
          color = colg$color, alpha = colg$alpha,
          lwd = r4(lwdv * sc_lwd), dash = lty_is_dash(ltyv)
        )
        if (!is.null(cap1)) pr$cap <- cap1
        if (!is.null(join1) && length(k) > 2) pr$join <- join1
        prims[[length(prims) + 1]] <- pr
      }
    }
    if ("text" %in% cls) {
      labels <- grob$label
      is_expr <- is.expression(labels)
      xs <- npc(grob$x, "x"); ys <- npc(grob$y, "y")
      n <- min(length(labels), length(xs), length(ys))
      fs <- (gp$fontsize %||% 12)[1]
      col <- col_split(gp$col, "#000000")
      rot <- (grob$rot %||% grob$angle %||% 0); rot <- if (length(rot)) rot[1] else 0
      # 文字锚点：ggplot2 给的是数字，手写的 textGrob 可能只给 just 关键字
      hj <- just_num(grob$hjust %||% grob$just[1], 0.5)
      vj <- just_num(grob$vjust %||% grob$just[2], 0.5)
      face <- (gp$fontface %||% "plain")[1]
      for (i in seq_len(n)) {
        if (is.na(xs[i]) || is.na(ys[i])) next
        ml <- gtv_math_label(labels[i], is_expr)
        lab <- ml$s
        # R 4.6 的 grid 不支持 string 单位；用字宽估算（平均字宽约 0.55em）
        tw <- nchar(lab) * fs * 0.55 / W_px          # 画布宽度 npc
        th <- fs * 1.2 / H_px                          # 画布高度 npc
        prims[[length(prims) + 1]] <- list(
          t = "text", s = lab, x = r4(ax(xs[i])), y = r4(ay(ys[i])),
          size = r4(fs * sc), color = col$color, alpha = col$alpha,
          rot = r4(rot %% 360), hjust = r4(hj[1]), vjust = r4(vj[1]),
          bold = ml$bold || face %in% c("bold", "bold.italic"),
          italic = ml$italic || face %in% c("italic", "bold.italic"),
          w = r4(tw), h = r4(th)
        )
      }
    }
    prims
  }

  # 叶子 bbox：prims 范围与单元格矩形求并（plane 至少覆盖单元格）
  tight_bbox <- function(prims, cell) {
    x0 <- Inf; y0 <- Inf; x1 <- -Inf; y1 <- -Inf; pad <- 0
    for (pr in prims) {
      if (pr$t %in% c("pts", "seg", "line", "poly")) {
        xy <- pr$xy
        if (pr$t == "pts") pad <- max(pad, pr$size / 2 / W_px)
        x0 <- min(x0, min(xy[c(TRUE, FALSE)])); x1 <- max(x1, max(xy[c(TRUE, FALSE)]))
        y0 <- min(y0, min(xy[c(FALSE, TRUE)])); y1 <- max(y1, max(xy[c(FALSE, TRUE)]))
      } else if (pr$t == "rect") {
        x0 <- min(x0, pr$x); y0 <- min(y0, pr$y)
        x1 <- max(x1, pr$x + pr$w); y1 <- max(y1, pr$y + pr$h)
      } else if (pr$t == "text") {
        hw <- pr$w / 2; hh <- pr$h / 2
        vert <- !is.na(pr$rot) && (pr$rot %% 180) == 90
        if (vert) { tmp <- hw; hw <- hh; hh <- tmp }
        cx <- pr$x + (0.5 - pr$hjust) * (if (vert) pr$h else pr$w)
        cy <- pr$y + (0.5 - pr$vjust) * (if (vert) pr$w else pr$h)
        x0 <- min(x0, cx - hw); x1 <- max(x1, cx + hw)
        y0 <- min(y0, cy - hh); y1 <- max(y1, cy + hh)
      }
    }
    if (!is.finite(x0)) return(cell)
    x0 <- x0 - pad; x1 <- x1 + pad
    bx0 <- min(x0, cell[1]); by0 <- min(y0, cell[2])
    bx1 <- max(x1, cell[1] + cell[3]); by1 <- max(y1, cell[2] + cell[4])
    c(bx0, by0, bx1 - bx0, by1 - by0)
  }

  # ---- 递归遍历 -------------------------------------------------------------
  # 不变式: 调用 walk() 时当前 vp == 父级单元格 vp；cell = 该单元格的画布绝对 npc
  #
  # grob 自带的 viewport（node$vp）必须参与几何计算，两个原因：
  #   * ggplot2 的 absoluteGrob 把位置只写在 $vp 里（$x/$y/$just 常常是 NULL），
  #     不认 vp 就会把坐标轴/图例当成「铺满单元格」画，整张图糊成一片；
  #   * patchwork / ggtree 拼多 panel 时常用 vp 做整体缩放（w=1.35npc 这种），
  #     不认 vp 缩放就丢了。
  # 解析口径与其它分支一致：x/y 相对当前 vp 取 npc，width/height 取 cm 再折算成比例。
  vp_rect <- function(vp, cell) {
    gx <- tryCatch(convertX(vp$x %||% unit(0.5, "npc"), "npc", valueOnly = TRUE),
                   error = function(e) NA_real_)[1]
    gy <- tryCatch(convertY(vp$y %||% unit(0.5, "npc"), "npc", valueOnly = TRUE),
                   error = function(e) NA_real_)[1]
    gw <- tryCatch(convertWidth(vp$width %||% unit(1, "npc"), "cm", valueOnly = TRUE),
                   error = function(e) NA_real_)[1]
    gh <- tryCatch(convertHeight(vp$height %||% unit(1, "npc"), "cm", valueOnly = TRUE),
                   error = function(e) NA_real_)[1]
    if (is.na(gx)) gx <- 0.5
    if (is.na(gy)) gy <- 0.5
    cw <- cell[3] * Wcm; ch_cm <- cell[4] * Hcm
    fw <- if (is.na(gw) || gw <= 0 || cw <= 0) 1 else gw / cw
    fh <- if (is.na(gh) || gh <= 0 || ch_cm <= 0) 1 else gh / ch_cm
    j <- vp$just %||% c(0.5, 0.5)
    if (length(j) < 2) j <- c(j, j)
    jx <- switch(as.character(j[1]), left = 0, right = 1, centre = 0.5, center = 0.5,
                 suppressWarnings(as.numeric(j[1])))
    jy <- switch(as.character(j[2]), bottom = 0, top = 1, centre = 0.5, center = 0.5,
                 suppressWarnings(as.numeric(j[2])))
    if (is.na(jx)) jx <- 0.5
    if (is.na(jy)) jy <- 0.5
    c(cell[1] + (gx - jx * fw) * cell[3], cell[2] + (gy - jy * fh) * cell[4],
      fw * cell[3], fh * cell[4])
  }

  walk <- function(node, cell, depth, parent, ctx, path, rpath, rseg, pgp = NULL) {
    if (is.null(node) || inherits(node, "zeroGrob")) return(NULL)
    nm <- node$name %||% ""
    gp_here <- merge_gp(pgp, node$gp)   # 传给子节点做 gp 继承

    if (!is.null(node$vp)) {            # 见上面 vp_rect 的注释
      cell <- vp_rect(node$vp, cell)
      pushViewport(viewport(width = unit(max(cell[3] * Wcm, 1e-4), "cm"),
                            height = unit(max(cell[4] * Hcm, 1e-4), "cm")))
      on.exit(popViewport(), add = TRUE)
    }

    # --- gtable ---
    if (inherits(node, "gtable")) {
      id <- add_node(nm, ctx$kind, "gtable", depth, parent, cell, path, rpath, rseg, NULL)
      total_w_cm <- cell[3] * Wcm
      total_h_cm <- cell[4] * Hcm
      pushViewport(viewport(width = unit(max(total_w_cm, 1e-4), "cm"),
                            height = unit(max(total_h_cm, 1e-4), "cm")))
      on.exit(popViewport(), add = TRUE)
      wc <- resolve_tracks(node$widths, total_w_cm)
      hc <- resolve_tracks_h(node$heights, total_h_cm)
      tw <- sum(wc); th <- sum(hc)
      if (tw <= 0) tw <- 1; if (th <= 0) th <- 1
      if (nrow(node$layout) == 0) return(id)
      ord <- order(node$layout$z, seq_len(nrow(node$layout)))
      for (i in ord) {
        lay <- node$layout[i, ]
        x0 <- sum(wc[seq_len(lay$l - 1)]) / tw
        x1 <- sum(wc[seq_len(lay$r)]) / tw
        y1 <- 1 - sum(hc[seq_len(lay$t - 1)]) / th
        y0 <- 1 - sum(hc[seq_len(lay$b)]) / th
        cell_abs <- c(cell[1] + x0 * cell[3], cell[2] + y0 * cell[4],
                      (x1 - x0) * cell[3], (y1 - y0) * cell[4])
        # layout 第 i 行对应的 grob 下标（ggplot 生成的 gtable 里 grob == i，但按 lay$grob 取
        # 才是 R 里真实的那个对象，导出的 rpath 也必须用它，否则学生照抄会取到别的 grob）
        gi <- as.integer(lay$grob %||% i)
        seg <- paste0("$grobs[[", gi, "]]")
        pushViewport(viewport(width = unit(max((x1 - x0) * total_w_cm, 1e-4), "cm"),
                              height = unit(max((y1 - y0) * total_h_cm, 1e-4), "cm")))
        walk(node$grobs[[gi]], cell_abs, depth + 1, id,
             ctx_for_cell(lay$name, ctx), paste0(path, " / ", lay$name),
             paste0(rpath, seg), seg, gp_here)
        popViewport()
      }
      return(id)
    }

    # --- absoluteGrob ---
    if (inherits(node, "absoluteGrob")) {
      id <- add_node(nm, ctx$kind, "absoluteGrob", depth, parent, cell, path, rpath, rseg, NULL)
      j <- node$just %||% c(0.5, 0.5)
      gx <- npc(node$x, "x")[1]; gy <- npc(node$y, "y")[1]
      gw <- npc(node$width, "width")[1]; gh <- npc(node$height, "height")[1]
      if (is.na(gx)) gx <- 0.5; if (is.na(gy)) gy <- 0.5
      if (is.na(gw) || gw <= 0) gw <- 1; if (is.na(gh) || gh <= 0) gh <- 1
      sub <- c(cell[1] + (gx - j[1] * gw) * cell[3],
               cell[2] + (gy - j[2] * gh) * cell[4],
               gw * cell[3], gh * cell[4])
      pushViewport(viewport(width = unit(max(sub[3] * Wcm, 1e-4), "cm"),
                            height = unit(max(sub[4] * Hcm, 1e-4), "cm")))
      on.exit(popViewport(), add = TRUE)
      for (i in seq_along(node$children)) {
        ch <- node$children[[i]]
        if (is.null(ch)) next
        seg <- paste0("$children[[", i, "]]")
        walk(ch, sub, depth + 1, id, ctx, paste0(path, " / ", nm), paste0(rpath, seg), seg, gp_here)
      }
      return(id)
    }

    # --- panel gTree（ggplot2 4.x: layer 数据已预缩放到 0~1 native，直接用单元格 vp）---
    if (inherits(node, "gTree") && grepl("^panel-\\d+", nm)) {
      id <- add_node(nm, "panel", "gTree", depth, parent, cell, path, rpath, rseg, NULL)
      for (i in seq_along(node$children)) {
        ch <- node$children[[i]]
        if (is.null(ch)) next
        seg <- paste0("$children[[", i, "]]")
        walk(ch, cell, depth + 1, id, list(kind = "panel"),
             paste0(path, " / ", nm), paste0(rpath, seg), seg, gp_here)
      }
      return(id)
    }

    # --- 普通 gTree（grill / titleGrob 等）：子 grob 画在当前 vp ---
    if (inherits(node, "gTree") && length(node$children) > 0) {
      id <- add_node(nm, ctx$kind, "gTree", depth, parent, cell, path, rpath, rseg, NULL)
      for (i in seq_along(node$children)) {
        ch <- node$children[[i]]
        if (is.null(ch)) next
        seg <- paste0("$children[[", i, "]]")
        walk(ch, cell, depth + 1, id, ctx, paste0(path, " / ", nm), paste0(rpath, seg), seg, gp_here)
      }
      return(id)
    }

    # --- 叶子 grob ---
    prims <- extract_prims(node, cell, gp_here)
    if (length(prims) == 0) return(NULL)
    has_text <- any(vapply(prims, function(pr) identical(pr$t, "text"), logical(1)))
    add_node(nm, leaf_kind(ctx, nm, has_text), class(node)[1], depth, parent,
             tight_bbox(prims, cell), path, rpath, rseg, prims)
    NULL
  }

  # ---- 根 ----
  # 根节点的 rpath 来自装载层：ggplot 输入是 ggplotGrob(<变量名>)，
  # .RData 图束是 <对象名>$Plot。学生只要手里有那个对象，整条路径就能直接粘进 R 求值。
  pushViewport(viewport(width = unit(Wcm, "cm"), height = unit(Hcm, "cm")))
  walk(g, c(0, 0, 1, 1), 0, NULL, list(kind = "layout"), "layout",
       src$root_expr, "")
  popViewport()

  panels <- lapply(seq_along(panel_params), function(i) {
    pp <- panel_params[[i]]
    list(index = i,
         xrange = list(r4(pp$x.range[1]), r4(pp$x.range[2])),
         yrange = list(r4(pp$y.range[1]), r4(pp$y.range[2])))
  })

  out <- list(
    meta = list(id = sample_id, label = sample_label, generator = "export_gtable.R",
                ggplot2 = as.character(packageVersion("ggplot2")),
                exported = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
                root_var = src$root_var,
                root_expr = src$root_expr,           # 学生粘进 R 的根表达式
                source = src$source,                 # rds | rdata
                kind = src$kind,                     # ggplot（要 build）| grob（成品树）
                size_in = list(r4(size_in[1]), r4(size_in[2])),
                size_src = src$size_src,             # Size | sidecar | default
                plot = list(width_px = W_px, height_px = H_px)),
    panels = panels,
    nodes = unname(nodes)
  )
  txt <- jsonlite::toJSON(out, auto_unbox = TRUE, pretty = FALSE, na = "null", digits = 4)
  # 直接写原始字节（跟 export_all.R 写 index.json 一样）：
  #   * writeLines(con = 文件名) 在 Windows 上会做 LF→CRLF 转换，同一份数据在不同
  #     平台上字节不同 —— 版本库里看着像整文件改动，校验哈希也对不上；
  #   * 文本连接还可能按本地代码页重编码，把中文写坏。
  writeBin(charToRaw(paste0(enc2utf8(as.character(txt)), "\n")), json_path)
  cat(sprintf("[export_gtable] %s -> %s  (%dx%d px, 画布 %s, nodes=%d, leaves=%d)\n",
              basename(rds_path), json_path, W_px, H_px, src$size_src, n_counter,
              sum(vapply(nodes, function(n) length(n$prims) > 0, logical(1)))))
  cat(sprintf("[export_gtable]   设备系数：线 ×%.3f（R 按 res/96 画线）  点 ×%.3f（点径 = 系数 ×（size + lwd））\n",
              dev_k$lwd, dev_k$size))
  invisible(out)
}

# ---------------------------------------------------------------------------
# CLI（被 source() 时不执行，见 Scripts/export_all.R）
# ---------------------------------------------------------------------------
if (!isTRUE(getOption("gtv.no_cli"))) local({
  args <- commandArgs(trailingOnly = TRUE)
  opt <- function(name) {
    hit <- grep(paste0("^--", name, "="), args, value = TRUE)
    if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else NA_character_
  }
  pos <- args[!grepl("^--", args)]
  if (length(pos) < 2) {
    cat("用法: Rscript export_gtable.R <input.rds|RData> <output.json> [sample_id] [sample_label]\n")
    cat("        [--root=<变量名>] [--plot=<RData 里的对象或 $路径>] [--size=7x6.11] [--size-unit=in|cm|mm|px]\n")
    cat("说明: .rds 与 .RData 都收「一个 ggplot / gtable」或「图束 list(Plot=, Size=)」；\n")
    cat("      有 Size 就按 Size 画，没有才用默认 7x5 英寸。\n")
    quit(status = 1)
  }
  export_gtable(
    rds_path = pos[1], json_path = pos[2],
    sample_id = pos[3] %||% tools::file_path_sans_ext(basename(pos[1])),
    sample_label = pos[4] %||% pos[3] %||% basename(pos[1]),
    root_var = if (is.na(opt("root"))) NULL else opt("root"),
    plot = opt("plot"),
    size = opt("size"),
    size_unit = { su <- opt("size-unit"); if (is.na(su)) "in" else su }
  )
})
