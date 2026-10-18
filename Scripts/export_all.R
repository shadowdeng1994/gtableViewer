#!/usr/bin/env Rscript
# ============================================================================
# export_all.R — 把 rds/ 下所有 .rds / .RData 一键导出为 samples/*.json（可展示数据）
# ----------------------------------------------------------------------------
# 用法（任意目录都行，脚本自己找 gtableViewer 根）:
#   Rscript Scripts/export_all.R                  # 扫描 rds/ 里的 .rds 和 .RData 全部重导
#   Rscript Scripts/export_all.R --skip-fresh     # 只导「源文件比 json 新」的
#   Rscript Scripts/export_all.R --clean          # 顺带删掉没有对应源文件的 json
#   Rscript Scripts/export_all.R --only=scatter,facet
#   Rscript Scripts/export_all.R rds/foo.rds      # 只导指定的文件
#   Rscript Scripts/export_all.R --list           # 只看会做什么，不动文件
#
# 吃什么输入:
#   * <id>.rds   : saveRDS(ggplot) 或 saveRDS(gtable)；画布默认 7x5 英寸，
#                  想换尺寸就在 sidecar 里写 size=8x6（单位用 size_unit 说）。
#   * <id>.RData : save(...) 的工作区快照。里面若是 list(Plot=, Size=) 这种图束
#                  （ggtree / patchwork 拼多 panel 后常见的存法），Plot 就是那张图，
#                  Size 就是画布尺寸（英寸）—— 有 Size 就按 Size 画，没有才用默认。
#                  一个 RData 里有多个对象时用 sidecar 的 plot=<对象名或 $路径> 指认。
#
# 新增一张图要怎么做：把 <id>.rds 或 <id>.RData 丢进 rds/ 再跑本脚本即可。想让它显示中文名，
# 在 rds/ 里放一个同名 sidecar 文本 rds/<id>.meta.txt（UTF-8 无 BOM，一行一个键）：
#
#   label=我的散点图 ggplot(mpg) + geom_point()
#   name=直方图 + 密度曲线
#   desc=geom_histogram 与 geom_density 叠在同一层
#   root=tmp
#   plot=fig.Merged$Plot
#   size=7x6.11
#   size_unit=in
#
# name 是下拉框里显示的名字，desc 是选中后的一行说明，label 写进 JSON 的 meta.label
# （name 缺省时用 label 顶上）；root 是学生 R 会话里那个对象的变量名，
# 「gtable 定位」会写成 ggplotGrob(root)$grobs[[...]] 或 fig.Merged$Plot$grobs[[...]]，
# 照抄就能在 R 里求值；plot / size / size_unit 只在 .RData（或想覆盖尺寸）时才用得上。
#
# 导出结束时还会写一份 samples/index.json（样例清单）。网站读它来填下拉框，所以
# 「丢一个 rds 进 rds/ → 跑本脚本 → 刷新页面就能选到」是通的，不用改前端代码。
#
# 为什么标签不写在命令行里：Windows PowerShell 往 Rscript 传中文参数容易乱码，
# 所以内置标签用 \uXXXX 转义（文件本身保持 ASCII），外部标签走 sidecar 文件。
#
# 注意：本文件不能带 BOM，否则 R 解析器会报 "unexpected input"。
# ============================================================================

# ---- 根目录与参数 -----------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
if (any(args %in% c("-h", "--help"))) {
  cat("用法: Rscript Scripts/export_all.R [.rds|.RData 文件...] [--skip-fresh] [--clean] [--only=id,id] [--list]\n")
  cat("输入: .rds（ggplot 或 gtable） / .RData（list(Plot=, Size=) 图束，Size 决定画布）\n")
  quit(status = 0)
}

root <- if (file.exists("Scripts/export_gtable.R")) getwd() else {
  ai <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(ai)) dirname(dirname(normalizePath(sub("^--file=", "", ai[1])))) else stop("找不到 Scripts/export_gtable.R")
}
setwd(root)
options(gtv.no_cli = TRUE)          # 阻止 export_gtable.R 的 CLI 段在 source 时执行
source("Scripts/export_gtable.R", local = FALSE, encoding = "UTF-8")

flag      <- function(f) any(args == f)
opt_value <- function(name) {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else NA_character_
}
SKIP_FRESH <- flag("--skip-fresh")
CLEAN      <- flag("--clean")
LIST_ONLY  <- flag("--list")
only <- opt_value("only")
ONLY <- if (!is.na(only)) trimws(strsplit(only, ",")[[1]]) else NULL

