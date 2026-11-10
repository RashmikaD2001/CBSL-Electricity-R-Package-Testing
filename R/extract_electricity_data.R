# =============================================================================
# Daily Economic Indicators — Electricity Generation Data Extractor
# Central Bank of Sri Lanka (CBSL) PDFs
# =============================================================================
# The PDFs have a real text layer (no OCR needed), but every word is stored as
# small overlapping pieces ("Tot" "al" "Ener" "gy").  Text-mode extraction
# (pdf_text / pdftotext -layout) staggers those pieces over several lines, so
# instead we take each piece's position from pdftools::pdf_data() and rebuild
# the rows ourselves:
#   * pieces whose vertical centres are within Y_TOL points form one row
#   * within a row, pieces that touch or overlap are glued into one word
#
# The "Electricity Generation" box is in the right-hand column, so only words
# at or right of the "Total Energy" / "Peak Demand" labels are used.
#
# The source percentages are pie-chart labels.  They are listed top-to-bottom
# in the same order as the legend (Coal, Oil, Hydro, Wind, Solar, ...), so we
# pair them by position and check that they add up to ~100.
#
# REQUIRES: install.packages("pdftools")
# =============================================================================

# ─── USER SETTINGS ────────────────────────────────────────────────────────────
pdf_folder <- "daily_economic_indicators"
output_csv <- file.path(pdf_folder, "electricity_generation_data.csv")
Y_TOL      <- 3     # points; pieces closer than this vertically share a row
GLUE_GAP   <- 1.5   # points; pieces closer than this horizontally form a word
# ──────────────────────────────────────────────────────────────────────────────

if (!requireNamespace("pdftools", quietly = TRUE))
  stop("Package 'pdftools' is not installed. Run: install.packages('pdftools')")


# =============================================================================
# REBUILD ROWS FROM pdf_data() POSITIONS
# =============================================================================

# Glue the pieces of one row into words; returns data.frame(x, text)
merge_words <- function(row) {
  row  <- row[order(row$x), ]
  x    <- row$x[1L]; x_end <- row$x[1L] + row$width[1L]; text <- row$text[1L]
  out_x <- numeric(0); out_text <- character(0)
  if (nrow(row) > 1L) {
    for (i in 2:nrow(row)) {
      if (row$x[i] - x_end < GLUE_GAP) {
        text  <- paste0(text, row$text[i])
        x_end <- max(x_end, row$x[i] + row$width[i])
      } else {
        out_x <- c(out_x, x); out_text <- c(out_text, text)
        x <- row$x[i]; x_end <- row$x[i] + row$width[i]; text <- row$text[i]
      }
    }
  }
  data.frame(x = c(out_x, x), text = c(out_text, text), stringsAsFactors = FALSE)
}

# Returns a list of rows (top to bottom), each a data.frame(x, text)
read_rows <- function(pdf_path) {
  pages <- pdftools::pdf_data(pdf_path)
  rows  <- list()
  for (pg in pages) {
    if (nrow(pg) == 0L) next
    pg$cy <- pg$y + pg$height / 2
    pg    <- pg[order(pg$cy, pg$x), ]

    # Start a new row when the centre moves more than Y_TOL below the row start
    row_id <- integer(nrow(pg)); id <- 1L; start <- pg$cy[1L]
    for (i in seq_len(nrow(pg))) {
      if (pg$cy[i] - start > Y_TOL) { id <- id + 1L; start <- pg$cy[i] }
      row_id[i] <- id
    }
    rows <- c(rows, lapply(split(pg, row_id), merge_words))
  }
  unname(rows)
}

row_text <- function(row, min_x = -Inf) paste(row$text[row$x >= min_x], collapse = " ")


# =============================================================================
# HELPERS
# =============================================================================

# Remove spaces so "Total Energy (GWh)" and "TotalEnergy(GWh)" both match
compact <- function(x) gsub("\\s+", "", x)

find_line <- function(lines, pattern, from = 1L) {
  if (from > length(lines)) return(NA_integer_)
  hit <- which(grepl(pattern, compact(lines[from:length(lines)]),
                     ignore.case = TRUE, perl = TRUE))
  if (length(hit) == 0L) NA_integer_ else from + hit[1L] - 1L
}

extract_numbers <- function(text, pattern) {
  raw <- regmatches(text, gregexpr(pattern, text, perl = TRUE))
  suppressWarnings(as.numeric(gsub(",", "", unlist(raw))))
}

