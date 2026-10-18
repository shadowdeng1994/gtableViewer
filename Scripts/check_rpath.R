#!/usr/bin/env Rscript
# ============================================================================
# check_rpath.R — 验证 samples/*.json 里每个节点的 rpath 在 R 里真能取到那个 grob
# ----------------------------------------------------------------------------
# 用法（在 gtableViewer/ 目录下）:
#   Rscript Scripts/check_rpath.R            # 全部样例
#   Rscript Scripts/check_rpath.R samples/facet.json
#
# 校验三件事：
#   1) rseg 能拼回 rpath（rpath == 父 rpath .. rseg），前端面包屑才不会骗人；
#   2) 沿 rseg 一层层 [[ 取到的对象，其 $name 与 JSON 里的 name 一致 —— 也就是
#      「学生照抄路径取到的，就是网站上显示的那个 grob」；
#   3) 抽查若干节点，把完整 rpath 字符串交给 eval(parse()) 求值（这才是学生
#      真正会做的事），确认与逐层取值结果相同。
#
# 逐层取值而不是每个节点都 eval：ggplotGrob(tmp) 每次都要重画图，facet 有 169
# 个节点，全 eval 要几分钟。
#
# 注意：本文件不能带 BOM。
# ============================================================================

root <- if (dir.exists("samples")) getwd() else stop("请在 gtableViewer/ 目录下运行")
setwd(root)
# rpath 里写的是裸 ggplotGrob()，eval 之前必须像学生那样把包挂上
suppressPackageStartupMessages(library(ggplot2))
# ggplotGrob() 解析单位时会要一个活动设备，不给它就得落到 Rplots.pdf 上（污染工作目录）
grDevices::pdf(NULL)

ids <- commandArgs(trailingOnly = TRUE)

# 一个样例的源文件：.rds 或 .RData/.rda 都算（导出时认哪种，校验就找哪种）
src_of <- function(id) {
  for (ext in c(".rds", ".RData", ".rda")) {
    f <- file.path("rds", paste0(id, ext))
    if (file.exists(f)) return(f)
  }
  NA_character_
}

# samples/index.json 是样例清单不是数据，别把它当 grob 树校验；同时要求有同名源文件，
# 否则 samples/ 里残留的旧 json 会让这个脚本莫名其妙地报错。
files <- if (length(ids)) ids else {
  fl   <- list.files("samples", pattern = "\\.json$", full.names = TRUE)
  keep <- vapply(tools::file_path_sans_ext(basename(fl)), function(id)
    id != "index" && !is.na(src_of(id)), logical(1))
  fl[keep]
}

# "$grobs[[15]]" -> list(field="grobs", i=15)
parse_seg <- function(seg) {
  m <- regmatches(seg, regexec("^\\$([a-zA-Z_][a-zA-Z0-9_.]*)\\[\\[([0-9]+)\\]\\]$", seg))[[1]]
  if (length(m) != 3) return(NULL)
  list(field = m[2], i = as.integer(m[3]))
}

# 名字末尾的 .NNN 是 grid 的全局自增计数，每画一次图就变一批，所以比较时要去掉。
# （这也正是这个功能存在的理由：按名字找 grob 不可靠，按路径下标才可靠。）
base_name <- function(x) sub("\\.[0-9]+$", "", as.character(x %||% ""))

ok_total <- 0L; bad_total <- 0L

