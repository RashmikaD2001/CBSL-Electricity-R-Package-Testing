# CBSL access test
#
# Checks whether CBSL's website answers requests from the machine this runs on,
# using the same requests the daily update job will make:
#   1. listing page 0 loads and contains daily-indicator PDF links
#   2. listing page 1 (?page=1) loads too
#   3. the newest PDF downloads and really is a PDF
#
# Run it on your own PC first (it should pass), then on GitHub Actions.
# Exit status: 0 = every check passed, 1 = at least one failed.

for (pkg in c("httr", "rvest")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Install the '", pkg, "' package first: install.packages(\"", pkg, "\")")
  }
}

LISTING_URL <- "https://www.cbsl.gov.lk/en/statistics/economic-indicators/daily-indicators"
BASE_URL    <- "https://www.cbsl.gov.lk"
USER_AGENT  <- "Mozilla/5.0 (R research script)"
PDF_PATTERN <- "(daily_economic_indicators_|DEI_).*\\.pdf$"

or_else <- function(x, y) if (is.null(x)) y else x

# ---- helpers ---------------------------------------------------------------

results <- data.frame(check = character(0), result = character(0), detail = character(0))

record <- function(check, ok, detail) {
  result <- if (ok) "PASS" else "FAIL"
  results[nrow(results) + 1L, ] <<- c(check, result, detail)
  cat(sprintf("[%s] %s: %s\n", result, check, detail))
}

fetch <- function(url) {
  start <- Sys.time()
  resp <- tryCatch(
    httr::GET(url, httr::add_headers(`User-Agent` = USER_AGENT), httr::timeout(60)),
    error = function(e) e
  )
  list(resp = resp, secs = round(as.numeric(difftime(Sys.time(), start, units = "secs")), 1))
}

describe <- function(resp) {
  h <- httr::headers(resp)
  sprintf("HTTP %d, %s, %s bytes, server: %s",
          httr::status_code(resp),
          or_else(h[["content-type"]], "no content-type"),
          format(length(httr::content(resp, "raw")), big.mark = ","),
          or_else(h[["server"]], "unknown"))
}

body_text <- function(resp) {
  tryCatch(httr::content(resp, "text", encoding = "UTF-8"), error = function(e) "")
}

pdf_links <- function(resp) {
  html  <- rvest::read_html(body_text(resp))
  links <- rvest::html_attr(rvest::html_elements(html, "a"), "href")
  links <- unique(links[!is.na(links) & grepl(PDF_PATTERN, links, ignore.case = TRUE)])
  ifelse(startsWith(links, "http"), links, paste0(BASE_URL, links))
}

# A blocked request often still returns a page (a firewall or "checking your
# browser" page), so show the start of it when a check fails.
show_reply <- function(resp) {
  cat("  First 400 characters of the reply:\n  ",
      gsub("\\s+", " ", substr(body_text(resp), 1, 400)), "\n", sep = "")
}

check_listing <- function(name, url) {
  r <- fetch(url)
  if (inherits(r$resp, "error")) {
    record(name, FALSE, paste("no response:", conditionMessage(r$resp)))
    return(character(0))
  }
  links <- tryCatch(pdf_links(r$resp), error = function(e) character(0))
  ok <- httr::status_code(r$resp) == 200 && length(links) > 0
  record(name, ok, sprintf("%s, %d PDF links, %s s", describe(r$resp), length(links), r$secs))
  if (!ok) show_reply(r$resp)
  links
}

# ---- checks ----------------------------------------------------------------

cat("Machine:", Sys.info()[["sysname"]], "| R", as.character(getRversion()),
    "| time:", format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC"), "UTC\n\n")

links0 <- check_listing("Listing page 0", LISTING_URL)
Sys.sleep(1.5)
links1 <- check_listing("Listing page 1", paste0(LISTING_URL, "?page=1"))
if (length(links0) && length(links1) && identical(sort(links0), sort(links1))) {
  cat("  Note: page 1 shows the same links as page 0, so ?page= may not work.\n")
}

if (length(links0)) {
  Sys.sleep(1.5)
  url <- links0[1]
  r <- fetch(url)
  if (inherits(r$resp, "error")) {
    record("Download newest PDF", FALSE, paste("no response:", conditionMessage(r$resp)))
  } else {
    bytes  <- httr::content(r$resp, "raw")
    is_pdf <- length(bytes) > 4 && identical(rawToChar(bytes[1:4]), "%PDF")
    ok     <- httr::status_code(r$resp) == 200 && is_pdf
    record("Download newest PDF", ok,
           sprintf("%s: %s, real PDF: %s, %s s", basename(url), describe(r$resp),
                   if (is_pdf) "yes" else "no", r$secs))
    if (!ok) show_reply(r$resp)
  }
} else {
  record("Download newest PDF", FALSE, "skipped: no PDF link found on listing page 0")
}

# ---- summary ---------------------------------------------------------------

all_ok <- all(results$result == "PASS")
cat("\n", if (all_ok) {
  "RESULT: CBSL answers this machine. The daily job can run here."
} else {
  "RESULT: at least one check failed. See the details above."
}, "\n", sep = "")

# On GitHub Actions, also show the results on the run's summary page.
summary_file <- Sys.getenv("GITHUB_STEP_SUMMARY")
if (nzchar(summary_file)) {
  lines <- c("## CBSL access test", "",
             "| Check | Result | Detail |", "|---|---|---|",
             sprintf("| %s | %s | %s |", results$check, results$result,
                     gsub("|", "/", results$detail, fixed = TRUE)),
             "", if (all_ok) "**CBSL answers GitHub's servers.**" else "**At least one check failed.**")
  cat(lines, file = summary_file, sep = "\n", append = TRUE)
}

if (!interactive()) quit(status = if (all_ok) 0L else 1L)