if (!dir.exists("samples")) dir.create("samples", recursive = TRUE)

# ---- 内置元数据（随仓库发布的三个样例，写死以免受编码问题影响）--------------
# label → 写进 JSON 的 meta.label；name/desc → 网站下拉框与说明行
BUILTIN <- list(
  scatter = list(label = "\u6563\u70b9\u56fe ggplot(mpg) + geom_point()", root = "tmp",
                 name  = "\u6563\u70b9\u56fe + \u56fe\u4f8b",
                 desc  = "\u5355\u4e2a panel\uff1a\u6570\u636e\u5c42\u3001\u7f51\u683c\u7ebf\u3001\u523b\u5ea6\u3001\u56fe\u4f8b\u952e"),
  boxplot = list(label = "\u7bb1\u7ebf\u56fe ToothGrowth + geom_boxplot()", root = "tmp",
                 name  = "\u7bb1\u7ebf\u56fe\uff08\u5206\u7c7b\u8f74\uff09",
                 desc  = "\u79bb\u6563 x \u8f74\u3001\u7ebf\u6bb5\u578b\u7f51\u683c\u3001\u6309\u7ec4\u7740\u8272"),
  facet   = list(label = "\u5206\u9762\u6563\u70b9 ggplot(diamonds) + facet_wrap", root = "tmp",
                 name  = "\u5206\u9762\u56fe\uff08facet_wrap\uff09",
                 desc  = "7 \u4e2a panel + strip \u6761\uff0cgtable \u5d4c\u5957\u6700\u4e30\u5bcc"),
  hist    = list(label = "\u76f4\u65b9\u56fe ggplot(faithful) + geom_histogram()", root = "tmp",
                 name  = "\u76f4\u65b9\u56fe + theme_minimal",
                 desc  = "geom_histogram \u67f1\u5b50\uff1arect \u7684 just \u662f left/top \u4e0d\u662f centre"),
  # .RData 图束这一例：源文件是 save(...) 的工作区快照（list(Plot=, Size=)），
  # 根变量名不用写 —— 装载层会直接用 RData 里那个对象的名字。
  RepresentativeTree = list(
                 label = "\u7ec4\u5408\u56fe ggtree\uff08.RData \u56fe\u675f\uff09", root = NA_character_,
                 name  = "\u7ec4\u5408\u5927\u56fe\uff08.RData + Size\uff09",
                 desc  = "33 \u4e2a grob \u7684 arrange \u5e03\u5c40\uff0c\u753b\u5e03\u5c3a\u5bf8\u53d6\u81ea RData \u91cc\u7684 Size")
)
META_KEYS <- c("label", "root", "name", "desc", "plot", "size", "size_unit")

# 输入文件扩展名（.rds 与 .RData 都算「一张图的源文件」）
SRC_EXT   <- "\\.(rds|rdata|rda)$"
src_ids   <- function() safe_id(tools::file_path_sans_ext(
  basename(list.files("rds", pattern = SRC_EXT, ignore.case = TRUE))))

# 读 rds/<id>.meta.txt：key=value，# 开头是注释；文件按 UTF-8 读
read_meta <- function(id) {
  f <- file.path("rds", paste0(id, ".meta.txt"))
  out <- setNames(rep(list(NA_character_), length(META_KEYS)), META_KEYS)
  if (!file.exists(f)) return(out)
  con <- file(f, open = "r", encoding = "UTF-8")
  ln <- readLines(con, warn = FALSE); close(con)
  ln <- ln[nzchar(trimws(ln)) & !grepl("^\\s*#", ln)]
  for (l in ln) {
    kv <- regmatches(l, regexec("^\\s*([A-Za-z_][A-Za-z0-9_.]*)\\s*=\\s*(.*)$", l))[[1]]
    if (length(kv) == 3) out[[kv[2]]] <- kv[3]
  }
  out
}

# 取元数据：sidecar 优先，其次内置表，最后兜底值。
# 注意 BUILTIN 里未必有那个键（比如 plot/size），[[ 取不到是 NULL，
# 而 is.na(NULL) 是逻辑零长，直接放进 if 会炸，所以先判 NULL。
pick_meta <- function(m, id, key, fallback) {
  if (!is.null(m[[key]]) && !is.na(m[[key]])) return(m[[key]])
  if (id %in% names(BUILTIN)) {
    v <- BUILTIN[[id]][[key]]
    if (!is.null(v) && !is.na(v)) return(v)
  }
  fallback
}

