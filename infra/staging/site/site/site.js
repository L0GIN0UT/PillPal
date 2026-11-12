// Copy button of the test-group address. Loaded with defer: the DOM is ready.
document.getElementById('copy').addEventListener('click', function () {
  var text = document.getElementById('addr').textContent;
  var out = document.getElementById('copied');
  function selectIt() {
    var r = document.createRange();
    r.selectNodeContents(document.getElementById('addr'));
    var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
    out.textContent = 'Адрес выделен, нажмите Ctrl+C';
  }
  try {
    navigator.clipboard.writeText(text).then(function () { out.textContent = 'Скопировано'; }, selectIt);
  } catch (e) { selectIt(); }
});
