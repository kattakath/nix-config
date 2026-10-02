const sets = [
  { genericFamily: 'standard', script: 'Mlym', fontId: 'Noto Sans Malayalam' },
  { genericFamily: 'sansserif', script: 'Mlym', fontId: 'Noto Sans Malayalam' },
  { genericFamily: 'fixed', script: 'Mlym', fontId: 'Noto Sans Malayalam' },
  { genericFamily: 'serif', script: 'Mlym', fontId: 'Noto Serif Malayalam' },
];

function applyFonts() {
  for (const s of sets) { chrome.fontSettings.setFont(s); }
}

chrome.runtime.onInstalled.addListener(applyFonts);
chrome.runtime.onStartup.addListener(applyFonts);
applyFonts();