# id 必须是能当文件名用的安全串，否则 samples/ 里会写出奇怪的东西
safe_id <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

# ---- 收集任务 ---------------------------------------------------------------
explicit <- args[grepl(SRC_EXT, args, ignore.case = TRUE)]
bad <- explicit[!file.exists(explicit)]
if (length(bad)) stop("指定的输入文件不存在: ", paste(bad, collapse = ", "))
if (!length(explicit)) explicit <- list.files("rds", pattern = SRC_EXT, ignore.case = TRUE, full.names = TRUE)

jobs <- list()
seen <- character()
for (f in explicit) {
  id <- safe_id(tools::file_path_sans_ext(basename(f)))
  if (id %in% seen) { cat("[export_all] 跳过（id 重名）:", f, "\n"); next }
  if (!is.null(ONLY) && !(id %in% ONLY)) next
  seen <- c(seen, id)
  m <- read_meta(id)
  lab  <- pick_meta(m, id, "label", id)
  rv   <- pick_meta(m, id, "root",  NA_character_)   # 缺省交给装载层：.rds 用 tmp，.RData 用对象名
  name <- pick_meta(m, id, "name",  lab)
  desc <- pick_meta(m, id, "desc",  "")
  jobs[[length(jobs) + 1L]] <- list(rds = f, json = file.path("samples", paste0(id, ".json")),
                                    id = id, label = lab, root = rv, name = name, desc = desc,
                                    plot = pick_meta(m, id, "plot", NA_character_),
                                    size = pick_meta(m, id, "size", NA_character_),
                                    size_unit = pick_meta(m, id, "size_unit", "in"))
}

if (!length(jobs)) {
  cat("[export_all] rds/ 里没有可导出的 .rds / .RData —— 先跑 Scripts/make_samples.R，或把自己的图 saveRDS()/save() 进 rds/\n")
  quit(status = 0)
}

# ---- 执行 -------------------------------------------------------------------
stat <- data.frame(id = character(), nodes = integer(), leaves = integer(),
                   kb = numeric(), status = character(), stringsAsFactors = FALSE)
# 记一行汇总。别写 rbind(stat, list(...))：R 4.6 上对 0 行 data.frame 这么 rbind，
# 列名会变成 deparse 出来的值（"X.box." 之类），stat$id 直接变 NULL，汇总表静默空白。
add_stat <- function(id, nodes, leaves, kb, status) {
  stat <<- rbind(stat, data.frame(id = id, nodes = nodes, leaves = leaves, kb = kb,
                                  status = status, stringsAsFactors = FALSE))
}
t0 <- proc.time()[["elapsed"]]

for (j in jobs) {
  fresh <- file.exists(j$json) && file.mtime(j$json) > file.mtime(j$rds)
  if (SKIP_FRESH && fresh) {
    cat(sprintf("[export_all] 跳过（json 比 rds 新）: %s\n", j$id))
    add_stat(j$id, NA_integer_, NA_integer_, round(file.size(j$json) / 1024, 1), "skip")
    next
  }
  if (LIST_ONLY) {
    cat(sprintf("[export_all] 将导出 %s -> %s   (label=%s, root=%s%s%s)\n", j$rds, j$json, j$label,
                ifelse(is.na(j$root), "<自动>", j$root),
                if (is.na(j$size)) "" else paste0(", size=", j$size),
                if (is.na(j$plot)) "" else paste0(", plot=", j$plot)))
    add_stat(j$id, NA_integer_, NA_integer_, 0, "plan")
    next
  }
  res <- tryCatch({
    export_gtable(j$rds, j$json, j$id, j$label,
                  root_var = if (is.na(j$root)) NULL else j$root,
                  plot = j$plot, size = j$size, size_unit = j$size_unit)
    TRUE
  }, error = function(e) { cat("   !! ", j$id, " 导出失败: ", conditionMessage(e), "\n", sep = ""); FALSE })

  if (!res) { add_stat(j$id, NA_integer_, NA_integer_, 0, "FAIL"); next }

  # 回读一遍统计节点/叶子数（jsonlite 已是本项目依赖，几十 KB 的文件无所谓）
  n <- NA_integer_; l <- NA_integer_
  try({
    j2 <- jsonlite::fromJSON(j$json, simplifyDataFrame = FALSE)
    n <- length(j2$nodes)
    l <- sum(vapply(j2$nodes, function(nd) length(nd$prims) > 0, logical(1)))
  }, silent = TRUE)
  add_stat(j$id, n, l, round(file.size(j$json) / 1024, 1), "ok")
}

