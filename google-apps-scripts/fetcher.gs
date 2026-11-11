/**
 * CBSL PDF fetcher (Google Apps Script).
 *
 * CBSL blocks GitHub's servers but answers Google's, so this script does only
 * the downloading. Every hour it:
 *   1. asks GitHub which CBSL PDF was processed last (electricity_meta.json,
 *      or the CSV's last date if that file is missing),
 *   2. reads CBSL's listing pages for newer daily-indicator PDFs,
 *   3. uploads each new PDF to the GitHub release "inbox",
 *   4. tells GitHub to start the "process-inbox" workflow, which parses them.
 *
 * CBSL refuses some of Google's servers (HTTP 403), and each run is handled
 * by one of them. So a refused request is retried a few times, and a run that
 * still cannot reach CBSL does not email you: the next run, usually on another
 * server, catches up. Each run uploads at most CONFIG.MAX_PDFS_PER_RUN PDFs,
 * so a backlog is cleared over the next few runs. You get an email only after
 * CONFIG.FAILS_BEFORE_ALERT failed runs in a row, or for problems on the
 * GitHub side (token).
 *
 * One-time setup is in SETUP.md. In short:
 *   - fill in CONFIG below,
 *   - Project Settings -> Script properties -> add GITHUB_TOKEN,
 *   - run "fetchNewPdfs" once to check it works,
 *   - Triggers (clock icon) -> add one "Time-driven" trigger for
 *     fetchNewPdfs: Hour timer, every hour. It is the only trigger needed.
 */

// ---- CONFIG -----------------------------------------------------------------

var CONFIG = {
  GITHUB_OWNER: 'RashmikaD2001',
  GITHUB_REPO: 'CBSL-Electricity-R-Package-Testing',
  BRANCH: 'main',
  // The published CSV: must be the same as DATA_CSV in process-inbox.yml.
  // electricity_meta.json is read from the same folder.
  // Use 'inst/extdata/electricity.csv' once this is an R package.
  DATA_CSV: 'dataraw/electricity_generation_data.csv',

  // Where to continue from is read from the meta file; if that is missing,
  // from the CSV's last date. Only for a brand-new repo with neither: the
  // date of the first PDF to fetch, e.g. '2026-11-06'. Leave '' otherwise.
  FIRST_RUN_FROM: '',

  MAX_PAGES: 30,            // safety limit only: the fetcher reads listing pages until it
                            // reaches the last processed PDF (12 PDFs per page, 30 = ~18 months)
  MAX_PDFS_PER_RUN: 15,     // keeps one run well under Apps Script's 6-minute limit
  PAUSE_MS: 1500,           // pause between requests to CBSL

  RETRY_WAITS_S: [10, 30, 60],   // seconds to wait before each retry of a refused CBSL request
  FAILS_BEFORE_ALERT: 12,        // email only after this many runs in a row could not reach CBSL
                                 // (12 = 12 hours with the hourly trigger)
  TIME_BUDGET_MS: 4 * 60 * 1000  // start no CBSL request after 4 min (Apps Script stops at 6)
};

var LISTING_URL = 'https://www.cbsl.gov.lk/en/statistics/economic-indicators/daily-indicators';
var CBSL_BASE = 'https://www.cbsl.gov.lk';
var USER_AGENT = 'Mozilla/5.0 (cbslelectricity research script)';
var INBOX_TAG = 'inbox';
var PROBLEMS_TAG = 'problems';
var FAILS_PROP = 'CBSL_FAILED_RUNS';
var deadline_ = 0;

/** A CBSL-side problem: the next run retries it instead of emailing at once. */
function CbslError_(message) { this.message = message; this.isCbsl = true; }
CbslError_.prototype = Object.create(Error.prototype);
CbslError_.prototype.name = 'CbslError';

// ---- entry points -------------------------------------------------------------

/**
 * The daily job. Throws (so Google emails you) on GitHub problems, or when
 * CBSL could not be reached for CONFIG.FAILS_BEFORE_ALERT runs in a row.
 */
