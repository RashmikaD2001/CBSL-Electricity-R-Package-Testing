# Confirm package root
repo_path <- getwd()

# Create package folders
folders <- c(
  "R",
  "man",
  "scripts",
  "inst/extdata",
  "tests/testthat"
)

for (folder in folders) {
  dir.create(
    file.path(repo_path, folder),
    recursive = TRUE,
    showWarnings = FALSE
  )
}

cat("Package folders created successfully!")


description <- c(
  "Package: CBSLElectricity",
  "Title: Tools for Processing CBSL Electricity Indicators",
  "Version: 0.0.1",
  'Authors@R: person("Buddhini", "G", role = c("aut", "cre"), email = "gamagebuddhinits@gmail.com")',
  "Description: Provides functions and tools for processing daily electricity indicators published by the Central Bank of Sri Lanka.",
  "License: MIT + file LICENSE",
  "Encoding: UTF-8",
  "Roxygen: list(markdown = TRUE)",
  "RoxygenNote: 7.3.2"
)

writeLines(
  description,
  file.path(repo_path, "DESCRIPTION")
)

file.create(file.path(repo_path, "NAMESPACE"))
usethis::use_mit_license("Buddhini")

script_path <- file.choose()

file.copy(
  from = script_path,
  to = file.path(
    repo_path,
    "scripts",
    basename(script_path)
  ),
  overwrite = TRUE
)

# Select your Excel dataset
dataset_path <- file.choose()

# Copy it to the package
file.copy(
  from = dataset_path,
  to = file.path(
    repo_path,
    "inst",
    "extdata",
    basename(dataset_path)
  ),
  overwrite = TRUE
)

df <- read.csv("dataraw/electricity_generation_data.csv", check.names = FALSE)
tail(df)                      # check the last row is the one you want to remove
df_new <- df[-nrow(df), ]     # removes the last row only
nrow(df) - nrow(df_new)       # should print 1
tail(df_new)                  # last row should now be the previous date
write.csv(df_new, "dataraw/electricity_generation_data.csv", row.names = FALSE)