# ---- 样例清单 samples/index.json（网站靠它填下拉框）--------------------------
# 注意：清单始终按「rds/ 里现有的 + samples/ 里已存在的」全量生成，
# 不受 --only / --skip-fresh 影响，否则一次局部重导会把别的样例从下拉框里抹掉。
write_manifest <- function() {
  # 清单 = samples/ 里现有的每个 json（index 除外）。
  # 这里刻意不要求 rds/ 里有同名源文件：.RData 那种工作区快照常常不进仓库，
  # 但导出的 json 照样能上线展示；真要清掉没有源文件的 json，用 --clean。
  ids <- setdiff(src_ids(), "index")
  ids <- union(ids, setdiff(
    safe_id(tools::file_path_sans_ext(basename(list.files("samples", pattern = "\\.json$")))), "index"))
  ids <- ids[order(ifelse(ids %in% names(BUILTIN), match(ids, names(BUILTIN)), Inf), ids)]
  ids <- ids[vapply(ids, function(i) file.exists(file.path("samples", paste0(i, ".json"))), logical(1))]
  ent <- list()
  for (id in ids) {
    f <- file.path("samples", paste0(id, ".json"))
    m <- read_meta(id)
    n <- NA_integer_; l <- NA_integer_
    try({
      j <- jsonlite::fromJSON(f, simplifyDataFrame = FALSE)
      n <- length(j$nodes)
      l <- sum(vapply(j$nodes, function(nd) length(nd$prims) > 0, logical(1)))
    }, silent = TRUE)
    lab <- pick_meta(m, id, "label", id)
    ent[[length(ent) + 1L]] <- list(
      id = id,
      name = pick_meta(m, id, "name", lab),
      desc = pick_meta(m, id, "desc", ""),
      file = paste0(id, ".json"),
      nodes = n, leaves = l,
      kb = round(file.size(f) / 1024, 1)
    )
  }
  txt <- jsonlite::toJSON(ent, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
  # 直接写原始字节：Windows 上 R 的文本连接可能按本地代码页重编码，把中文写坏
  writeBin(charToRaw(paste0(enc2utf8(as.character(txt)), "\n")), "samples/index.json")
  cat("[export_all] 清单 samples/index.json 已更新：", length(ent), "个样例\n", sep = "")
}

# ---- 清理孤儿 json ----------------------------------------------------------
# 「孤儿」= samples/ 里有 json 但 rds/ 里没有同名 rds。注意不能按「本次任务列表」
# 判定：`--clean --only=scatter` 的本意是只重导 scatter，若按任务列表就会顺手把
# boxplot / facet / hist 全删了（清单也会跟着只剩一个）。
if (CLEAN && !LIST_ONLY) {
  ids_js  <- tools::file_path_sans_ext(basename(list.files("samples", pattern = "\\.json$")))
  ids_src <- src_ids()
  # 内置样例永不删：随仓库发布的 json 是成品，源文件（尤其 .RData 那种私人工作区快照）
  # 未必进仓库，克隆下来跑一次 --clean 不该把上线的样例删掉。
  orphans <- setdiff(ids_js, c(ids_src, "index", names(BUILTIN)))
  for (o in orphans) {
    unlink(file.path("samples", paste0(o, ".json")), force = TRUE)
    cat("[export_all] 删除孤儿 json:", o, ".json\n")
  }
}

if (!LIST_ONLY) write_manifest()

# ---- 汇总 -------------------------------------------------------------------
cat("\n[export_all] 汇总\n")
for (i in seq_len(nrow(stat))) {
  cat(sprintf("   %-18s %-6s 节点 %5s  叶子 %5s  %9.1f KB\n", stat$id[i], stat$status[i],
              ifelse(is.na(stat$nodes[i]), "-", stat$nodes[i]),
              ifelse(is.na(stat$leaves[i]), "-", stat$leaves[i]), stat$kb[i]))
}
fails <- sum(stat$status == "FAIL")
cat(sprintf("[export_all] %d 个任务，失败 %d，用时 %.1fs -> %s\n",
            nrow(stat), fails, proc.time()[["elapsed"]] - t0,
            if (fails == 0) "PASS" else "FAIL"))
if (!fails && !LIST_ONLY) {
  cat("[export_all] 下一步: Rscript Scripts/check_rpath.R  +  Scripts/build_preview.ps1（或直接双击 Scripts/run_all.bat）\n")
}
quit(status = if (fails) 2 else 0)
