# Parse the PDFs waiting in the inbox folder and update the published data.
#
# Usage:  Rscript tools/process_inbox.R [inbox_dir] [csv_file]
#         defaults: inbox  inst/extdata/electricity.csv
#
# Reads    <inbox_dir>/*.pdf   (downloaded from the "inbox" release by the workflow)
# Updates, in the folder of <csv_file>:
#   <csv_file>                        FULL DATA: one row per PDF, for the PDF's own
#                                     day: energy, peak and the source percentages
#   electricity_energy_peak_data.csv  ENERGY AND PEAK ONLY, for every day a PDF
#                                     shows: the days above, plus the "day before"
#                                     column (Sundays and holidays, from 4 Aug 2022)
#   electricity_meta.json             last date, rows and md5 of both files, and the
#                                     last PDF processed (created on the first run)
#   problems.csv                      every PDF that needed a safeguard
# Writes   <inbox_dir>/problem_files.txt  PDFs to park in the "problems" release
#
# The PDFs are handled one at a time, oldest first:
#   * the PDF's own day goes into the full data: added, or replaces that date
#   * the "day before" column (PDFs from 4 Aug 2022 on show two dates) goes into
#     the energy-and-peak data only, and only for a date neither file has yet
# For every date in the full data, the energy-and-peak data repeats its energy
# and peak, so the two files never disagree (also after a correction by hand).
#
# Dates are written as YYYY-MM-DD. A CSV saved by Excel as m/d/yyyy (e.g.
# 11/5/2026) is read correctly and converted on the next write.
#
# Safeguards (the feed is never blocked by one bad PDF, and nothing is guessed):
#   * no date or no total energy        -> row skipped, logged
#   * energy or peak outside its range  -> that value left empty, logged
#   * percentages do not sum to ~100 or
#     labels and numbers do not match   -> percentages left empty, logged
#   * a problem row never replaces a row already in the full data
#
# Also run with an empty inbox: it then only rewrites what differs, e.g. the
# meta file after the CSV was corrected by hand, so clients see the change.

args     <- commandArgs(trailingOnly = TRUE)
inbox    <- if (length(args) >= 1L) args[1L] else "inbox"
csv_path <- if (length(args) >= 2L) args[2L] else "inst/extdata/electricity.csv"
extdata  <- dirname(csv_path)

this_file <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
tools_dir <- if (length(this_file)) dirname(this_file[1L]) else "tools"
source(file.path(tools_dir, "extract_electricity_data.R"))

CSV_COLS <- c("date", "total_energy_gwh", "peak_demand_mw",
              "pct_hydro", "pct_thermal", "pct_coal",
              "pct_wind", "pct_solar", "pct_biomass")
EP_COLS  <- c("date", "total_energy_gwh", "peak_demand_mw")
PCT_COLS <- grep("^pct_", CSV_COLS, value = TRUE)
PDF_RE   <- "^(daily_economic_indicators_\\d{8}_e|DEI_\\d{2}_\\d{2}_\\d{4})\\.pdf$"

ep_path   <- file.path(extdata, "electricity_energy_peak_data.csv")
meta_path <- file.path(extdata, "electricity_meta.json")
prob_path <- file.path(extdata, "problems.csv")
dir.create(extdata, recursive = TRUE, showWarnings = FALSE)

# ---- current state ------------------------------------------------------------

read_data <- function(path, cols) {
  if (!file.exists(path)) {
    out <- as.data.frame(setNames(replicate(length(cols), numeric(0), simplify = FALSE), cols))
    out$date <- as.Date(character(0))
    return(out)
  }
  d <- read.csv(path, colClasses = c(date = "character"), stringsAsFactors = FALSE)
  missing <- setdiff(cols, names(d))
  if (length(missing)) stop(path, " is missing column(s): ", paste(missing, collapse = ", "))
  d$date <- parse_csv_dates(d$date)
  d[, cols]
}