# Dates printed as 03-May-21 / 03-Aug-2022 / 03 Aug 2022
extract_dates <- function(text) {
  pat <- "\\b\\d{1,2}[- ][A-Za-z]{3}[- ]\\d{2,4}\\b"
  raw <- unlist(regmatches(text, gregexpr(pat, text, perl = TRUE)))
  if (length(raw) == 0L) return(as.Date(character(0)))
  raw <- gsub(" ", "-", raw)
  d <- suppressWarnings(as.Date(raw, "%d-%b-%y"))
  long <- nchar(sub(".*-", "", raw)) == 4L
  d[long] <- suppressWarnings(as.Date(raw[long], "%d-%b-%Y"))
  d[!is.na(d)]
}

date_from_filename <- function(fname) {
  # daily_economic_indicators_20200902_e.pdf
  m <- regmatches(fname, regexpr("\\d{8}", fname))
  if (length(m) == 1L) {
    d <- suppressWarnings(as.Date(m, "%Y%m%d"))
    if (!is.na(d)) return(d)
  }
  # DEI_02_09_2020.pdf
  m <- regmatches(fname, regexpr("\\d{2}_\\d{2}_\\d{4}", fname))
  if (length(m) == 1L) return(suppressWarnings(as.Date(m, "%d_%m_%Y")))
  as.Date(NA)
}

# Legend labels, in the order they are searched for on a (space-stripped) line.
# Longer names come first so "ThermalCoal" is not read as just "Coal".
LEGEND_PATTERNS <- c(
  coal    = "Thermal\\W*Coal|Coal",
  thermal = "Thermal\\W*Oil|Oil",
  hydro   = "Mini\\W*Hydro|Hydro",
  wind    = "Wind",
  solar   = "Solar",
  biomass = "Biomass|Bio\\W*mass",
  other   = "Other"
)

find_legend <- function(text) {
  pat <- paste0("(", paste(LEGEND_PATTERNS, collapse = "|"), ")")
  hits <- unlist(regmatches(text, gregexpr(pat, text, ignore.case = TRUE, perl = TRUE)))
  vapply(hits, function(h) {
    names(LEGEND_PATTERNS)[which(vapply(
      LEGEND_PATTERNS,
      function(p) grepl(paste0("^(", p, ")$"), h, ignore.case = TRUE, perl = TRUE),
      logical(1)
    ))[1L]]
  }, character(1), USE.NAMES = FALSE)
}


# =============================================================================
# MAIN EXTRACTION FUNCTION
# =============================================================================

empty_row <- function(fname, date = as.Date(NA), note = NA_character_) {
  data.frame(
    date             = date,
    total_energy_gwh = NA_real_,
    peak_demand_mw   = NA_real_,
    pct_hydro        = NA_real_,
    pct_thermal      = NA_real_,
    pct_coal         = NA_real_,
    pct_wind         = NA_real_,
    pct_solar        = NA_real_,
    pct_biomass      = NA_real_,
    pct_total        = NA_real_,
    source_file      = fname,
    note             = note,
    stringsAsFactors = FALSE
  )
}

extract_electricity_data <- function(pdf_path) {

  fname <- basename(pdf_path)
  rows  <- read_rows(pdf_path)
  if (length(rows) == 0L) return(empty_row(fname, note = "unreadable PDF"))
  lines <- vapply(rows, row_text, character(1))

  # 1. Locate the section: heading -> "Source: Ceylon Electricity Board"
  head_i <- find_line(lines, "ElectricityGeneration")
  if (is.na(head_i)) return(empty_row(fname, date_from_filename(fname),
                                      note = "no electricity section"))
  end_i <- find_line(lines, "Source.*(CeylonElectricity|CEB)", head_i + 1L)
  if (is.na(end_i)) end_i <- min(head_i + 30L, length(lines))

  # 2. Keep only the right-hand column: words at or right of the
  #    "Total Energy" / "Peak Demand" labels (or the heading if those are missing)
  blk_rows <- rows[head_i:end_i]
  label_x  <- unlist(lapply(blk_rows, function(r) r$x[grepl("^(Total|Peak)", r$text, ignore.case = TRUE)]))
  if (length(label_x) == 0L)
    label_x <- rows[[head_i]]$x[grepl("^Electricity", rows[[head_i]]$text, ignore.case = TRUE)]
  col   <- min(label_x) - 5
  block <- vapply(blk_rows, row_text, character(1), min_x = col)

  pct_i <- find_line(block, "Percent|\\(%\\)")
  if (is.na(pct_i)) pct_i <- length(block)
  top <- block[1:pct_i]                 # date, total energy, peak demand
  pie <- block[pct_i:length(block)]     # legend + pie-slice percentages

  # 3. Date: the latest date in the section (recent PDFs show two dates)
  dates <- extract_dates(paste(top, collapse = " "))
  date  <- if (length(dates) > 0L) max(dates) else date_from_filename(fname)

  # 4. Total energy (GWh) and peak demand (MW) are the 2-decimal numbers in
  #    the top part.  They are told apart by size.  When two dates are shown
  #    the latest value is printed last, so take the last one.
  big <- extract_numbers(paste(top, collapse = " "), "(?<![\\d.,])\\d{1,3}(?:,\\d{3})*\\.\\d{2}(?!\\d)")
  energy <- big[big >= 5 & big < 300]
  peak   <- big[big >= 300 & big < 10000]

  # 5. Percentages: 1-2 decimal numbers in the pie area, matched to the
  #    legend in the order both appear on the page.
  legend <- unlist(lapply(compact(pie), find_legend))
  pct    <- unlist(lapply(pie, extract_numbers,
                          "(?<![\\d.,])\\d{1,3}\\.\\d{1,2}(?![\\d.])"))
  pct    <- pct[pct <= 100]

  row <- empty_row(fname, date)
  row$total_energy_gwh <- if (length(energy)) tail(energy, 1L) else NA_real_
  row$peak_demand_mw   <- if (length(peak))   tail(peak, 1L)   else NA_real_

  if (length(legend) > 0L && length(pct) == length(legend)) {
    sums <- tapply(pct, legend, sum)          # e.g. Hydro + Mini Hydro
    for (src in intersect(names(sums), c("hydro", "thermal", "coal", "wind", "solar", "biomass")))
      row[[paste0("pct_", src)]] <- unname(sums[src])
    row$pct_total <- round(sum(pct), 1)
    if (abs(row$pct_total - 100) > 1.5) row$note <- "percentages do not sum to 100"
  } else {
    row$note <- sprintf("found %d legend labels but %d percentages",
                        length(legend), length(pct))
  }
  row
}

