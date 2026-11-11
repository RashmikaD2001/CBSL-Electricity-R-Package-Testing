/**
 * CBSL PDF fetcher (Google Apps Script).
 *
 * CBSL blocks GitHub's servers but answers Google's, so this script does only
 * the downloading. Twice a day it:
 *   1. asks GitHub which CBSL PDF was processed last (electricity_meta.json),
 *   2. reads CBSL's listing pages for newer daily-indicator PDFs,
 *   3. uploads each new PDF to the GitHub release "inbox",
 *   4. tells GitHub to start the "process-inbox" workflow, which parses them.
 *
 * One-time setup is in SETUP.md. In short:
 *   - fill in CONFIG below,
 *   - Project Settings -> Script properties -> add GITHUB_TOKEN,
 *   - run "setup" once (creates the two daily timers),
 *   - run "fetchNewPdfs" once to check it works.
 */

// ---- CONFIG -----------------------------------------------------------------

var CONFIG = {
  GITHUB_OWNER: 'RashmikaD2001',
  GITHUB_REPO: 'CBSL-Electricity-R-Package-Testing',
  BRANCH: 'main',
  // The meta file sits next to the CSV (DATA_CSV in process-inbox.yml).
  // Use 'inst/extdata/electricity_meta.json' once this is an R package.
  META_PATH: 'dataraw/electricity_meta.json',

  // Used only while the repo has no meta file yet. Normally you run the
  // process-inbox workflow once first, which creates it from the CSV.
  FIRST_RUN_FROM: '2026-11-06',

  RUN_HOURS: [11, 16],      // Sri Lanka time; set the project time zone to Colombo
  MAX_PAGES: 3,             // listing pages to read per run (12 PDFs per page)
  MAX_PDFS_PER_RUN: 15,     // keeps one run well under Apps Script's 6-minute limit
  PAUSE_MS: 1500            // pause between requests to CBSL
};

var LISTING_URL = 'https://www.cbsl.gov.lk/en/statistics/economic-indicators/daily-indicators';
var CBSL_BASE = 'https://www.cbsl.gov.lk';
var USER_AGENT = 'Mozilla/5.0 (cbslelectricity research script)';
var INBOX_TAG = 'inbox';
var PROBLEMS_TAG = 'problems';

// ---- entry points -------------------------------------------------------------

/** Run once: replaces any old timers with one per hour in CONFIG.RUN_HOURS. */
function setup() {
  token_();  // fails early if the token is missing
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'fetchNewPdfs') ScriptApp.deleteTrigger(t);
  });
  CONFIG.RUN_HOURS.forEach(function (h) {
    ScriptApp.newTrigger('fetchNewPdfs').timeBased().everyDays(1).atHour(h).nearMinute(30).create();
  });
  Logger.log('Timers created for %s:30 (%s). If that time zone is not Asia/Colombo, ' +
             'change it in Project Settings and run setup again.',
             CONFIG.RUN_HOURS.join(':30 and '), Session.getScriptTimeZone());
}

