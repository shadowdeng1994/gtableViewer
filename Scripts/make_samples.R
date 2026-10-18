#!/usr/bin/env Rscript
# ============================================================================
# make_samples.R — 生成示例 ggplot 对象并保存为 .rds（供 export_gtable.R 消费）
# 用法: Rscript make_samples.R   （在 gtableViewer/ 上级或任意目录运行均可）
# ============================================================================

suppressPackageStartupMessages(library(ggplot2))

here <- tryCatch(dirname(normalizePath(substitute(commandArgs()[0], n = 0))),
                error = function(e) getwd())
# 兼容 Rscript 调用: 用命令行参数定位脚本自身
argv <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", argv, value = TRUE)
root <- if (length(file_arg) == 1) {
  dirname(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
} else getwd()

dir.create(file.path(root, "rds"), showWarnings = FALSE, recursive = TRUE)

# 1) 散点图 — ggplot 自带示例数据 mpg
scatter <- ggplot(mpg, aes(displ, hwy)) +
  geom_point() +
  labs(title = "Engine displacement vs highway mileage")

# 2) 箱线图 — ToothGrowth，带分面填色图例
boxplot_p <- ggplot(ToothGrowth, aes(factor(dose), len, fill = factor(dose))) +
  geom_boxplot() +
  labs(x = "Dose (mg)", y = "Tooth length", fill = "dose")

# 3) 分面散点 — facet_wrap 多面板 + strip
facet <- ggplot(mpg, aes(displ, hwy, colour = class)) +
  geom_point() +
  facet_wrap(~ class) +
  labs(title = "Mileage by vehicle class")

# 4) 直方图 — theme_minimal；柱子的 rectGrob 用 just = c("left","top")（x 是左边、
#    y 是顶边），和前三个样例里 just = centre 的背景矩形不是一回事，正好当回归用例。
hist_p <- ggplot(faithful, aes(eruptions)) +
  geom_histogram(bins = 20, fill = "steelblue", colour = "white") +
  labs(title = "Old Faithful 喷发时长", x = "时长 (min)", y = "频数") +
  theme_minimal(base_size = 11)

saveRDS(scatter,   file.path(root, "rds", "scatter.rds"))
saveRDS(boxplot_p, file.path(root, "rds", "boxplot.rds"))
saveRDS(facet,     file.path(root, "rds", "facet.rds"))
saveRDS(hist_p,    file.path(root, "rds", "hist.rds"))

cat("[make_samples] 已生成 rds/scatter.rds, rds/boxplot.rds, rds/facet.rds, rds/hist.rds\n")