# YYYY-MM-DD, or m/d/yyyy as Excel saves it. Stops rather than guess.
parse_csv_dates <- function(x) {
  x   <- trimws(x)
  out <- as.Date(x, format = "%Y-%m-%d")
  us  <- is.na(out) & grepl("^\\d{1,2}/\\d{1,2}/\\d{4}$", x)
  out[us] <- as.Date(x[us], format = "%m/%d/%Y")
  if (any(us)) cat("Converting Excel dates (m/d/yyyy) to YYYY-MM-DD.\n")
  bad <- is.na(out) & nzchar(x)
  if (any(bad)) stop("Unreadable date(s) in the CSV, e.g. '", x[bad][1L],
                     "'. Use YYYY-MM-DD or m/d/yyyy.")
  out
}

meta_field <- function(field) {
  if (!file.exists(meta_path)) return(NA_character_)
  txt <- paste(readLines(meta_path, warn = FALSE), collapse = "")
  m <- regmatches(txt, regexec(sprintf('"%s"\\s*:\\s*"([^"]*)"', field), txt))[[1L]]
  if (length(m) == 2L) m[2L] else NA_character_
}

old    <- read_data(csv_path, CSV_COLS)
old_ep <- read_data(ep_path, EP_COLS)
last_pdf_date <- meta_field("last_pdf_date")
# First run on an existing CSV (no meta file yet): continue after its last date.
if ((is.na(last_pdf_date) || !nzchar(last_pdf_date)) && nrow(old)) {
  last_pdf_date <- format(max(old$date))
}

# ---- parse the inbox, one PDF at a time ---------------------------------------

pdfs <- list.files(inbox, pattern = PDF_RE, full.names = TRUE, ignore.case = TRUE)
pdfs <- pdfs[order(vapply(basename(pdfs), function(f) format(date_from_filename(f)), ""))]
cat(sprintf("PDFs in inbox: %d\n", length(pdfs)))

problems <- data.frame(date = character(0), source_file = character(0),
                       reason = character(0), logged_at = character(0))
log_problem <- function(date, file, reason) {
  problems[nrow(problems) + 1L, ] <<- c(if (is.na(date)) "" else format(date), file, reason,
                                         format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC"))
}

out   <- old                                     # the full data, growing one PDF at a time
extra <- old_ep[!old_ep$date %in% old$date, ]    # days only the energy-and-peak data has
n_added <- 0L; n_replaced <- 0L; n_extra <- 0L

in_full  <- function(d) any(out$date == d)
in_extra <- function(d) any(extra$date == d)

# Energy or peak outside its range: that value left empty, logged.
check_ranges <- function(row, name, label = "") {
  if (!is.na(row$total_energy_gwh) && (row$total_energy_gwh < 5 || row$total_energy_gwh > 300)) {
    log_problem(row$date, name, sprintf("%stotal energy %s GWh outside 5-300; left empty", label, row$total_energy_gwh))
    row$total_energy_gwh <- NA
  }
  if (!is.na(row$peak_demand_mw) && (row$peak_demand_mw < 300 || row$peak_demand_mw > 10000)) {
    log_problem(row$date, name, sprintf("%speak demand %s MW outside 300-10000; left empty", label, row$peak_demand_mw))
    row$peak_demand_mw <- NA
  }
  row
}

# The PDF's own day -> full data: added, or replaces the row for that date,
# except that a problem row never replaces a row already there.
add_own_date <- function(row, name) {
  if (is.na(row$date) || is.na(row$total_energy_gwh)) {
    log_problem(row$date, name, paste("skipped: no date or total energy found;",
                                      if (is.na(row$note)) "" else row$note))
    return(invisible())
  }
  if (row$date > Sys.Date() + 1L) {
    log_problem(row$date, name, "skipped: date is in the future")
    return(invisible())
  }
  row <- check_ranges(row, name)
  if (!is.na(row$note)) {
    log_problem(row$date, name, paste("percentages left empty:", row$note))
    row[PCT_COLS] <- NA
  }
  ok <- is.na(row$note) && !is.na(row$total_energy_gwh) && !is.na(row$peak_demand_mw)
  i <- which(out$date == row$date)
  if (length(i)) {
    if (!ok) return(invisible())
    out[i, CSV_COLS] <<- row[, CSV_COLS]
    n_replaced <<- n_replaced + 1L
  } else {
    out <<- rbind(out, row[, CSV_COLS])
    n_added <<- n_added + 1L
  }
}

# The "day before" column -> energy-and-peak data only, for a new date only.
add_day_before <- function(row, name) {
  if (is.na(row$date) || in_full(row$date) || in_extra(row$date)) return(invisible())
  row <- check_ranges(row, name, "day-before column: ")
  if (is.na(row$total_energy_gwh) && is.na(row$peak_demand_mw)) return(invisible())
  extra <<- rbind(extra, row[, EP_COLS])
  n_extra <<- n_extra + 1L
}

for (f in pdfs) {
  name <- basename(f)
  rows <- tryCatch(extract_electricity_data(f),
                   error = function(e) empty_row(name, note = conditionMessage(e)))
  add_own_date(rows[!rows$is_previous, , drop = FALSE][1L, ], name)
  prev <- rows[rows$is_previous, , drop = FALSE]
  if (nrow(prev)) add_day_before(prev[1L, ], name)
}

out <- out[order(out$date), ]
rownames(out) <- NULL
# A day that has since got its own PDF takes its values from the full data.
extra <- extra[!extra$date %in% out$date, ]
ep    <- rbind(out[, EP_COLS], extra)
ep    <- ep[order(ep$date), ]
rownames(ep) <- NULL

# ---- write ------------------------------------------------------------------

# Files are written with "\n" line ends on every system (through a binary
# connection), so a run on Windows gives the same bytes, and the same md5, as a
# run on GitHub.
write_lf <- function(path, writer, append = FALSE) {
  con <- file(path, if (append) "ab" else "wb")
  on.exit(close(con))
  writer(con)
}

# Writes the CSV only when its bytes would change (this also converts a file
# saved by Excel or checked out with Windows line ends). TRUE if it changed.
write_csv_if_changed <- function(df, path) {
  df$date <- format(df$date, "%Y-%m-%d")
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp))
  write_lf(tmp, function(con) write.csv(df, con, row.names = FALSE, na = ""))
  if (file.exists(path) && unname(tools::md5sum(tmp)) == unname(tools::md5sum(path))) return(FALSE)
  file.copy(tmp, path, overwrite = TRUE)
  TRUE
}

