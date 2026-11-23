// Injected into the WebGPU CTS standalone page by webkit-cts.sh (through webkithost): presses the first "Run subtree"
// (the query's root) and every 15 s logs the status counts and each failing node not reported yet (CTSNODE; for a
// failing case also its failure text, CTSLOG: 2500 characters for the first 10, 200 for the rest), so a run cut off by
// the time limit keeps what it found; when the run finishes ("Finished run" on the console) or nothing has changed for
// 30 minutes, the final counts and WEBKITHOST_DONE. With #list in the URL it only logs every node's query (CTSQUERY).
(function () {
  var clicked = false, last = '', stable = 0, finished = false;
  var logs = 10, shown = 0, reported = {};
  var original = console.log;
  console.log = function () {
    if (Array.prototype.join.call(arguments, ' ').indexOf('Finished run') >= 0) finished = true;
    return original.apply(console, arguments);
  };
  function counts() {
    var c = {};
    document.querySelectorAll('[data-status]').forEach(function (e) { var k = e.getAttribute('data-status') || 'pending'; c[k] = (c[k] || 0) + 1; });
    return JSON.stringify(c);
  }
  function query(e) { var q = e.querySelector('input.nodequery'); return q ? q.value : '?'; }
  function report() {
    document.querySelectorAll('[data-status=fail], [data-status=warn], [data-status=passfail]').forEach(function (e) {
      var q = query(e), status = e.getAttribute('data-status');
      if (reported[q] === status) return;
      reported[q] = status;
      console.log('CTSNODE ' + status + ' ' + q);
      if (status !== 'fail' || /\*$/.test(q)) return;
      var t = e.textContent.replace(/\s+\n/g, '\n'), k = t.search(/EXPECTATION FAILED|EXCEPTION/);
      t = k >= 0 ? t.slice(k) : t;
      console.log('CTSLOG ' + q + '\n' + t.slice(0, shown++ < logs ? 2500 : 200));
    });
  }
  if (location.hash === '#list') {  // webkit-cts.sh SPLIT=1: the subtree queries of the page's tree, then done
    var lister = setInterval(function () {
      if (!document.querySelector('button.subtreerun')) return;
      clearInterval(lister);
      document.querySelectorAll('input.nodequery').forEach(function (q) { console.log('CTSQUERY ' + q.value); });
      console.log('WEBKITHOST_DONE');
    }, 2000);
    return;
  }
  var timer = setInterval(function () {
    if (!clicked) {
      var b = document.querySelector('button.subtreerun');
      if (b) { b.click(); clicked = true; console.log('CTS started'); }
      return;
    }
    var c = counts();
    if (c !== last) { console.log('CTS ' + new Date().toTimeString().slice(0, 8) + ' ' + c); last = c; stable = 0; } else stable++;
    report();
    if (!finished && stable < 120) return;
    clearInterval(timer);
    console.log('CTS final ' + c + (finished ? '' : ' (no change in 30 minutes: stalled?)'));
    console.log('WEBKITHOST_DONE');
  }, 15000);
})();
