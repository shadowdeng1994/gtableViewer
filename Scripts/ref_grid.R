#!/usr/bin/env Rscript
# ============================================================================
# ref_grid.R — 生成「R 真实渲染」的参考亮度网格，用于校验网页端 2D 复现是否正确
# ----------------------------------------------------------------------------
# 用法（在 gtableViewer/ 目录下）:
#   Rscript Scripts/ref_grid.R            # 输出到 Scripts/.ref/<id>.grid.txt
#   Rscript Scripts/ref_grid.R scatter    # 只重做几个
#
# 网格：每格约 6.4 px（504x360 就是 79 列 x 57 行），行 0 = 顶部；
#       每格 = 该区域内 RGB 亮度的均值（0-255，白底）。
# 画布尺寸跟着样例走：.rds 默认 7x5 英寸，.RData 里带 Size 就按 Size 渲染，
#       所以每个样例的网格尺寸可能不同 —— 网页端（check_render.js）按文件自身的
#       行列数推断，不写死 79x57。
# 网页端用同一网格采样 canvas-2d（把透明像素按白底合成），再算平均绝对误差。
# ============================================================================

suppressPackageStartupMessages({ library(ggplot2); library(grid) })

root <- if (file.exists("Scripts/export_gtable.R")) getwd() else {
  ai <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(ai)) dirname(dirname(normalizePath(sub("^--file=", "", ai[1])))) else stop("找不到 Scripts/export_gtable.R")
}
setwd(root)
options(gtv.no_cli = TRUE)             # 别把 export_gtable.R 的命令行入口跑起来
source("Scripts/export_gtable.R", local = FALSE, encoding = "UTF-8")   # 只要它的装载层

# Size 只决定「比例与相对大小」（用户裁定）：画布按 Size 英寸出，
# 分辨率按 R 里常用的 repr.plot.res=200 出，这样参考图清晰好看；
# 网格仍按 72 dpi 空间的同一格大小（约 6.4 px）划分，所以 504x360 依旧是 79x57，
# 既有样例的网格行列数不变，网页端（check_render.js）继续按文件自身行列数推断。
DPI <- 72        # 网格坐标系（与网页 page_w_px/page_h_px 同一空间）
REF_RES <- gtv_ref_res()   # 参考 PNG 的实际光栅分辨率（导出器量布局用同一台设备/同一 res）
CELL_W <- 504 / 79; CELL_H <- 360 / 57
outdir <- "Scripts/.ref"
if (!dir.exists(outdir)) dir.create(outdir, recursive = TRUE)

cell_mean <- function(L, GX, GY) {
  h <- nrow(L); w <- ncol(L)
  m <- matrix(0, GY, GX)
  for (gy in seq_len(GY)) {
    r0 <- floor((gy - 1) * h / GY) + 1; r1 <- max(r0, floor(gy * h / GY))
    for (gx in seq_len(GX)) {
      c0 <- floor((gx - 1) * w / GX) + 1; c1 <- max(c0, floor(gx * w / GX))
      m[gy, gx] <- mean(L[r0:r1, c0:c1, drop = FALSE])
    }
  }
  m
}

# 默认给 rds/ 里所有样例生成基准（新丢进来的图跑一次就有基准）；也可以把 id 当参数
# 传进来只重做几个：Rscript Scripts/ref_grid.R scatter facet
ids <- commandArgs(trailingOnly = TRUE)
if (!length(ids)) {
  ids <- tools::file_path_sans_ext(basename(
    list.files("rds", pattern = "\\.(rds|rdata|rda)$", ignore.case = TRUE)))
}
for (id in ids) {
  src <- NA_character_
  for (ext in c(".rds", ".RData", ".rda")) {
    f <- file.path("rds", paste0(id, ext))
    if (file.exists(f)) { src <- f; break }
  }
  if (is.na(src)) { cat("[ref_grid] skip", id, "（rds/ 里没有源文件）\n"); next }

  inp <- tryCatch(gtv_load_input(src), error = function(e) {
    cat("[ref_grid] skip", id, "装载失败:", conditionMessage(e), "\n"); NULL })
  if (is.null(inp)) next

  W <- max(1L, round(inp$size_in[1] * DPI)); H <- max(1L, round(inp$size_in[2] * DPI))
  GX <- max(1L, round(W / CELL_W)); GY <- max(1L, round(H / CELL_H))
  # 光栅按 REF_RES 出（同一 Size 比例，像素更多 = 更清晰），网格按 72dpi 空间划分
  RW <- max(1L, round(inp$size_in[1] * REF_RES)); RH <- max(1L, round(inp$size_in[2] * REF_RES))

  png_file <- tempfile(fileext = ".png")
  grDevices::png(png_file, width = RW, height = RH, res = REF_RES, bg = "white", type = "cairo")
  # ggplot 用 print()；.RData 里那种成品 gtable 用 print 只会打印摘要不画图，得 grid.draw
  if (inp$kind == "ggplot") print(inp$obj) else grid.draw(inp$obj)
  invisible(grDevices::dev.off())
  if (!file.exists(png_file)) { cat("[ref_grid] skip", id, "（没有产出 PNG）\n"); next }
  img <- png::readPNG(png_file)
  unlink(png_file)
  L <- (0.299 * img[, , 1] + 0.587 * img[, , 2] + 0.114 * img[, , 3]) * 255
  m <- round(cell_mean(L, GX, GY))
  out <- file.path(outdir, paste0(id, ".grid.txt"))
  # 原始字节 + LF（理由同 export_gtable.R 写 json）：免得同一份基准在不同平台上
  # 字节不同，git 里看着像整文件改动
  writeBin(charToRaw(paste0(paste(apply(m, 1, function(r) paste(r, collapse = " ")),
                                   collapse = "\n"), "\n")), out)
  cat(sprintf("[ref_grid] %s -> %s  (%dx%d px @%d，网格 %dx%d，画布 %s，mean=%.1f)\n",
              id, out, RW, RH, REF_RES, GX, GY, inp$size_src, mean(m)))
}
