// Shared login/register helpers: language switch (en/bn), password eye,
// inline validation, and bilingual auth error messages.
(function(){
  const KEY = 'boltpay_lang';
  window.authLang = () => (localStorage.getItem(KEY) === 'bn' ? 'bn' : 'en');
  window.t = (en, bn) => authLang() === 'bn' ? bn : en;
  function apply(){
    const l = authLang();
    document.documentElement.lang = l;
    document.querySelectorAll('[data-en]').forEach(el => { el.textContent = l === 'bn' ? el.dataset.bn : el.dataset.en; });
    document.querySelectorAll('[data-ph-en]').forEach(el => { el.placeholder = l === 'bn' ? el.dataset.phBn : el.dataset.phEn; });
    const b = document.getElementById('langBtn'); if (b) b.textContent = l === 'bn' ? 'English' : 'বাংলা';
  }
  window.applyLang = apply;
  window.toggleLang = () => { localStorage.setItem(KEY, authLang() === 'bn' ? 'en' : 'bn'); apply(); };
  window.togglePw = (id, btn) => {
    const i = document.getElementById(id); const show = i.type === 'password';
    i.type = show ? 'text' : 'password';
    btn.setAttribute('aria-label', show ? t('Hide password','পাসওয়ার্ড লুকান') : t('Show password','পাসওয়ার্ড দেখান'));
  };
  window.setFieldError = (id, en, bn) => {
    const i = document.getElementById(id); const f = i.closest('.field');
    const e = f.querySelector('.inline-err');
    if (en){ f.classList.add('invalid'); i.setAttribute('aria-invalid','true'); if (e) e.textContent = t(en, bn); }
    else { f.classList.remove('invalid'); i.removeAttribute('aria-invalid'); }
    return !en;
  };
  const MAP = [
    [/invalid login credentials/i, 'Wrong email or password.', 'ইমেইল বা পাসওয়ার্ড ভুল।'],
    [/email not confirmed/i, 'Please confirm your email first.', 'আগে আপনার ইমেইল নিশ্চিত করুন।'],
    [/already registered|already exists/i, 'An account with this email already exists.', 'এই ইমেইলে আগে থেকেই অ্যাকাউন্ট আছে।'],
    [/rate limit|too many/i, 'Too many attempts. Please wait and try again.', 'অনেকবার চেষ্টা হয়েছে। একটু পরে আবার চেষ্টা করুন।'],
    [/password/i, 'This password is not accepted. Try a stronger one.', 'এই পাসওয়ার্ড গ্রহণযোগ্য নয়। আরও শক্ত পাসওয়ার্ড দিন।'],
    [/valid email|invalid email/i, 'Enter a valid email address.', 'সঠিক ইমেইল ঠিকানা দিন।'],
    [/network|fetch/i, 'Network error. Check your connection.', 'নেটওয়ার্ক সমস্যা। সংযোগ দেখুন।'],
  ];
  window.authErrorText = (msg) => {
    for (const [re, en, bn] of MAP) if (re.test(msg || '')) return t(en, bn);
    return t('Something went wrong. Please try again.', 'কিছু একটা সমস্যা হয়েছে। আবার চেষ্টা করুন।');
  };
  document.addEventListener('DOMContentLoaded', apply);
})();
