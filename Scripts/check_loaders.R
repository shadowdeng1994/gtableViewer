#!/usr/bin/env Rscript
# ============================================================================
# check_loaders.R — 钉死 gtv_load_input() 的「认图 / 取尺寸」行为
# ----------------------------------------------------------------------------
# 用法（在 gtableViewer/ 目录下）:
#   Rscript Scripts/check_loaders.R
#
# rds/ 下既可能放 .rds 也可能放 .RData；文件里既可能是「一个 ggplot / gtable」，
# 也可能是「图束 list(Plot =, Size =)」（ggtree / patchwork 拼完基本都这么存，
# 画布尺寸只有 $Size 知道）。这个脚本用临时造出来的样例把这几种组合逐条钉死：
# 认出的是哪张图、root_expr 写成什么、画布尺寸取到多少、多对象时有没有报错或提醒。
# 改装载层的人必须显式改这里的期望值，不能让「认错图 / 悄悄按 7x5 画」溜过去。
#
# 注意：本文件不能带 BOM。
# ============================================================================

root <- if (dir.exists("samples")) getwd() else stop("请在 gtableViewer/ 目录下运行")
setwd(root)
grDevices::pdf(NULL)                 # 别让 grid 顺手往仓库里掉 Rplots.pdf
options(gtv.no_cli = TRUE)           # 否则 source 导出器会打印 CLI 用法并 quit
source("Scripts/export_gtable.R", local = FALSE, encoding = "UTF-8")

tmp <- file.path(tempdir(), "gtv-loaders")
unlink(tmp, recursive = TRUE)
dir.create(tmp, recursive = TRUE)

# ---- 造样例 -----------------------------------------------------------------
p  <- ggplot2::ggplot(mtcars, ggplot2::aes(mpg, wt)) + ggplot2::geom_point()
gg <- ggplot2::ggplotGrob(p)
# 「整列都是 null 单位」的 gtable：拼出来的图（ggtree / patchwork）就长这样，
# 它自己没有绝对尺寸，只有 Size 才知道该画多大。
null_gt <- gtable::gtable(widths = grid::unit(c(1, 1), "null"),
                          heights = grid::unit(c(1, 1), "null"))

saveRDS(p,  file.path(tmp, "plain.rds"))                                   # ①
saveRDS(gg, file.path(tmp, "gtable.rds"))                                  # ②
saveRDS(list(Plot = gg, Size = c(3, 2)), file.path(tmp, "bundle.rds"))     # ③
saveRDS(data.frame(a = 1), file.path(tmp, "notplot.rds"))                  # ⑩

fig.Merged <- list(Plot = gg, Size = c(3, 3))
save(fig.Merged, file = file.path(tmp, "bundle.RData"))                    # ④
Bare <- gg; Size <- c(5, 4)
save(Bare, Size, file = file.path(tmp, "bare_size.RData"))                 # ⑤
Whole <- null_gt
save(Whole, file = file.path(tmp, "null_nosize.RData"))                    # ⑥
NullSized <- null_gt; Size <- c(4, 2)
save(NullSized, Size, file = file.path(tmp, "null_size.RData"))            # ⑦
unitSize <- list(Plot = gg, Size = grid::unit(c(3, 2), "in"))
save(unitSize, file = file.path(tmp, "unit_size.RData"))                   # ⑧
A <- p; B <- p
save(A, B, file = file.path(tmp, "two.RData"))                             # ⑨
fig2 <- list(Plot = gg, Size = c(3, 3)); Other <- gg
save(fig2, Other, file = file.path(tmp, "pick.RData"))                     # ⑪
PxSize <- list(Plot = gg, Size = c(504, 440))
save(PxSize, file = file.path(tmp, "px_size.RData"))                       # ⑫

# ---- 断言工具 ---------------------------------------------------------------
pass <- 0L; total <- 0L
ok <- function(cond, label) {
  total <<- total + 1L; pass <<- pass + as.integer(isTRUE(cond))
  cat(if (isTRUE(cond)) "  ok   " else "  FAIL ", label, "\n", sep = "")
  invisible(isTRUE(cond))
}
near <- function(a, b) isTRUE(all.equal(as.numeric(a), as.numeric(b), tolerance = 1e-4))
L <- function(...) gtv_load_input(...)
f <- function(nm) file.path(tmp, nm)
err_of <- function(expr) tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))

# ---- ① 单个 ggplot 的 .rds ---------------------------------------------------
i <- L(f("plain.rds"))
ok(i$kind == "ggplot" && i$source == "rds" && i$root_var == "tmp" &&
   i$root_expr == "ggplotGrob(tmp)" && near(i$size_in, c(7, 5)),
   "① .rds(ggplot) → kind=ggplot，根表达式 ggplotGrob(tmp)，默认 7x5")

