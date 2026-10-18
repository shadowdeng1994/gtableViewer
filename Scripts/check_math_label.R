#!/usr/bin/env Rscript
# ============================================================================
# check_math_label.R — 钉死 gtv_math_label() 的 plotmath 降级结果
# ----------------------------------------------------------------------------
# 用法（在 gtableViewer/ 目录下）:
#   Rscript Scripts/check_math_label.R
#
# expression(paste("PM"[2.5], " / mL")) 这类标签在网页上画不出来，导出器把它降级
# 成纯文本 + bold / italic 近似。这个脚本把「降级成什么」逐条钉死：改
# gtv_math_label() 的人必须显式改这里的期望值，而不是让标签悄悄变成 "paste"、
# 空串或者一堆星号。
#
# 期望值就是当前实现的输出（2026-10 标定），所以这个脚本防的是「改坏了没人知道」，
# 不是「实现符合某个规范」。上标 / 下标会被摊平（x^2 → x2）——那是有意的取舍：
# canvas 上没有 plotmath 的排版引擎，摊平比丢掉强。
#
# 注意：本文件不能带 BOM。
# ============================================================================

root <- if (dir.exists("samples")) getwd() else stop("请在 gtableViewer/ 目录下运行")
setwd(root)
grDevices::pdf(NULL)                       # 别让 grid 探针顺手往仓库里掉 Rplots.pdf
options(gtv.no_cli = TRUE)                 # 否则 source 导出器会打印 CLI 用法并 quit
source("Scripts/export_gtable.R", local = FALSE, encoding = "UTF-8")

# expression 向量：下标 1 / 2 走的是「传 expression[i] + is_expr = TRUE」那条分支
exprs <- expression(paste("PM", degree, "C"), alpha)

# src 为 NULL 时取 exprs[[n]]；kind: "str" 普通字符 / "math" 字符串形式的表达式 /
# "expr" expression 向量的第 n 个 / "edge" 边界输入
cases <- list(
  list(kind = "str",  s = 'bold("ZF 1")',                                        want = "ZF 1",                 b = TRUE,  i = FALSE),
  list(kind = "str",  s = 'bold(italic("HMF9"))',                                want = "HMF9",                 b = TRUE,  i = TRUE),
  list(kind = "str",  s = 'paste("PM"[2.5], " / mL")',                           want = "PM2.5 / mL",           b = FALSE, i = FALSE),
  list(kind = "str",  s = 'paste("n =", 3, " (", alpha, " =", 0.05, ")")',        want = "n = 3 ( α = 0.05 )",  b = FALSE, i = FALSE),
  list(kind = "str",  s = 'italic("p") - value',                                 want = "p - value",            b = FALSE, i = TRUE),
  list(kind = "math", s = 'Dose (mg)',                                           want = "Dose (mg)",            b = FALSE, i = FALSE),
  list(kind = "math", s = 'Time (min)',                                          want = "Time (min)",           b = FALSE, i = FALSE),
  list(kind = "str",  s = 'bgroup("(" * x^2 * ")"^3)',                           want = "(x2)3",                b = FALSE, i = FALSE),
  list(kind = "str",  s = 'list("A" == 1, B >= 2)',                              want = "A=1, B≥2",              b = FALSE, i = FALSE),
  list(kind = "expr", n = 1,                                                     want = "PM ° C",               b = FALSE, i = FALSE),
  list(kind = "expr", n = 2,                                                     want = "α",                     b = FALSE, i = FALSE),
  list(kind = "edge", s = NULL,                                                  want = "",                     b = FALSE, i = FALSE),
  list(kind = "edge", s = NA,                                                    want = "",                     b = FALSE, i = FALSE),
  list(kind = "edge", s = "",                                                    want = "",                     b = FALSE, i = FALSE),
  list(kind = "plain", s = "Counts (per 1000)",                                  want = "Counts (per 1000)",    b = FALSE, i = FALSE)
)

run <- function(c) {
  if (c$kind == "expr") gtv_math_label(exprs[c$n], TRUE)
  else if (c$kind == "edge") gtv_math_label(c$s)
  else gtv_math_label(c$s)
}

label <- function(c) {
  if (c$kind == "expr") paste0("expression[", c$n, "] ", deparse(exprs[[c$n]]))
  else if (c$kind == "edge") paste0("边界输入 ", if (is.null(c$s)) "NULL" else if (length(c$s) == 1 && is.na(c$s)) "NA" else '""')
  else if (c$kind == "plain") paste0("普通字符标签 ", c$s)
  else c$s
}

fails <- 0L
for (c in cases) {
  r <- tryCatch(run(c), error = function(e) { warning(label(c), " 抛错：", conditionMessage(e)); NULL })
  if (is.null(r)) { fails <- fails + 1L; next }
  ok <- identical(r$s, c$want) && isTRUE(r$bold == c$b) && isTRUE(r$italic == c$i)
  if (!ok) fails <- fails + 1L
  cat(sprintf("%s %-52s → <%s> bold=%s italic=%s%s\n",
              if (ok) "  ok " else " FAIL", label(c), r$s, r$bold, r$italic,
              if (ok) "" else sprintf("   期望 <%s> bold=%s italic=%s", c$want, c$b, c$i)))
}

cat(sprintf("\n== gtv_math_label 回归：%d 例 / %d 失败 ==\n", length(cases), fails))
if (fails > 0L) quit(status = 1L, save = "no")
