// White-label branding: on an active custom domain, "Boltpay" becomes the
// owner's brand name on login, register and pay pages. On platform
// domains /api/domain-info returns null and nothing changes.
(function () {
  function apply(name) {
    var re = /Boltpay/g;
    document.title = document.title.replace(re, name);
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    var n; while ((n = walker.nextNode())) if (re.test(n.nodeValue)) n.nodeValue = n.nodeValue.replace(re, name);
    document.querySelectorAll('[data-en],[data-bn]').forEach(function (el) {
      ['data-en', 'data-bn'].forEach(function (a) {
        var v = el.getAttribute(a); if (v && v.indexOf('Boltpay') !== -1) el.setAttribute(a, v.replace(re, name));
      });
    });
    var b = document.getElementById('brand'); if (b) b.textContent = name;
    document.documentElement.setAttribute('data-white-label', '1');
  }
  function run() {
    fetch('/api/domain-info', { credentials: 'omit' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) { if (j && j.data && j.data.brand_name) apply(String(j.data.brand_name).slice(0, 60)); })
      .catch(function () {});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
})();
