# ============================================================
#  CBSL Daily Economic Indicators - PDF Downloader
#  Source : https://www.cbsl.gov.lk/en/statistics/economic-indicators/daily-indicators
# ============================================================

# -----------------------------------------------------------
# 0. Install / load required packages
# -----------------------------------------------------------
required_packages <- c("rvest", "httr", "stringr", "dplyr")

for (pkg in required_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    install.packages(pkg, repos = "https://cloud.r-project.org")
  }
  library(pkg, character.only = TRUE)
}

# -----------------------------------------------------------
# 1. Configuration
# -----------------------------------------------------------
BASE_URL     <- "https://www.cbsl.gov.lk"
LISTING_URL  <- paste0(BASE_URL, "/en/statistics/economic-indicators/daily-indicators")
SAVE_FOLDER  <- "daily_economic_indicators"
TOTAL_PAGES  <- 125
SLEEP_SEC    <- 1.5

# -----------------------------------------------------------
# 2. Create destination folder
# -----------------------------------------------------------
if (!dir.exists(SAVE_FOLDER)) {
  dir.create(SAVE_FOLDER, recursive = TRUE)
  cat("Created folder:", SAVE_FOLDER, "\n")
} else {
  cat("Folder already exists:", SAVE_FOLDER, "\n")
}

# -----------------------------------------------------------
# 3. Helper: extract PDF links from a single listing page
# -----------------------------------------------------------
get_pdf_links <- function(page_number) {
  url <- if (page_number == 0) {
    LISTING_URL
  } else {
    paste0(LISTING_URL, "?page=", page_number)
  }
  
  cat(sprintf("  Scraping page %d of %d : %s\n", page_number + 1, TOTAL_PAGES, url))
  
  response <- tryCatch({
    httr::GET(
      url,
      httr::add_headers(`User-Agent` = "Mozilla/5.0 (R research script)"),
      httr::timeout(30)
    )
  }, error = function(e) {
    warning("  [ERROR] Failed to fetch page ", page_number + 1, ": ", e$message)
    return(NULL)
  })
  
  if (is.null(response) || httr::status_code(response) != 200) {
    warning(sprintf("  [WARN]  Page %d returned status %s. Skipping.",
                    page_number + 1,
                    if (is.null(response)) "NULL" else httr::status_code(response)))
    return(character(0))
  }
  
  page_html <- httr::content(response, as = "text", encoding = "UTF-8")
  parsed    <- rvest::read_html(page_html)
  
  links <- parsed |>
    rvest::html_nodes("a") |>
    rvest::html_attr("href") |>
    na.omit() |>
    unique()
  
  pdf_links <- links[grepl("\\.pdf$", links, ignore.case = TRUE)]
  
  pdf_links <- ifelse(
    startsWith(pdf_links, "http"),
    pdf_links,
    paste0(BASE_URL, pdf_links)
  )
  
  return(pdf_links)
}

# -----------------------------------------------------------
# 4. Helper: download a single PDF
# -----------------------------------------------------------
download_pdf <- function(pdf_url, save_folder) {
  raw_filename   <- basename(pdf_url)
  clean_filename <- URLdecode(raw_filename)
  clean_filename <- stringr::str_remove(clean_filename, "\\?.*$")
  clean_filename <- stringr::str_replace_all(clean_filename, '[<>:"/\\|?*]', "_")
  
  dest_path <- file.path(save_folder, clean_filename)
  
  if (file.exists(dest_path) && file.size(dest_path) > 0) {
    cat(sprintf("    [SKIP]   Already exists: %s\n", clean_filename))
    return(invisible(dest_path))
  }
  
  tryCatch({
    response <- httr::GET(
      pdf_url,
      httr::add_headers(`User-Agent` = "Mozilla/5.0 (R research script)"),
      httr::write_disk(dest_path, overwrite = TRUE),
      httr::timeout(60)
    )
    
    if (httr::status_code(response) == 200) {
      size_kb <- round(file.size(dest_path) / 1024, 1)
      cat(sprintf("    [OK]     Downloaded: %-60s  (%s KB)\n", clean_filename, size_kb))
    } else {
      cat(sprintf("    [FAIL]   Status %d for: %s\n", httr::status_code(response), pdf_url))
      if (file.exists(dest_path)) file.remove(dest_path)
    }
  }, error = function(e) {
    cat(sprintf("    [ERROR]  %s  =>  %s\n", pdf_url, e$message))
    if (file.exists(dest_path)) file.remove(dest_path)
  })
  
  return(invisible(dest_path))
}

