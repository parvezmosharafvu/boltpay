/**
 * Boltpay theme engine
 *
 * Every page that should follow the per-domain theme includes this file
 * and calls applyDomainTheme(). It looks up the current hostname in
 * site_domains, reads its `theme`, and swaps CSS custom properties.
 *
 * Themes are palette + font swaps only — one HTML file per page, four
 * looks. Adding a feature never has to be repeated across four copies.
 */

const BOLTPAY_THEMES = {
  voltmeter: {
    label: 'Voltmeter',
    vars: {
      '--bg': '#141022', '--panel': '#1D1830', '--panel-hi': '#241C3B',
      '--line': 'rgba(245,243,255,0.08)',
      '--text': '#F5F3FF', '--text-dim': 'rgba(245,243,255,0.45)', '--text-faint': 'rgba(245,243,255,0.28)',
      '--amber': '#F5A623', '--violet': '#7C5CFF', '--alert': '#FF5C7A', '--ok': '#5CE0A0',
      '--font-display': "'Space Grotesk', sans-serif",
      '--glow-a': 'rgba(124,92,255,0.10)', '--glow-b': 'rgba(245,166,35,0.08)',
    },
  },
  ledger: {
    label: 'Ledger (light paper)',
    vars: {
      '--bg': '#EEF1EC', '--panel': '#FBFBF9', '--panel-hi': '#F2F4EF',
      '--line': '#D9DCD3',
      '--text': '#16221C', '--text-dim': '#5C6A60', '--text-faint': '#93A096',
      '--amber': '#0B6E4F', '--violet': '#A9791E', '--alert': '#B8542E', '--ok': '#0B6E4F',
      '--font-display': "'Zilla Slab', serif",
      '--glow-a': 'rgba(11,110,79,0.05)', '--glow-b': 'rgba(169,121,30,0.05)',
    },
  },
  aurora: {
    label: 'Aurora (magenta/cyan)',
    vars: {
      '--bg': '#0A0E1A', '--panel': 'rgba(255,255,255,0.05)', '--panel-hi': 'rgba(255,255,255,0.08)',
      '--line': 'rgba(255,255,255,0.09)',
      '--text': '#F3F5FC', '--text-dim': 'rgba(243,245,252,0.5)', '--text-faint': 'rgba(243,245,252,0.3)',
      '--amber': '#FF2D87', '--violet': '#22E5C8', '--alert': '#FF5C7A', '--ok': '#22E5C8',
      '--font-display': "'Sora', sans-serif",
      '--glow-a': 'rgba(255,45,135,0.20)', '--glow-b': 'rgba(34,229,200,0.16)',
    },
  },
  calm: {
    label: 'Calm (soft neutral)',
    vars: {
      '--bg': '#F5F6F8', '--panel': '#FFFFFF', '--panel-hi': '#F0F2F6',
      '--line': '#E7E9EE',
      '--text': '#1C1D21', '--text-dim': '#6B6E78', '--text-faint': '#A0A3AC',
      '--amber': '#3E6AE1', '--violet': '#C98A1F', '--alert': '#E1523E', '--ok': '#3E6AE1',
      '--font-display': "'Inter', sans-serif",
      '--glow-a': 'rgba(62,106,225,0.06)', '--glow-b': 'rgba(201,138,31,0.05)',
    },
  },
};

const BOLTPAY_THEME_FONTS = {
  voltmeter: 'Space+Grotesk:wght@500;600;700;800',
  ledger: 'Zilla+Slab:wght@500;600;700',
  aurora: 'Sora:wght@500;600;700;800',
  calm: 'Inter:wght@400;500;600;700;800',
};

function applyThemeVars(themeName) {
  const theme = BOLTPAY_THEMES[themeName] || BOLTPAY_THEMES.voltmeter;
  const root = document.documentElement;
  Object.entries(theme.vars).forEach(([k, v]) => root.style.setProperty(k, v));

  // Pull in the display font this theme needs, if it isn't the default.
  const fontSpec = BOLTPAY_THEME_FONTS[themeName];
  if (fontSpec && !document.getElementById('theme-font-link')) {
    const link = document.createElement('link');
    link.id = 'theme-font-link';
    link.rel = 'stylesheet';
    link.href = `https://fonts.googleapis.com/css2?family=${fontSpec}&display=swap`;
    document.head.appendChild(link);
  }
  document.body.style.fontFamily = theme.vars['--font-display'];
  document.documentElement.setAttribute('data-theme', themeName);
}

/**
 * Looks up this hostname's theme and applies it. Safe to call before the
 * page has any auth session — site_domains is readable by anon.
 * Falls back to voltmeter silently if the domain isn't registered.
 */
async function applyDomainTheme() {
  try {
    const host = window.location.host.toLowerCase();
    const { data } = await window.supabaseClient
      .from('site_domains')
      .select('hostname, theme')
      .eq('is_active', true);

    const match = (data || []).find(d => d.hostname.toLowerCase() === host);
    applyThemeVars(match?.theme || 'voltmeter');
  } catch (e) {
    applyThemeVars('voltmeter');
  }
}