# Print what the parser sees for one PDF - useful when a file lands in
# the problems CSV.  Example: debug_pdf("daily_economic_indicators/xxx.pdf")
debug_pdf <- function(pdf_path) {
  lines  <- vapply(read_rows(pdf_path), row_text, character(1))
  head_i <- find_line(lines, "ElectricityGeneration")
  if (is.na(head_i)) {
    cat("No 'Electricity Generation' heading. First 40 rows:\n")
    writeLines(head(lines, 40))
  } else {
    writeLines(lines[head_i:min(head_i + 30L, length(lines))])
  }
  print(extract_electricity_data(pdf_path))
}


# =============================================================================
# BATCH PROCESSING
# =============================================================================

extract_electricity_folder <- function(folder = pdf_folder, output = output_csv) {
  pdf_files <- list.files(folder,
                          pattern = "^(daily_economic_indicators_\\d{8}_e|DEI_\\d{2}_\\d{2}_\\d{4})\\.pdf$",
                          full.names = TRUE, ignore.case = TRUE)
  if (length(pdf_files) == 0L) stop("No daily indicator PDFs found in: ", folder)
  cat(sprintf("Found %d PDF files.\n", length(pdf_files)))

  rows <- lapply(seq_along(pdf_files), function(i) {
    if (i %% 100L == 0L) cat(sprintf("  Processing %d / %d ...\n", i, length(pdf_files)))
    tryCatch(
      extract_electricity_data(pdf_files[i]),
      error = function(e) empty_row(basename(pdf_files[i]), note = conditionMessage(e))
    )
  })
  all_rows <- do.call(rbind, rows)

  # Rows that failed are kept in a separate file for checking by hand
  problems <- all_rows[!is.na(all_rows$note) | is.na(all_rows$date), ]
  if (nrow(problems) > 0L) {
    problem_csv <- sub("\\.csv$", "_problems.csv", output)
    write.csv(problems, problem_csv, row.names = FALSE)
    cat(sprintf("%d file(s) need checking -> %s\n", nrow(problems), problem_csv))
    print(table(problems$note, useNA = "ifany"))
  }

  # One row per date: prefer a row without problems
  out <- all_rows[!is.na(all_rows$date), ]
  out <- out[order(out$date, !is.na(out$note)), ]
  out <- out[!duplicated(out$date), ]
  rownames(out) <- NULL

  csv <- out[, c("date", "total_energy_gwh", "peak_demand_mw",
                 "pct_hydro", "pct_thermal", "pct_coal",
                 "pct_wind", "pct_solar", "pct_biomass")]
  write.csv(csv, output, row.names = FALSE, na = "")

  cat(sprintf("Rows written : %d (%s to %s)\n", nrow(out), min(out$date), max(out$date)))
  cat(sprintf("Saved to     : %s\n", normalizePath(output)))
  invisible(out)
}


# Run when the script is sourced directly
if (sys.nframe() == 0L || interactive()) {
  results_df <- extract_electricity_folder()
  print(head(results_df), row.names = FALSE)
}
