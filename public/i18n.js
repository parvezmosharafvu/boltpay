// Dashboard language switch (English / বাংলা), shared by dashboard.html and
// admin.html. Same storage key as the login pages (auth.js), so the choice
// carries across the whole app.
//
//  - Elements with data-en / data-bn get the text for the chosen language
//    (data-ph-en / data-ph-bn for placeholders).
//  - Older strings written as "English · বাংলা", "English / বাংলা" or
//    "English (বাংলা)" are split at render time, so only one language shows.
//    This also covers toasts and rows rendered later by JS.
(function(){
  const KEY = 'boltpay_lang';
  const lang = () => (localStorage.getItem(KEY) === 'bn' ? 'bn' : 'en');
  window.uiLang = lang;
  window.t = window.t || ((en, bn) => lang() === 'bn' ? bn : en);

  // A Bengali letter (not ৳ and not just digits) marks the Bengali half.
  const BN = /[\u0985-\u09B9\u09BC-\u09D7\u09DC-\u09DF]/;
  const startsBn = s => /^[\u0980-\u09FF]/.test(s.trim()) && BN.test(s);
  function split(s){
    if (!s || !BN.test(s)) return s;
    const want = lang();
    // "English (বাংলা …)" at the end
    let m = s.match(/^([\s\S]*?\S)\s*\(([^()]*)\)\s*$/);
    if (m && !BN.test(m[1]) && startsBn(m[2])) return want === 'bn' ? m[2] : m[1];
    // "English · বাংলা" / "English / বাংলা" — split at the last separator
    // whose right side is Bengali and left side is not.
    for (const sep of [' · ', ' / ']){
      let i = s.lastIndexOf(sep);
      while (i > 0){
        const L = s.slice(0, i), R = s.slice(i + sep.length);
        if (!BN.test(L) && startsBn(R)){
          // keep a trailing ": detail" on the English side's message
          const tail = R.match(/^([^:]*?)(:\s[\s\S]*)$/);
          if (tail && !BN.test(tail[2])) return want === 'bn' ? tail[1] + tail[2] : L + tail[2];
          return want === 'bn' ? R : L;
        }
        i = s.lastIndexOf(sep, i - 1);
      }
    }
    return s;
  }
  window.splitLang = split;

  const ORIG = new WeakMap();
  function fixText(node){
    const cur = node.nodeValue;
    let o = ORIG.get(node);
    if (o === undefined || (cur !== o.out)) { o = { src: cur }; }
    const out = split(o.src);
    o.out = out; ORIG.set(node, o);
    if (out !== cur) node.nodeValue = out;
  }
  function fixAttr(el, attr){
    const k = 'i18nSrc' + attr;
    const src = el.dataset[k] ?? el.getAttribute(attr);
    if (!src || !BN.test(src)) return;
    el.dataset[k] = src;
    const out = split(src);
    if (el.getAttribute(attr) !== out) el.setAttribute(attr, out);
  }
  function walk(root){
    if (!root) return;
    if (root.nodeType === 3) { fixText(root); return; }
    if (root.nodeType !== 1 || /^(SCRIPT|STYLE|TEXTAREA)$/.test(root.tagName)) return;
    const l = lang();
    const els = [root, ...root.querySelectorAll('*')];
    for (const el of els){
      if (el.dataset && el.dataset.en !== undefined && el.dataset.bn !== undefined){
        const v = l === 'bn' ? el.dataset.bn : el.dataset.en;
        if (el.textContent !== v) el.textContent = v;
        continue;
      }
      if (el.dataset && el.dataset.phEn !== undefined) el.placeholder = l === 'bn' ? el.dataset.phBn : el.dataset.phEn;
      else if (el.hasAttribute && el.hasAttribute('placeholder')) fixAttr(el, 'placeholder');
      if (el.hasAttribute && el.hasAttribute('title')) fixAttr(el, 'title');
    }
    const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: n => (n.parentElement && /^(SCRIPT|STYLE|TEXTAREA)$/.test(n.parentElement.tagName)) || (n.parentElement && n.parentElement.closest('[data-en][data-bn]')) ? 2 : 1
    });
    let n; while ((n = tw.nextNode())) fixText(n);
  }
  function apply(){
    document.documentElement.lang = lang();
    walk(document.body);
    document.querySelectorAll('.lang-btn').forEach(b => { b.textContent = lang() === 'bn' ? 'English' : 'বাংলা'; });
  }
  window.applyUiLang = apply;
  window.toggleUiLang = () => { localStorage.setItem(KEY, lang() === 'bn' ? 'en' : 'bn'); apply(); window.dispatchEvent(new Event('uilangchange')); };

  // Native dialogs take raw strings.
  const _c = window.confirm.bind(window), _p = window.prompt.bind(window), _a = window.alert.bind(window);
  window.confirm = m => _c(split(String(m)));
  window.prompt = (m, d) => _p(split(String(m)), d);
  window.alert = m => _a(split(String(m)));

  let busy = false;
  const mo = new MutationObserver(recs => {
    if (busy) return; busy = true;
    try {
      for (const r of recs){
        if (r.type === 'characterData') fixText(r.target);
        else r.addedNodes.forEach(walk);
      }
    } finally { busy = false; }
  });
  function start(){
    const slot = document.querySelector('.header-actions, .header-right');
    if (slot && !slot.querySelector('.lang-btn')){
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'lang-btn'; b.onclick = window.toggleUiLang;
      slot.insertBefore(b, slot.firstChild);
    }
    apply();
    mo.observe(document.body, { childList: true, subtree: true, characterData: true });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
