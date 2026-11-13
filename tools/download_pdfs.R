# Download CBSL Daily Economic Indicators PDFs for a range of dates, for a
# one-off rebuild on your own computer. (CBSL blocks GitHub's servers, so this
# does not run in the workflow.)
#
# Usage:  Rscript tools/download_pdfs.R <from> [to] [folder]
#         dates as YYYY-MM-DD; to defaults to today, folder to "cbsl_pdfs"
# e.g.    Rscript tools/download_pdfs.R 2022-08-04 2026-11-13 ../cbsl_pdfs
#
# Reads CBSL's listing pages (12 PDFs each, newest first) until it is past
# <from>, then downloads every PDF dated <from> to <to> into <folder>, oldest
# first, with CBSL's own file names (tools/process_inbox.R needs them).
# PDFs already in the folder are skipped, so it can be stopped and run again.
# Base R only; no packages needed.

LISTING_URL <- "https://www.cbsl.gov.lk/en/statistics/economic-indicators/daily-indicators"
CBSL_BASE   <- "https://www.cbsl.gov.lk"
USER_AGENT  <- "Mozilla/5.0 (cbslelectricity research script)"
PAUSE_S     <- 1.5               # pause between requests to CBSL
RETRY_WAITS <- c(10, 30, 60)     # seconds before each retry of a failed request

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L) stop("Usage: Rscript tools/download_pdfs.R <from YYYY-MM-DD> [to YYYY-MM-DD] [folder]")
from   <- as.Date(args[1L], format = "%Y-%m-%d")
to     <- if (length(args) >= 2L) as.Date(args[2L], format = "%Y-%m-%d") else Sys.Date()
folder <- if (length(args) >= 3L) args[3L] else "cbsl_pdfs"
if (is.na(from) || is.na(to) || from > to) stop("Give the dates as YYYY-MM-DD, <from> not after <to>.")
dir.create(folder, recursive = TRUE, showWarnings = FALSE)

# daily_economic_indicators_20220804_e.pdf or DEI_02_09_2020.pdf -> Date
pdf_date <- function(name) {
  m <- regmatches(name, regexpr("\\d{8}", name))
  if (length(m)) return(as.Date(m, format = "%Y%m%d"))
  m <- regmatches(name, regexpr("\\d{2}_\\d{2}_\\d{4}", name))
  if (length(m)) return(as.Date(m, format = "%d_%m_%Y"))
  as.Date(NA)
}

is_pdf <- function(path) {
  b <- readBin(path, "raw", 4L)
  length(b) == 4L && identical(rawToChar(b), "%PDF")
}

# Download url to dest; retries a failed request after RETRY_WAITS.
fetch <- function(url, dest, what) {
  for (attempt in 0:length(RETRY_WAITS)) {
    if (attempt > 0L) {
      message(sprintf("  %s failed; trying again in %d s", what, RETRY_WAITS[attempt]))
      Sys.sleep(RETRY_WAITS[attempt])
    }
    ok <- tryCatch(
      download.file(url, dest, mode = "wb", quiet = TRUE,
                    headers = c("User-Agent" = USER_AGENT)) == 0L,
      error = function(e) FALSE, warning = function(w) FALSE)
    if (ok && file.exists(dest) && file.size(dest) > 0) return(TRUE)
  }
  FALSE
}

# ---- 1. read the listing until it is past <from> -------------------------------

links <- list(); page <- 0L; prev_first <- ""
repeat {
  url <- if (page == 0L) LISTING_URL else paste0(LISTING_URL, "?page=", page)
  tmp <- tempfile(fileext = ".html")
  if (!fetch(url, tmp, sprintf("Listing page %d", page)))
    stop("Could not read CBSL listing page ", page,
         ". Check the site opens in your browser, then run the same command again.")
  html  <- paste(readLines(tmp, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  unlink(tmp)
  hrefs <- regmatches(html, gregexpr('href="[^"]*(daily_economic_indicators_|DEI_)[^"]*\\.pdf"',
                                     html, ignore.case = TRUE))[[1L]]
  hrefs <- unique(sub('"$', "", sub('^href="', "", hrefs)))
  if (!length(hrefs) || hrefs[1L] == prev_first) break      # past the last listing page
  prev_first <- hrefs[1L]

  names <- basename(hrefs)
  dates <- do.call(c, lapply(names, pdf_date))
  for (i in which(!is.na(dates) & dates >= from & dates <= to)) {
    links[[names[i]]] <- list(url = if (startsWith(hrefs[i], "http")) hrefs[i] else paste0(CBSL_BASE, hrefs[i]),
                              date = dates[i])
  }
  if (page %% 10L == 0L)
    message(sprintf("Listing page %d: %s to %s", page, min(dates, na.rm = TRUE), max(dates, na.rm = TRUE)))
  if (any(!is.na(dates) & dates < from)) break              # reached PDFs older than <from>
  page <- page + 1L
  Sys.sleep(PAUSE_S)
}
message(sprintf("Read %d listing page(s): %d PDF(s) dated %s to %s", page + 1L, length(links), from, to))

# ---- 2. download them, oldest first ---------------------------------------------

links <- links[order(vapply(links, function(l) format(l$date), ""))]
have  <- vapply(names(links), function(n) { p <- file.path(folder, n); file.exists(p) && is_pdf(p) }, logical(1))
message(sprintf("%d already in %s, %d to download", sum(have), folder, sum(!have)))

failed <- character(0); done <- 0L
for (name in names(links)[!have]) {
  dest <- file.path(folder, name)
  part <- paste0(dest, ".part")                # process_inbox.R ignores .part files
  if (fetch(links[[name]]$url, part, name) && is_pdf(part)) {
    file.rename(part, dest)
    done <- done + 1L
    if (done %% 50L == 0L) message(sprintf("  %d of %d downloaded (now at %s)", done, sum(!have), links[[name]]$date))
  } else {
    unlink(part)
    failed <- c(failed, name)
  }
  Sys.sleep(PAUSE_S)
}

message(sprintf("Downloaded %d, already there %d, failed %d. Folder: %s",
                done, sum(have), length(failed), normalizePath(folder)))
if (length(failed)) {
  message("Failed (run the same command again to retry only these):\n  ", paste(failed, collapse = "\n  "))
  quit(status = 1L)
}