function fetchNewPdfs() {
  deadline_ = Date.now() + CONFIG.TIME_BUDGET_MS;
  var start = startingPoint_();
  var isNew = start.after
    ? function (d) { return d > start.after; }
    : function (d) { return d >= start.from; };
  Logger.log(start.why);

  var inbox = getOrCreateRelease_(INBOX_TAG, 'PDF inbox (automatic)',
    'New CBSL PDFs waiting to be parsed. Filled by the Apps Script fetcher, ' +
    'emptied by the process-inbox workflow. Do not edit by hand.');
  var waiting = assetNames_(inbox.id);
  var problems = getRelease_(PROBLEMS_TAG);
  var parked = problems ? assetNames_(problems.id) : [];

  var cbslProblem = null, links = [];
  try {
    links = newLinks_(isNew, !!start.after).filter(function (l) {
      return waiting.indexOf(l.name) === -1 && parked.indexOf(l.name) === -1;
    });
  } catch (e) {
    if (!e.isCbsl) throw e;
    cbslProblem = e.message;
  }
  if (!cbslProblem) {
    Logger.log(links.length + ' new PDF(s) to fetch, ' + waiting.length + ' already waiting in the inbox' +
      (links.length > CONFIG.MAX_PDFS_PER_RUN
        ? '; fetching the oldest ' + CONFIG.MAX_PDFS_PER_RUN + ' now, the rest in the next runs' : ''));
  }
  links = links.slice(0, CONFIG.MAX_PDFS_PER_RUN);

  for (var i = 0; i < links.length; i++) {
    var l = links[i];
    if (Date.now() > deadline_) {
      Logger.log('Out of time; ' + (links.length - i) + ' PDF(s) left for the next run');
      break;
    }
    Utilities.sleep(CONFIG.PAUSE_MS);
    var resp;
    try {
      resp = fetchCbsl_(l.url, l.name);
    } catch (e) {
      if (!e.isCbsl) throw e;
      cbslProblem = e.message;
      break;
    }
    var bytes = resp.getContent();
    var isPdf = bytes.length > 4 &&
      String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) === '%PDF';
    if (!isPdf) {
      cbslProblem = 'CBSL returned something that is not a PDF for ' + l.name;
      break;
    }
    uploadAsset_(inbox.id, l.name, bytes);
    waiting.push(l.name);
    Logger.log('Uploaded ' + l.name + ' (' + bytes.length + ' bytes)');
  }

  // Whatever reached the inbox is processed, even if CBSL failed part-way.
  if (waiting.length > 0) {
    github_('post', '/dispatches', { event_type: 'new-pdfs' });
    Logger.log('Started the process-inbox workflow for ' + waiting.length + ' PDF(s)');
  } else if (!cbslProblem) {
    Logger.log('Nothing new. Done.');
  }

  if (cbslProblem) cbslFailed_(cbslProblem);
  else cbslReached_();
}

// ---- CBSL -------------------------------------------------------------------

/**
 * GET a CBSL URL. Retries a refused (403/429), failed (5xx) or unanswered
 * request after the waits in CONFIG.RETRY_WAITS_S. Returns the 200 response,
 * or throws CbslError_ when every attempt failed.
 */
function fetchCbsl_(url, what) {
  var last = '';
  for (var attempt = 0; attempt <= CONFIG.RETRY_WAITS_S.length; attempt++) {
    if (attempt > 0) {
      var waitMs = CONFIG.RETRY_WAITS_S[attempt - 1] * 1000;
      if (Date.now() + waitMs > deadline_) break;
      Logger.log(what + ': ' + last + '; trying again in ' + (waitMs / 1000) + ' s');
      Utilities.sleep(waitMs);
    }
    var resp;
    try {
      resp = UrlFetchApp.fetch(url, { headers: { 'User-Agent': USER_AGENT }, muteHttpExceptions: true });
    } catch (e) {
      last = 'no answer (' + e.message + ')';
      continue;
    }
    var code = resp.getResponseCode();
    if (code === 200) {
      if (attempt > 0) Logger.log(what + ': OK on attempt ' + (attempt + 1));
      return resp;
    }
    last = 'HTTP ' + code;
    if (code !== 403 && code !== 429 && code < 500) break;  // e.g. 404: retrying won't help
  }
  throw new CbslError_(what + ' failed: ' + last);
}

/** A run could not reach CBSL. Emails (by throwing) only after several in a row. */
function cbslFailed_(message) {
  var props = PropertiesService.getScriptProperties();
  var runs = Number(props.getProperty(FAILS_PROP) || 0) + 1;
  props.setProperty(FAILS_PROP, String(runs));
  if (runs >= CONFIG.FAILS_BEFORE_ALERT) {
    throw new Error(message + '. CBSL could not be reached in ' + runs + ' runs in a row.');
  }
  Logger.log('WARNING: ' + message + '. Failed runs in a row: ' + runs + ' (email from ' +
             CONFIG.FAILS_BEFORE_ALERT + '). The next run will catch up.');
}

