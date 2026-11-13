# CBSL daily electricity data - Testing repository

Daily electricity generation figures for Sri Lanka, taken from the Central Bank
of Sri Lanka's (CBSL) [Daily Economic Indicators](https://www.cbsl.gov.lk/en/statistics/economic-indicators/daily-indicators)
PDFs and kept in one CSV. The CSV updates itself every working day; nobody has
to download or type anything.

## The data

`dataraw/electricity_generation_data.csv`: one row per day, from 2020-09-02.

CBSL publishes a PDF on working days only. Since 4 Aug 2022 each PDF also shows
the day before, so Sundays and holidays have a row too, with energy and peak
demand only: the percentages come from a pie chart drawn for the PDF's own day.
Saturdays, and the first day of a longer break, appear in no PDF and have no
row.

| Column | Meaning |
|---|---|
| `date` | Date the figures are for, `YYYY-MM-DD` |
| `total_energy_gwh` | Total electricity generated that day, GWh |
| `peak_demand_mw` | Peak demand that day, MW |
| `pct_hydro` | Share of generation from hydro, % |
| `pct_thermal` | Share from oil-fired thermal plants, % |
| `pct_coal` | Share from coal, % |
| `pct_wind` | Share from wind, % |
| `pct_solar` | Share from solar, % (reported from 2022-06-01) |
| `pct_biomass` | Share from biomass, % (reported from 2022-12-01) |

An empty cell means the PDF did not report the value, or the value failed a
check and was left empty rather than guessed (see `dataraw/problems.csv` when
it exists).

Read it in R:

```r
url  <- "https://raw.githubusercontent.com/RashmikaD2001/CBSL-Electricity-R-Package-Testing/main/dataraw/electricity_generation_data.csv"
elec <- read.csv(url)
elec$date <- as.Date(elec$date)
```

`dataraw/electricity_meta.json` describes the CSV (last date, number of rows,
MD5 checksum, when it last changed), so a program can check for new data
without downloading the whole file.

The figures are CBSL's; this repository only extracts them from the PDFs.

## How it updates

CBSL blocks GitHub's servers but answers Google's, so the job is split in two.
Both halves are free and run on their own.

```
Google Apps Script  (google-apps-scripts/fetcher.gs, every hour)
  reads CBSL's listing pages -> downloads new PDFs -> uploads them to the
  GitHub release "inbox" -> starts the process-inbox workflow
GitHub Actions  (process-inbox.yml, never contacts CBSL)
  parses the PDFs in R -> adds rows to the CSV, updates electricity_meta.json
  -> commits -> empties the inbox
```

### The daily 18:30 run

Besides the runs the fetcher starts, `process-inbox.yml` also runs once a day
on a timer (`cron: "0 13 * * *"`, 13:00 UTC = 18:30 Sri Lanka). GitHub often
starts timed runs late, sometimes by several hours; that is normal. This run
is a safety net:

- **It processes anything left in the inbox.** If a fetcher-started run failed,
  or the fetcher uploaded PDFs but could not start the workflow, the PDFs wait
  in the inbox and this run parses them.
- **It notices when nothing arrives.** It reads `updated` in the meta file and,
  if the data has not changed for more than 5 days (`STALE_DAYS`), the step
  "Check the data is not stale" fails and GitHub emails you. Only a timed run
  can notice this: if the fetcher stops completely (trigger deleted, Google
  account problem, CBSL site changed), it never starts a workflow at all.
- **It publishes hand edits.** If someone corrects the CSV by hand, this run
  updates the meta file's checksum so clients see the change.

On a day with nothing to do it takes about 2 minutes, commits nothing and sends
no email. Public repositories don't pay for GitHub Actions.

GitHub sends the email to the person who last changed the `cron:` line in
`process-inbox.yml` (at first, whoever added the file). That person needs
**Settings -> Notifications -> Actions** set to email, with "Only notify for
failed workflows" ticked.

## Files

| Path in the repo | What it is |
|---|---|
| `dataraw/electricity_generation_data.csv` | The data. The pipeline adds rows to it |
| `dataraw/electricity_meta.json` | Written by the workflow; don't create or edit it. If it goes missing, the fetcher uses the CSV's last date and the next workflow run recreates it |
| `dataraw/problems.csv` | Made only when a PDF needed a safeguard |
| `.github/workflows/process-inbox.yml` | The GitHub half |
| `tools/process_inbox.R` | Parses the inbox, applies the safeguards, writes CSV + meta |
| `tools/extract_electricity_data.R` | Reads one CBSL PDF |
| `tools/download_pdfs.R` | Downloads CBSL PDFs for a date range to your own computer, for a one-off rebuild (see "Reprocessing old PDFs"). The workflow does not use it |
| `google-apps-scripts/fetcher.gs` | The Google half. A copy is kept here; it runs in Apps Script |
| Release `inbox` | A mailbox, not a data release: PDFs waiting for the workflow. Created and emptied automatically, so usually empty |
| Release `problems` | PDFs that needed a safeguard, kept so they can be parsed again. Exists only after the first problem |

