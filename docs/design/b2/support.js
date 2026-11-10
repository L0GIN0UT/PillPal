// Minimal standalone shim of the design-canvas runtime, so the *.dc.html boards also open in a
// plain browser. The canvas host provides its own runtime; this file only moves <helmet> into
// <head> and defines DCLogic, so nothing breaks when the original support.js is absent.
(function () {
  window.DCLogic = window.DCLogic || class { renderVals() { return {}; } };
  function lift(el) {
    var h = el.querySelector('helmet');
    if (h) { while (h.firstChild) document.head.appendChild(h.firstChild); h.remove(); }
    el.style.display = 'contents';
  }
  if (!customElements.get('x-dc')) {
    customElements.define('x-dc', class extends HTMLElement {
      connectedCallback() {
        var el = this;
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { lift(el); });
        else lift(el);
      }
    });
  }
})();