for (f in files) {
  if (!file.exists(f)) { cat("[check_rpath] missing", f, "\n"); next }
  j <- jsonlite::fromJSON(f, simplifyDataFrame = TRUE)
  nd <- j$nodes
  if (is.null(nd) || !is.data.frame(nd)) { cat("[check_rpath] ", basename(f), " 里没有 nodes，跳过\n", sep = ""); next }
  id_of <- setNames(seq_len(nrow(nd)), nd$id)
  src <- src_of(j$meta$id)
  if (is.na(src)) { cat("[check_rpath] missing rds/", j$meta$id, ".rds|.RData 跳过\n"); next }
  # rpath 里写的根变量名来自 meta.root_var（sidecar 可改）。放进独立环境再 eval，
  # 免得那个名字恰好和本脚本的变量（nd/g/f…）撞上。
  rv <- if (!is.null(j$meta$root_var) && nzchar(j$meta$root_var)) j$meta$root_var else "tmp"
  env <- new.env(parent = globalenv())
  if (tolower(tools::file_ext(src)) %in% c("rdata", "rda")) {
    load(src, envir = env)              # .RData：整个工作区灌进来，根表达式里的对象名自然就在
  } else {
    assign(rv, readRDS(src), envir = env)
  }
  # 根对象照 meta.root_expr 求值 —— 那正是学生粘进 R 的那串（ggplotGrob(tmp) 或 fig.Merged$Plot）
  expr <- if (!is.null(j$meta$root_expr) && nzchar(j$meta$root_expr))
            j$meta$root_expr else paste0("ggplotGrob(", rv, ")")
  g <- tryCatch(eval(parse(text = expr), envir = env), error = function(e) {
    cat("   ✗ 根表达式求值失败 ", expr, ": ", conditionMessage(e), "\n", sep = ""); NULL })

  bad_seg <- 0L; bad_name <- 0L; bad_eval <- 0L; n_ok <- 0L
  obj_of <- vector("list", nrow(nd))

  for (k in seq_len(nrow(nd))) {
    node <- nd[k, ]
    if (is.na(node$parent) || !nzchar(node$rseg)) {
      obj <- g                                             # 根
    } else {
      pk <- id_of[[node$parent]]
      par <- nd[pk, ]
      # 1) rpath 拼接一致性
      if (!identical(paste0(par$rpath, node$rseg), node$rpath)) bad_seg <- bad_seg + 1L
      po <- obj_of[[pk]]
      sg <- parse_seg(node$rseg)
      obj <- if (is.null(po) || is.null(sg)) NULL else tryCatch(po[[sg$field]][[sg$i]], error = function(e) NULL)
    }
    obj_of[[k]] <- obj
    # 2) 取到的对象要和 JSON 里那个是同一个：名字（去掉自增编号）+ 类名都对得上
    got <- if (is.null(obj)) NA_character_ else base_name(obj$name)
    want <- base_name(node$name)
    # gclass 是「类别」而不是字面类名（titleGrob 这类容器统一记作 gTree），所以用 inherits 判
    cls_ok <- !is.null(obj) && inherits(obj, as.character(node$gclass))
    if (isTRUE(is.na(got)) || !identical(got, want) || !cls_ok) {
      bad_name <- bad_name + 1L
      if (bad_name <= 3) cat("   ✗ ", j$meta$id, " ", node$id, " rpath=", node$rpath,
                             " 取到 ", if (is.null(obj)) "<NULL>" else class(obj)[1],
                             " name=", got, " 期望 ", want,
                             if (!cls_ok) paste0(" 类不符(", node$gclass, ")") else "", "\n", sep = "")
    } else n_ok <- n_ok + 1L
  }

  # 3) 抽查完整 rpath 字符串 eval（含最深、最浅、随机若干）
  depth_order <- order(-nd$depth)
  pick <- unique(c(depth_order[1], depth_order[min(6, length(depth_order))],
                   sample.int(nrow(nd), min(6, nrow(nd)))))
  for (k in pick) {
    o <- tryCatch(eval(parse(text = nd$rpath[k]), envir = env), error = function(e) NULL)
    o2 <- obj_of[[k]]
    same <- !is.null(o) && !is.null(o2) && identical(class(o)[1], class(o2)[1]) &&
            identical(base_name(o$name), base_name(o2$name))
    if (!same) {
      bad_eval <- bad_eval + 1L
      cat("   ✗ eval 失败/不符: ", nd$rpath[k], "\n", sep = "")
    }
  }

  bad_total <- bad_total + bad_seg + bad_name + bad_eval
  ok_total <- ok_total + n_ok
  cat(sprintf("[check_rpath] %-8s 节点 %3d  命中 %3d  rseg拼接错 %d  名字不符 %d  eval抽查错 %d  (%s)\n",
              j$meta$id, nrow(nd), n_ok, bad_seg, bad_name, bad_eval,
              if (bad_seg + bad_name + bad_eval == 0) "OK" else "FAIL"))
}

cat(sprintf("[check_rpath] 合计命中 %d，问题 %d -> %s\n", ok_total, bad_total,
            if (bad_total == 0) "PASS" else "FAIL"))
quit(status = if (bad_total == 0) 0 else 2)
