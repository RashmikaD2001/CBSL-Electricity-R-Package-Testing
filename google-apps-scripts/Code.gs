/**
 * CBSL access test for Google Apps Script.
 *
 * Checks whether CBSL's website answers requests from Google's servers,
 * using the same three requests as tools/cbsl_access_test.R:
 *   1. listing page 0 loads and contains daily-indicator PDF links
 *   2. listing page 1 (?page=1) loads too
 *   3. the newest PDF downloads and really is a PDF
 *
 * How to run: script.google.com -> New project -> paste this file ->
 * choose "testCbslAccess" in the toolbar -> Run -> allow the permission
 * request -> read the result under "Execution log".
 */

var LISTING_URL = 'https://www.cbsl.gov.lk/en/statistics/economic-indicators/daily-indicators';
var BASE_URL = 'https://www.cbsl.gov.lk';
var USER_AGENT = 'Mozilla/5.0 (cbslelectricity research script)';
var PDF_PATTERN = /href="([^"]*(?:daily_economic_indicators_|DEI_)[^"]*\.pdf)"/gi;

function fetchUrl(url) {
  var start = Date.now();
  try {
    var resp = UrlFetchApp.fetch(url, {
      headers: { 'User-Agent': USER_AGENT },
      muteHttpExceptions: true,
      followRedirects: true
    });
    return { resp: resp, secs: ((Date.now() - start) / 1000).toFixed(1) };
  } catch (e) {
    return { error: String(e), secs: ((Date.now() - start) / 1000).toFixed(1) };
  }
}

function describe(r) {
  var h = r.resp.getHeaders();
  return 'HTTP ' + r.resp.getResponseCode() +
    ', ' + (h['Content-Type'] || h['content-type'] || 'no content-type') +
    ', ' + r.resp.getContent().length + ' bytes' +
    ', server: ' + (h['Server'] || h['server'] || 'unknown') +
    ', ' + r.secs + ' s';
}

function pdfLinks(html) {
  var links = [], m;
  PDF_PATTERN.lastIndex = 0;
  while ((m = PDF_PATTERN.exec(html)) !== null) {
    var link = m[1].indexOf('http') === 0 ? m[1] : BASE_URL + m[1];
    if (links.indexOf(link) === -1) links.push(link);
  }
  return links;
}

function checkListing(name, url, results) {
  var r = fetchUrl(url);
  if (r.error) {
    results.push([name, 'FAIL', 'no response: ' + r.error]);
    return [];
  }
  var body = r.resp.getContentText();
  var links = pdfLinks(body);
  var ok = r.resp.getResponseCode() === 200 && links.length > 0;
  results.push([name, ok ? 'PASS' : 'FAIL', describe(r) + ', ' + links.length + ' PDF links']);
  if (!ok) results.push(['', '', 'reply starts: ' + body.substring(0, 300).replace(/\s+/g, ' ')]);
  return links;
}

function testCbslAccess() {
  var results = [];

  var links0 = checkListing('Listing page 0', LISTING_URL, results);
  Utilities.sleep(1500);
  checkListing('Listing page 1', LISTING_URL + '?page=1', results);

  if (links0.length > 0) {
    Utilities.sleep(1500);
    var url = links0[0];
    var r = fetchUrl(url);
    if (r.error) {
      results.push(['Download newest PDF', 'FAIL', 'no response: ' + r.error]);
    } else {
      var bytes = r.resp.getContent();
      var isPdf = bytes.length > 4 &&
        String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) === '%PDF';
      var ok = r.resp.getResponseCode() === 200 && isPdf;
      results.push(['Download newest PDF', ok ? 'PASS' : 'FAIL',
        url.split('/').pop() + ': ' + describe(r) + ', real PDF: ' + (isPdf ? 'yes' : 'no')]);
    }
  } else {
    results.push(['Download newest PDF', 'FAIL', 'skipped: no PDF link found on listing page 0']);
  }

  results.forEach(function (row) {
    Logger.log((row[1] ? '[' + row[1] + '] ' + row[0] + ': ' : '  ') + row[2]);
  });
  var allOk = results.every(function (row) { return row[1] !== 'FAIL'; });
  Logger.log(allOk
    ? 'RESULT: CBSL answers Google\'s servers. The fetch step can run on Apps Script.'
    : 'RESULT: at least one check failed. See the details above.');
}