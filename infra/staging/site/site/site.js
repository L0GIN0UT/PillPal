// Copy button of the test-group address. Loaded with defer: the DOM is ready.
document.getElementById('copy').addEventListener('click', function () {
  var text = document.getElementById('addr').textContent;
  var out = document.getElementById('copied');
  // Clear the live region first, so a repeated message is announced again.
  function say(message) {
    out.textContent = '';
    setTimeout(function () { out.textContent = message; }, 50);
  }
  function selectIt() {
    var r = document.createRange();
    r.selectNodeContents(document.getElementById('addr'));
    var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
    say('Адрес выделен — скопируйте его');
  }
  try {
    navigator.clipboard.writeText(text).then(function () { say('Скопировано'); }, selectIt);
  } catch (e) { selectIt(); }
});