/** The daily job. Throws on failure, so Google emails you about it. */
function fetchNewPdfs() {
  var meta = readMeta_();
  var isNew = meta && meta.last_pdf_date
    ? function (d) { return d > meta.last_pdf_date; }
    : function (d) { return d >= CONFIG.FIRST_RUN_FROM; };
  Logger.log(meta && meta.last_pdf_date
    ? 'Last processed PDF is dated ' + meta.last_pdf_date
    : 'No meta file yet; fetching PDFs dated from ' + CONFIG.FIRST_RUN_FROM);

  var inbox = getOrCreateRelease_(INBOX_TAG, 'PDF inbox (automatic)',
    'New CBSL PDFs waiting to be parsed. Filled by the Apps Script fetcher, ' +
    'emptied by the process-inbox workflow. Do not edit by hand.');
  var waiting = assetNames_(inbox.id);
  var problems = getRelease_(PROBLEMS_TAG);
  var parked = problems ? assetNames_(problems.id) : [];

  var links = newLinks_(isNew).filter(function (l) {
    return waiting.indexOf(l.name) === -1 && parked.indexOf(l.name) === -1;
  });
  links = links.slice(0, CONFIG.MAX_PDFS_PER_RUN);
  Logger.log('%s new PDF(s) to fetch, %s already waiting in the inbox', links.length, waiting.length);

  links.forEach(function (l) {
    Utilities.sleep(CONFIG.PAUSE_MS);
    var resp = UrlFetchApp.fetch(l.url, {
      headers: { 'User-Agent': USER_AGENT }, muteHttpExceptions: true
    });
    var bytes = resp.getContent();
    var isPdf = bytes.length > 4 &&
      String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) === '%PDF';
    if (resp.getResponseCode() !== 200 || !isPdf) {
      throw new Error('CBSL did not return a PDF for ' + l.name + ' (HTTP ' + resp.getResponseCode() + ')');
    }
    uploadAsset_(inbox.id, l.name, bytes);
    waiting.push(l.name);
    Logger.log('Uploaded %s (%s bytes)', l.name, bytes.length);
  });

  if (waiting.length > 0) {
    github_('post', '/dispatches', { event_type: 'new-pdfs' });
    Logger.log('Started the process-inbox workflow for %s PDF(s)', waiting.length);
  } else {
    Logger.log('Nothing new. Done.');
  }
}

// ---- CBSL -------------------------------------------------------------------

function dateFromName_(name) {
  var m = name.match(/daily_economic_indicators_(\d{4})(\d{2})(\d{2})_e\.pdf$/i);
  if (m) return m[1] + '-' + m[2] + '-' + m[3];
  m = name.match(/DEI_(\d{2})_(\d{2})_(\d{4})\.pdf$/i);
  if (m) return m[3] + '-' + m[2] + '-' + m[1];
  return null;
}

/** New PDF links, oldest first. Stops at the first page that reaches old PDFs. */
function newLinks_(isNew) {
  var found = {}, re = /href="([^"]*(?:daily_economic_indicators_|DEI_)[^"]*\.pdf)"/gi;
  for (var page = 0; page < CONFIG.MAX_PAGES; page++) {
    if (page > 0) Utilities.sleep(CONFIG.PAUSE_MS);
    var url = page === 0 ? LISTING_URL : LISTING_URL + '?page=' + page;
    var resp = UrlFetchApp.fetch(url, { headers: { 'User-Agent': USER_AGENT }, muteHttpExceptions: true });
    if (resp.getResponseCode() !== 200) {
      throw new Error('CBSL listing page ' + page + ' returned HTTP ' + resp.getResponseCode());
    }
    var html = resp.getContentText(), m, onPage = 0, reachedOld = false;
    re.lastIndex = 0;
    while ((m = re.exec(html)) !== null) {
      var link = m[1].indexOf('http') === 0 ? m[1] : CBSL_BASE + m[1];
      var name = link.split('/').pop();
      var date = dateFromName_(name);
      if (!date) continue;
      onPage++;
      if (isNew(date)) found[name] = { name: name, url: link, date: date };
      else reachedOld = true;
    }
    if (onPage === 0) throw new Error('No PDF links found on CBSL listing page ' + page + '; has the page changed?');
    if (reachedOld) break;
  }
  return Object.keys(found).map(function (k) { return found[k]; })
    .sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0; });
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

/** The repo's meta file, read through the API (no 5-minute raw-file cache). */
function readMeta_() {
  var resp = UrlFetchApp.fetch(
    'https://api.github.com/repos/' + CONFIG.GITHUB_OWNER + '/' + CONFIG.GITHUB_REPO +
    '/contents/' + CONFIG.META_PATH + '?ref=' + CONFIG.BRANCH,
    { headers: { Authorization: 'Bearer ' + token_(), Accept: 'application/vnd.github.raw+json' },
      muteHttpExceptions: true });
  if (resp.getResponseCode() === 404) return null;
  if (resp.getResponseCode() !== 200) throw new Error('Could not read ' + CONFIG.META_PATH + ': HTTP ' + resp.getResponseCode());
  return JSON.parse(resp.getContentText());
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