# -----------------------------------------------------------
# 5. Main loop: collect all PDF links
# -----------------------------------------------------------
all_pdf_urls <- character(0)
failed_pages <- integer(0)

cat("\n===== STEP 1: Collecting PDF links from all", TOTAL_PAGES, "pages =====\n\n")

for (page_idx in 0:(TOTAL_PAGES - 1)) {
  pdf_urls <- get_pdf_links(page_idx)
  
  if (length(pdf_urls) == 0) {
    cat(sprintf("  [WARN]  No PDFs found on page %d\n", page_idx + 1))
    failed_pages <- c(failed_pages, page_idx)
  } else {
    cat(sprintf("  Found %d PDF(s) on page %d\n", length(pdf_urls), page_idx + 1))
    all_pdf_urls <- c(all_pdf_urls, pdf_urls)
  }
  
  Sys.sleep(SLEEP_SEC)
}

all_pdf_urls <- unique(all_pdf_urls)
cat(sprintf("\nTotal unique PDFs found: %d\n", length(all_pdf_urls)))

# -----------------------------------------------------------
# 6. Download all PDFs
# -----------------------------------------------------------
cat("\n===== STEP 2: Downloading", length(all_pdf_urls), "PDFs =====\n\n")

for (i in seq_along(all_pdf_urls)) {
  cat(sprintf("[%d / %d] ", i, length(all_pdf_urls)))
  download_pdf(all_pdf_urls[i], SAVE_FOLDER)
  Sys.sleep(SLEEP_SEC)
}

# -----------------------------------------------------------
# 7. Summary
# -----------------------------------------------------------
downloaded_files <- list.files(SAVE_FOLDER, pattern = "\\.pdf$", ignore.case = TRUE)
total_size_mb    <- round(sum(file.size(file.path(SAVE_FOLDER, downloaded_files))) / 1024^2, 2)

cat("\n\n===== DOWNLOAD COMPLETE =====\n")
cat(sprintf("  Folder      : %s\n", normalizePath(SAVE_FOLDER)))
cat(sprintf("  PDFs saved  : %d\n", length(downloaded_files)))
cat(sprintf("  Total size  : %.2f MB\n", total_size_mb))

if (length(failed_pages) > 0) {
  cat(sprintf("  [WARN] Pages with issues: %s\n", paste(failed_pages + 1, collapse = ", ")))
}

cat("\nDone!\n")







# Count downloaded PDFs
files <- list.files("daily_economic_indicators", pattern = "\\.pdf$", ignore.case = TRUE)
cat("Total PDFs downloaded:", length(files), "\n")







# ============================================================
#  CBSL PDF Download Verifier
#  Run this AFTER the download script completes
# ============================================================

library(rvest)
library(httr)
library(stringr)

BASE_URL    <- "https://www.cbsl.gov.lk"
LISTING_URL <- paste0(BASE_URL, "/en/statistics/economic-indicators/daily-indicators")
SAVE_FOLDER <- "daily_economic_indicators"
TOTAL_PAGES <- 124
SLEEP_SEC   <- 1.5

# -----------------------------------------------------------
# STEP 1: Re-collect all expected PDF links from website
# -----------------------------------------------------------
cat("===== STEP 1: Re-scanning website for all PDF links =====\n\n")

expected_urls <- character(0)

for (page_idx in 0:(TOTAL_PAGES - 1)) {
  url <- if (page_idx == 0) LISTING_URL else paste0(LISTING_URL, "?page=", page_idx)
  cat(sprintf("  Checking page %d of %d ...\n", page_idx + 1, TOTAL_PAGES))
  
  response <- tryCatch({
    httr::GET(url,
              httr::add_headers(`User-Agent` = "Mozilla/5.0"),
              httr::timeout(30))
  }, error = function(e) NULL)
  
  if (!is.null(response) && httr::status_code(response) == 200) {
    page_html <- httr::content(response, as = "text", encoding = "UTF-8")
    parsed    <- rvest::read_html(page_html)
    
    links <- parsed |>
      rvest::html_nodes("a") |>
      rvest::html_attr("href") |>
      na.omit() |>
      unique()
    
    pdf_links <- links[grepl("\\.pdf$", links, ignore.case = TRUE)]
    pdf_links <- ifelse(startsWith(pdf_links, "http"),
                        pdf_links,
                        paste0(BASE_URL, pdf_links))
    
    expected_urls <- c(expected_urls, pdf_links)
  }
  
  Sys.sleep(SLEEP_SEC)
}