function cbslReached_() {
  var props = PropertiesService.getScriptProperties();
  var runs = Number(props.getProperty(FAILS_PROP) || 0);
  if (runs > 0) {
    props.deleteProperty(FAILS_PROP);
    Logger.log('CBSL reachable again after ' + runs + ' failed run(s).');
  }
}

function dateFromName_(name) {
  var m = name.match(/daily_economic_indicators_(\d{4})(\d{2})(\d{2})_e\.pdf$/i);
  if (m) return m[1] + '-' + m[2] + '-' + m[3];
  m = name.match(/DEI_(\d{2})_(\d{2})_(\d{4})\.pdf$/i);
  if (m) return m[3] + '-' + m[2] + '-' + m[1];
  return null;
}

/**
 * Every new PDF link, oldest first. Reads listing pages (newest first) until
 * it reaches a PDF that was already processed, however many pages back that
 * is, so a long break never leaves a gap.
 *
 * mustReachOld: true once there is a last processed PDF. If the listing ends,
 * or CONFIG.MAX_PAGES is hit, before reaching it, nothing is returned (and so
 * nothing is uploaded) rather than risk skipping the PDFs not seen.
 */
function newLinks_(isNew, mustReachOld) {
  var found = {}, re = /href="([^"]*(?:daily_economic_indicators_|DEI_)[^"]*\.pdf)"/gi;
  var prevFirst = null, reachedOld = false, page;
  for (page = 0; page < CONFIG.MAX_PAGES && !reachedOld; page++) {
    if (Date.now() > deadline_) {
      throw new CbslError_('Ran out of time on CBSL listing page ' + page + ' before reaching the last processed PDF');
    }
    if (page > 0) Utilities.sleep(CONFIG.PAUSE_MS);
    var url = page === 0 ? LISTING_URL : LISTING_URL + '?page=' + page;
    var resp = fetchCbsl_(url, 'CBSL listing page ' + page);
    var html = resp.getContentText(), m, onPage = [];
    re.lastIndex = 0;
    while ((m = re.exec(html)) !== null) {
      var link = m[1].indexOf('http') === 0 ? m[1] : CBSL_BASE + m[1];
      var name = link.split('/').pop();
      var date = dateFromName_(name);
      if (!date) continue;
      onPage.push(name);
      if (isNew(date)) found[name] = { name: name, url: link, date: date };
      else reachedOld = true;
    }
    if (onPage.length === 0) {
      if (page === 0) throw new CbslError_('No PDF links found on CBSL listing page 0; has the page changed?');
      break;                                   // past the last listing page
    }
    if (onPage[0] === prevFirst) break;        // CBSL repeated the last page
    prevFirst = onPage[0];
  }

  if (!reachedOld && mustReachOld) {
    if (page >= CONFIG.MAX_PAGES) {
      throw new Error('All PDFs on the first ' + CONFIG.MAX_PAGES + ' CBSL listing pages are new. ' +
        'Nothing was uploaded, so nothing was skipped. Raise MAX_PAGES in CONFIG and run fetchNewPdfs again.');
    }
    throw new CbslError_('The CBSL listing ended on page ' + page + ' before reaching the last processed PDF');
  }
  var links = Object.keys(found).map(function (k) { return found[k]; })
    .sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0; });
  Logger.log('Read ' + page + ' listing page(s): ' + links.length + ' PDF(s) newer than the last processed one');
  return links;
}

// ---- GitHub -----------------------------------------------------------------

function token_() {
  var t = PropertiesService.getScriptProperties().getProperty('GITHUB_TOKEN');
  if (!t) throw new Error('Add GITHUB_TOKEN under Project Settings -> Script properties');
  return t;
}

function github_(method, path, body, allow404) {
  var opts = {
    method: method,
    headers: {
      Authorization: 'Bearer ' + token_(),
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28'
    },
    muteHttpExceptions: true
  };
  if (body) { opts.contentType = 'application/json'; opts.payload = JSON.stringify(body); }
  var url = 'https://api.github.com/repos/' + CONFIG.GITHUB_OWNER + '/' + CONFIG.GITHUB_REPO + path;
  var resp = UrlFetchApp.fetch(url, opts);
  var code = resp.getResponseCode();
  if (code === 404 && allow404) return null;
  if (code >= 300) throw new Error('GitHub ' + method.toUpperCase() + ' ' + path + ' failed: HTTP ' + code + ' ' + resp.getContentText().substring(0, 300));
  var text = resp.getContentText();
  return text ? JSON.parse(text) : {};
}

/** A file in the repo as text, or null if it does not exist. Read through the
 *  API, which has no 5-minute cache like raw.githubusercontent.com. */