The CSV path is set in **two places**, with the same value. Change both
together if you move the CSV (for the R package it becomes
`inst/extdata/electricity.csv`):

- `process-inbox.yml`: `DATA_CSV: dataraw/electricity_generation_data.csv`
- `fetcher.gs`: `DATA_CSV: 'dataraw/electricity_generation_data.csv'`

The meta file is always read from and written to the CSV's folder.

## Setting up the pipeline

This repository is already set up. These steps are for a new repository or a
new Google account.

### 1. Files in the repo

The repo needs the CSV, `.github/workflows/process-inbox.yml`, the two R
scripts in `tools/` and, for reference, `google-apps-scripts/fetcher.gs`. The
meta file and `problems.csv` are created by the workflow.

### 2. Test the workflow (2 min)

**Actions -> process-inbox -> Run workflow -> Run workflow**. With an empty
inbox this run only:

- converts the CSV's dates to `YYYY-MM-DD` if Excel saved them as `11/5/2026`,
- creates `electricity_meta.json` next to the CSV from its last date,
- commits both.

It must finish green. That proves the workflow and the R scripts work before
any PDF depends on them.

### 3. Create a GitHub token for the fetcher (3 min)

1. GitHub -> your photo -> **Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens -> Generate new token**.
2. Name: `cbsl-fetcher`. Expiration: the longest offered (GitHub emails you before it expires; renewing is the only recurring task).
3. Repository access: **Only select repositories** -> this repository.
4. Permissions -> Repository permissions -> **Contents: Read and write**. Nothing else.
5. Generate, and copy the token. Don't paste it anywhere except step 4.

### 4. Set up Apps Script (5 min)

1. **script.google.com** -> **New project** (e.g. `CBSL fetcher`).
2. Replace all code with `google-apps-scripts/fetcher.gs`, save (Ctrl+S).
3. Check `CONFIG` at the top: `GITHUB_OWNER`, `GITHUB_REPO`, `DATA_CSV`. Leave
   `FIRST_RUN_FROM` as `''` and `FAILS_BEFORE_ALERT` as `12`.
4. **Project Settings** (gear icon):
   - Time zone: **(GMT+05:30) Colombo**, so the log times are Sri Lanka time.
   - **Script properties -> Add script property**: name `GITHUB_TOKEN`, value = the token. Save.
5. **Editor**: choose **fetchNewPdfs** in the function menu -> **Run** -> allow
   the permissions. The log says the last processed PDF date, lists the newer
   PDFs it uploaded, and says it started the workflow (or "Nothing new").
6. **Triggers** (clock icon) -> **+ Add Trigger**, and fill in:

   | Field | Value |
   |---|---|
   | Choose which function to run | `fetchNewPdfs` |
   | Choose which deployment should run | `Head` |
   | Select event source | `Time-driven` |
   | Select type of time based trigger | `Hour timer` |
   | Select hour interval | `Every hour` |
   | Failure notification settings | `Notify me daily` |

   Save.
7. Check the Triggers page lists **exactly one** `fetchNewPdfs` trigger.

Why every hour:

- **CBSL refuses some of Google's servers** (HTTP 403). Each run is handled by
  one server, so retrying inside a refused run rarely helps, but the next run
  usually gets a different server and goes through. With hourly runs a refused
  run is caught up within an hour.
- **Each run uploads at most 15 PDFs** (see "After a long break"), so a backlog
  is cleared at 15 an hour.
- A new PDF arrives within about an hour of CBSL posting it (usually around
  10am).
- A run with nothing new reads one CBSL page and takes about 5 s, so 24 runs a
  day use only a few minutes of Google's daily allowance. GitHub runs only
  when PDFs arrive.

"Notify me daily" sends at most one failure email a day (for example while a
token has expired) instead of one an hour. To change how often the fetcher
runs, edit the trigger; there is nothing to change in the code. If you choose a
longer interval, lower `FAILS_BEFORE_ALERT` to match (it counts runs, not
hours).

### 5. Check it worked