full_changed <- write_csv_if_changed(out, csv_path)
ep_changed   <- write_csv_if_changed(ep, ep_path)

md5    <- unname(tools::md5sum(csv_path))
ep_md5 <- unname(tools::md5sum(ep_path))
pdf_dates <- vapply(basename(pdfs), function(f) format(date_from_filename(f)), "")
pdf_dates <- c(last_pdf_date, pdf_dates)
pdf_dates <- pdf_dates[!is.na(pdf_dates) & nzchar(pdf_dates)]
new_last_pdf <- if (length(pdf_dates)) max(pdf_dates) else ""

if (full_changed || ep_changed ||
    !identical(meta_field("md5"), md5) || !identical(meta_field("energy_peak_md5"), ep_md5) ||
    !identical(meta_field("last_pdf_date"), new_last_pdf)) {
  last_of <- function(d) if (nrow(d)) format(max(d$date)) else ""
  meta <- sprintf(paste0(
    '{"last_date": "%s", "rows": %d, "md5": "%s", "updated": "%s", "last_pdf_date": "%s", ',
    '"energy_peak_last_date": "%s", "energy_peak_rows": %d, "energy_peak_md5": "%s"}'),
    last_of(out), nrow(out), md5, format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    new_last_pdf, last_of(ep), nrow(ep), ep_md5)
  write_lf(meta_path, function(con) writeLines(meta, con))
  cat("Meta file updated.\n")
}

problem_files <- unique(problems$source_file)
write_lf(file.path(inbox, "problem_files.txt"), function(con) writeLines(problem_files, con))
if (nrow(problems)) {
  had_problems <- file.exists(prob_path)
  write_lf(prob_path, append = had_problems, function(con)
    write.table(problems, con, sep = ",", row.names = FALSE, qmethod = "double", col.names = !had_problems))
}

cat(sprintf("Full data: %d added, %d replaced, %d rows, last date %s\n",
            n_added, n_replaced, nrow(out), if (nrow(out)) format(max(out$date)) else "none"))
cat(sprintf("Energy-and-peak data: %d day(s) added from a day-before column, %d rows\n",
            n_extra, nrow(ep)))
if (nrow(problems)) {
  cat("\nPROBLEMS (logged in problems.csv):\n")
  print(problems[, c("date", "source_file", "reason")], row.names = FALSE)
}