# ---- ② 成品 gtable 的 .rds --------------------------------------------------
i <- L(f("gtable.rds"))
ok(i$kind == "grob" && i$root_expr == "tmp" && i$size_src == "default",
   "② .rds(gtable) → kind=grob，根表达式 tmp")

# ---- ③ 图束存成 .rds（不只是 .RData 才有图束）--------------------------------
out <- capture.output(i <- L(f("bundle.rds")))
ok(i$kind == "grob" && i$root_expr == "tmp$Plot" && near(i$size_in, c(3, 2)) && i$size_src == "Size",
   "③ .rds(list(Plot=, Size=)) → 取 tmp$Plot，尺寸 3x2 来自 Size")

# ---- ④ .RData 图束：Plot + Size 都要用上 -------------------------------------
i <- L(f("bundle.RData"))
ok(i$kind == "grob" && i$source == "rdata" && i$root_var == "fig.Merged" &&
   i$root_expr == "fig.Merged$Plot" && near(i$size_in, c(3, 3)) && i$size_src == "Size",
   "④ .RData 图束 → 变量名 fig.Merged、表达式 fig.Merged$Plot、尺寸 3x3 来自 Size")

# ---- ⑤ 不是图束：图 + 工作区里叫 Size 的对象 ---------------------------------
i <- L(f("bare_size.RData"))
ok(i$root_var == "Bare" && near(i$size_in, c(5, 4)) && i$size_src == "Size",
   "⑤ .RData(非图束) + 顶层 Size → 尺寸 5x4 仍从 Size 取")

# ---- ⑥ 全 null 的 gtable 没有 Size：给默认值，但必须提醒 ----------------------
out <- capture.output(i <- L(f("null_nosize.RData")))
ok(near(i$size_in, c(7, 5)) && any(grepl("null 单位", out)),
   "⑥ 全 null 的 gtable 无 Size → 默认 7x5，并打印「宽高全是 null 单位」提醒")

# ---- ⑦ 全 null 的 gtable + Size：安静通过（这是 ggtree 那张图的常态）----------
out <- capture.output(i <- L(f("null_size.RData")))
ok(near(i$size_in, c(4, 2)) && !any(grepl("null 单位", out)),
   "⑦ 全 null 的 gtable + Size → 按 Size 画，不啰嗦")

# ---- ⑧ Size 是 unit 对象（unit(c(3,2), "in")）-------------------------------
i <- L(f("unit_size.RData"))
ok(near(i$size_in, c(3, 2)) && i$size_src == "Size",
   "⑧ Size = unit(c(3,2), 'in') → 按自带单位解析成 3x2 英寸")

# ---- ⑨ 多个可绘制对象：报错并要求 sidecar 指定 -------------------------------
e <- err_of(L(f("two.RData")))
ok(!is.null(e) && grepl("plot=", e) && grepl("A|B", e),
   "⑨ 多个可绘制对象 → 报错并提示用 sidecar 的 plot= 指定")

# ---- ⑩ .rds 里根本不是图：报错点明 class ------------------------------------
e <- err_of(L(f("notplot.rds")))
ok(!is.null(e) && grepl("不是 ggplot", e) && grepl("data.frame", e),
   "⑩ .rds 里是 data.frame → 报错点明 class")

# ---- ⑪ sidecar 的 plot= 支持对象名与 $ 路径 ---------------------------------
i <- L(f("pick.RData"), plot = "Other")
ok(i$root_var == "Other" && near(i$size_in, c(7, 5)) && i$size_src == "default",
   "⑪a plot=Other → 认那张裸图（没 Size 就 7x5）")
i <- L(f("pick.RData"), plot = "fig2$Plot")
ok(i$root_var == "fig2" && near(i$size_in, c(3, 3)) && i$size_src == "Size",
   "⑪b plot=fig2$Plot → 认那张图，并从同一个图束拿到 Size")

# ---- ⑫ sidecar 的 size= 覆盖图束里的 $Size ---------------------------------
i <- L(f("bundle.RData"), size = "6x2.5")
ok(near(i$size_in, c(6, 2.5)) && i$size_src == "sidecar",
   "⑫ sidecar size=6x2.5 → 覆盖图束里的 $Size")

# ---- ⑬ Size 看着像像素（504x440）：按 px 理解并标注 --------------------------
i <- L(f("px_size.RData"))
ok(near(i$size_in, c(7, 440 / 72)) && grepl("按 px", i$size_src),
   "⑬ Size = c(504, 440) → 按 px 理解成 7x6.11 英寸并标注来源")

unlink(tmp, recursive = TRUE)
cat(sprintf("\n== 装载层回归：%d 通过 / %d 失败 ==\n", pass, total - pass))
quit(status = if (pass == total) 0 else 1)