expected_urls <- unique(expected_urls)
cat(sprintf("\nTotal PDFs expected from website : %d\n", length(expected_urls)))

# -----------------------------------------------------------
# STEP 2: Get list of downloaded files
# -----------------------------------------------------------
downloaded_files <- list.files(SAVE_FOLDER,
                               pattern = "\\.pdf$",
                               ignore.case = TRUE,
                               full.names = FALSE)

cat(sprintf("Total PDFs found in folder       : %d\n\n", length(downloaded_files)))

# -----------------------------------------------------------
# STEP 3: Compare - find MISSING files
# -----------------------------------------------------------

# Extract expected filenames from URLs (same logic as downloader)
expected_filenames <- basename(expected_urls)
expected_filenames <- URLdecode(expected_filenames)
expected_filenames <- stringr::str_remove(expected_filenames, "\\?.*$")
expected_filenames <- stringr::str_replace_all(expected_filenames, '[<>:"/\\|?*]', "_")

missing_files <- expected_filenames[!expected_filenames %in% downloaded_files]
extra_files   <- downloaded_files[!downloaded_files %in% expected_filenames]

# -----------------------------------------------------------
# STEP 4: Check for CORRUPTED files (size = 0 KB)
# -----------------------------------------------------------
all_file_paths  <- file.path(SAVE_FOLDER, downloaded_files)
file_sizes      <- file.size(all_file_paths)
corrupted_files <- downloaded_files[file_sizes == 0 | is.na(file_sizes)]

# -----------------------------------------------------------
# STEP 5: Print Report
# -----------------------------------------------------------
cat("========================================\n")
cat("         VERIFICATION REPORT            \n")
cat("========================================\n")
cat(sprintf("  Expected (from website) : %d PDFs\n", length(expected_urls)))
cat(sprintf("  Downloaded (in folder)  : %d PDFs\n", length(downloaded_files)))
cat(sprintf("  Missing files           : %d\n",      length(missing_files)))
cat(sprintf("  Corrupted (0 KB) files  : %d\n",      length(corrupted_files)))
cat(sprintf("  Extra/unexpected files  : %d\n",      length(extra_files)))
cat("========================================\n\n")

# Show missing files
if (length(missing_files) > 0) {
  cat("🔴 MISSING FILES:\n")
  for (f in missing_files) cat("   -", f, "\n")
  cat("\n")
  
  # Show their original URLs for re-downloading
  cat("URLs to re-download:\n")
  missing_idx <- which(expected_filenames %in% missing_files)
  for (url in expected_urls[missing_idx]) cat("   ", url, "\n")
} else {
  cat("✅ No missing files! All PDFs downloaded.\n")
}

# Show corrupted files
if (length(corrupted_files) > 0) {
  cat("\n🟡 CORRUPTED FILES (0 KB - need re-download):\n")
  for (f in corrupted_files) cat("   -", f, "\n")
} else {
  cat("✅ No corrupted files found.\n")
}

# -----------------------------------------------------------
# STEP 6: Auto Re-download missing/corrupted files
# -----------------------------------------------------------
files_to_redownload <- c(
  expected_urls[expected_filenames %in% missing_files],
  expected_urls[expected_filenames %in% corrupted_files]
)

if (length(files_to_redownload) > 0) {
  cat(sprintf("\n===== Re-downloading %d missing/corrupted files =====\n",
              length(files_to_redownload)))
  
  for (url in files_to_redownload) {
    fname <- URLdecode(basename(url))
    fname <- stringr::str_replace_all(fname, '[<>:"/\\|?*]', "_")
    dest  <- file.path(SAVE_FOLDER, fname)
    
    cat("  Downloading:", fname, "\n")
    tryCatch({
      httr::GET(url,
                httr::add_headers(`User-Agent` = "Mozilla/5.0"),
                httr::write_disk(dest, overwrite = TRUE),
                httr::timeout(60))
    }, error = function(e) cat("  [ERROR]:", e$message, "\n"))
    
    Sys.sleep(SLEEP_SEC)
  }
  cat("Re-download complete!\n")
} else {
  cat("\n🎉 Everything is complete! No re-downloads needed.\n")
}