- **Releases -> inbox** exists.
- If CBSL has published since the CSV's last date: **Actions -> process-inbox**
  shows a green run started by `repository_dispatch`, the CSV has the new rows,
  and the inbox is empty again. Otherwise the fetcher logs "Nothing new" and
  the next PDF comes through on its own.

From then on nothing needs you unless an email arrives.

## Testing

### Each half on its own

- **Workflow:** **Actions -> process-inbox -> Run workflow**. With an empty
  inbox it finishes green and changes nothing (it only refreshes the meta file
  if the CSV was edited by hand).
- **Fetcher:** in Apps Script choose **fetchNewPdfs** -> **Run**, then read the
  log (also under **Executions**):

  | Log line | Meaning |
  |---|---|
  | `Last processed PDF is dated ...` | Where it continues from (the meta file) |
  | `No meta file ...; continuing after the last date in the CSV, ...` | The meta file is missing, so it uses the CSV |
  | `Read N listing page(s): M PDF(s) newer than the last processed one` | How far back it read CBSL's listing |
  | `Uploaded ...`, then `Started the process-inbox workflow for N PDF(s)` | PDFs handed to GitHub |
  | `Nothing new. Done.` | Up to date |
  | `WARNING: ... HTTP 403 ...` | CBSL refused this run; the next run catches up |

### The whole pipeline: rebuild removed days

1. In **one commit**, delete `dataraw/electricity_meta.json` and the last rows
   of the CSV (for example every row after a chosen date). Note the commit
   before it. Delete both together: if the meta file stays, the fetcher
   continues from its date and does not fetch the removed days.
2. Wait for the hourly trigger, or run **fetchNewPdfs** by hand. The first run
   logs `No meta file ...; continuing after the last date in the CSV, <date>`.
   Each run uploads the oldest 15 missing PDFs, so 60 removed days take 4 or 5
   runs.
3. After each run check: a green `process-inbox` run started by
   `repository_dispatch`, up to 15 more rows in the CSV, `last_pdf_date` in the
   meta file moving forward, and an empty `inbox` release.
4. When the fetcher logs `Nothing new. Done.`, compare the CSV with the commit
   from step 1:

   ```
   git diff <commit-before-the-test> -- dataraw/electricity_generation_data.csv
   ```

   The only difference should be rows for days CBSL published after the test
   started.

### A parser change, on your own computer

Put a few CBSL PDFs in a folder, with the names CBSL gives them (e.g.
`daily_economic_indicators_20261110_e.pdf`), and point the script at a CSV
that does not exist yet:

```
Rscript tools/process_inbox.R test-pdfs test-out/electricity.csv
```

It needs the `pdftools` R package. It creates `test-out/electricity.csv` with
just those days, plus the meta file, and `test-out/problems.csv` if a PDF
needed a safeguard. The repo's data is not touched. Push the parser change
only when the output looks right.

### While testing, avoid

- **Deleting the `inbox` release while a fetcher run is uploading.** That run
  fails with HTTP 404. Deleting it at other times is fine: the next run creates
  it again.
- **Running fetchNewPdfs by hand while a trigger run is going.** Both may try
  to upload the same PDF, and one fails. The next run sorts it out.

## When an email arrives

| Email from | Meaning | What to do |
|---|---|---|
| Google (Apps Script failure, daily summary) | Either the GitHub token expired or was wrong, or CBSL could not be reached for 12 runs in a row (12 hours) | Open the project -> **Executions** to read the error. Token: make a new one (setup step 3) and replace `GITHUB_TOKEN`. CBSL: check the site opens in your browser; if the listing page has changed, the parser or fetcher needs updating |
| GitHub: "Fail if any PDF had a problem" | A PDF needed a safeguard. Its data **was still published**, with the doubtful values left empty | Read `dataraw/problems.csv`. Fix the parser, then **Actions -> process-inbox -> Run workflow** with **reprocess** ticked. The PDFs are kept in the **problems** release, so CBSL is not needed |
| GitHub: "Check the data is not stale" (from the daily 18:30 run) | No new data for more than 5 days | Look at the Apps Script **Executions** and the **inbox** release |

Quiet weekends and holidays are normal; only more than 5 days without new data
sends the stale email.

## Good to know

### Don't open and save the CSV in Excel

Excel rewrites the dates (`2026-11-05` becomes `11/5/2026`). The pipeline still
reads them and converts them back, but users who download the file in between
would get the Excel format. To look at the data, open it read-only or use R.

### After a long break nothing is skipped