function readRepoFile_(path) {
  var resp = UrlFetchApp.fetch(
    'https://api.github.com/repos/' + CONFIG.GITHUB_OWNER + '/' + CONFIG.GITHUB_REPO +
    '/contents/' + path + '?ref=' + CONFIG.BRANCH,
    { headers: { Authorization: 'Bearer ' + token_(), Accept: 'application/vnd.github.raw+json' },
      muteHttpExceptions: true });
  if (resp.getResponseCode() === 404) return null;
  if (resp.getResponseCode() !== 200) throw new Error('Could not read ' + path + ': HTTP ' + resp.getResponseCode());
  return resp.getContentText();
}

function metaPath_() {
  return CONFIG.DATA_CSV.replace(/[^\/]*$/, '') + 'electricity_meta.json';
}

/**
 * Where this run continues from, in order of preference:
 *   1. last_pdf_date in the meta file (normal case),
 *   2. the CSV's last date, if the meta file is missing (e.g. a new repo the
 *      CSV was copied to; the workflow then creates the meta file),
 *   3. CONFIG.FIRST_RUN_FROM, for a brand-new repo with no CSV.
 * Returns { after: date } (fetch PDFs newer than it) or { from: date }.
 */
function startingPoint_() {
  var metaText = readRepoFile_(metaPath_());
  var meta = metaText ? JSON.parse(metaText) : null;
  if (meta && meta.last_pdf_date) {
    return { after: meta.last_pdf_date, why: 'Last processed PDF is dated ' + meta.last_pdf_date };
  }
  var csv = readRepoFile_(CONFIG.DATA_CSV);
  var last = csv ? lastCsvDate_(csv) : null;
  if (last) {
    return { after: last, why: 'No meta file at ' + metaPath_() + '; continuing after the last date in the CSV, ' + last };
  }
  if (CONFIG.FIRST_RUN_FROM) {
    return { from: CONFIG.FIRST_RUN_FROM, why: 'No data in the repo yet; fetching PDFs dated from ' + CONFIG.FIRST_RUN_FROM };
  }
  throw new Error('Found neither ' + metaPath_() + ' nor a CSV with dates at ' + CONFIG.DATA_CSV +
    ' in ' + CONFIG.GITHUB_OWNER + '/' + CONFIG.GITHUB_REPO + '. Check GITHUB_REPO and DATA_CSV in CONFIG ' +
    'and that the token can access this repo. To start a new CSV instead, set FIRST_RUN_FROM.');
}

/** Latest date in the CSV's first column: YYYY-MM-DD, or m/d/yyyy as Excel saves it. */
function lastCsvDate_(text) {
  var max = null;
  text.split(/\r?\n/).forEach(function (line) {
    var cell = line.split(',')[0].replace(/"/g, '').trim(), m, iso = null;
    if (/^\d{4}-\d{2}-\d{2}$/.test(cell)) iso = cell;
    else if ((m = cell.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/))) {
      iso = m[3] + '-' + ('0' + m[1]).slice(-2) + '-' + ('0' + m[2]).slice(-2);
    }
    if (iso && (max === null || iso > max)) max = iso;
  });
  return max;
}

function getRelease_(tag) {
  return github_('get', '/releases/tags/' + tag, null, true);
}

function getOrCreateRelease_(tag, title, notes) {
  return getRelease_(tag) || github_('post', '/releases', {
    tag_name: tag, target_commitish: CONFIG.BRANCH, name: title, body: notes, prerelease: true
  });
}

function assetNames_(releaseId) {
  var names = [];
  for (var page = 1; ; page++) {
    var assets = github_('get', '/releases/' + releaseId + '/assets?per_page=100&page=' + page);
    assets.forEach(function (a) { names.push(a.name); });
    if (assets.length < 100) return names;
  }
}

function uploadAsset_(releaseId, name, bytes) {
  var resp = UrlFetchApp.fetch(
    'https://uploads.github.com/repos/' + CONFIG.GITHUB_OWNER + '/' + CONFIG.GITHUB_REPO +
    '/releases/' + releaseId + '/assets?name=' + encodeURIComponent(name),
    { method: 'post', contentType: 'application/pdf', payload: bytes,
      headers: { Authorization: 'Bearer ' + token_(), Accept: 'application/vnd.github+json' },
      muteHttpExceptions: true });
  if (resp.getResponseCode() >= 300) {
    throw new Error('Upload of ' + name + ' failed: HTTP ' + resp.getResponseCode() + ' ' + resp.getContentText().substring(0, 300));
  }
}