Each run reads CBSL's listing pages (newest first, 12 PDFs per page) until it
reaches the last PDF already processed (`last_pdf_date` in the meta file),
however many pages back that is. It then uploads the missed PDFs oldest first,
15 per run, so a backlog of 40 is done after 3 runs (3 hours). It never uploads
past a PDF it has not seen, so the data has no gaps.

The 15 is `MAX_PDFS_PER_RUN`, and it is deliberate, not a CBSL or GitHub limit.
Google stops any Apps Script run at 6 minutes, and one PDF takes 4 to 14 s to
download and upload, depending on how fast CBSL answers. When CBSL is slow, 15
PDFs take over 2 minutes; at that pace 45 would take about 7 minutes and be cut
off. So each run takes the oldest 15, tells GitHub, and the next run continues. On a normal day there is only one
new PDF, so the limit never matters.

The page limit `MAX_PAGES: 30` (about 18 months of PDFs) is only a safety
stop. If the fetcher was off longer than that, it uploads nothing and emails
"Raise MAX_PAGES"; raise it in `CONFIG`, save, and run **fetchNewPdfs**.

### Reprocessing old PDFs on your computer

For anything the fetcher cannot do in its hourly runs (a gap longer than
`MAX_PAGES`, or running a changed parser over years of PDFs), run the same
script on your own computer. CBSL answers Sri Lankan connections. You need R
and `install.packages("pdftools")`.

```
Rscript tools/download_pdfs.R 2022-08-04 2026-11-13 ../cbsl_pdfs
git pull
Rscript tools/process_inbox.R ../cbsl_pdfs dataraw/electricity_generation_data.csv
git diff --numstat dataraw/electricity_generation_data.csv
```

Keep the PDF folder outside the repo. The download can be stopped and run
again; it skips PDFs it already has. Reprocessing leaves existing rows as they
are and only adds missing dates, so the second number from `git diff --numstat`
(lines removed) must be 0. Then commit `dataraw/` and push. The script writes
`\n` line ends on every system, so the md5 in the meta file matches the file
GitHub stores.

### If the meta file is missing

Nothing breaks and nothing is skipped. Each side falls back to the CSV:

| Who | Without `electricity_meta.json` |
|---|---|
| Fetcher (Apps Script) | Continues after the **last date in the CSV** (reads either date format). Logs "No meta file ...; continuing after the last date in the CSV" |
| Workflow (GitHub) | Takes the CSV's last date as the last processed PDF and **writes a new meta file** on its next run |

Only if there is **no CSV either** does the fetcher stop and email you: then
`GITHUB_REPO` or `DATA_CSV` is wrong, or the token can't see the repo. For a
deliberately empty new repo, set `FIRST_RUN_FROM` to the first PDF date wanted.

### "HTTP 403" in the Apps Script executions

CBSL refuses some of Google's servers, and each Apps Script run is handled by
one of them. The fetcher retries each refused request (after 10, 30 and 60 s).
If a whole run still fails, it logs a `WARNING` and finishes as **Completed**,
with no email, and the next run, usually on another server, catches up. So an
occasional warning in **Executions** is normal. Only 12 failed runs in a row
send an email (`FAILS_BEFORE_ALERT` in `CONFIG`).

## Moving the pipeline to another repo

For example to the R package's repository. The fetcher always continues from
the **target repo's** own CSV, so a move cannot lose or skip days: anything the
old repo processed after you copied the CSV is simply fetched again for the new
one.

1. **New repo:** copy the CSV (and `electricity_meta.json` if you like; it is
   optional), `.github/workflows/process-inbox.yml` and the R scripts. If the
   path changes (e.g. `inst/extdata/electricity.csv`), set `DATA_CSV` in the
   workflow. Commit and push.
2. **Token:** GitHub -> Settings -> Developer settings -> Fine-grained tokens ->
   `cbsl-fetcher` -> **Repository access** -> add the new repo (or make a new
   token as in setup step 3). If you made a new token, replace `GITHUB_TOKEN`
   in the Apps Script **Script properties**.
3. **Apps Script:** in `CONFIG` set `GITHUB_OWNER`, `GITHUB_REPO` and `DATA_CSV`
   to the new repo's values. Save, then run **fetchNewPdfs** once. The log
   should name the new repo's last date. The trigger stays as it is.
4. **Old repo:** **Actions -> process-inbox -> ... -> Disable workflow**.
   Otherwise its daily check emails "stale data" 5 days later, because no new
   PDFs arrive there any more. You can delete its `inbox` release.

The `inbox` release in the new repo is created automatically on the first run.
