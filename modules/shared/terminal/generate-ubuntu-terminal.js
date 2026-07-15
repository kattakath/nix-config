// Regenerates ./Ubuntu.terminal — a macOS Terminal.app profile ("Window
// Settings" plist) styled like the Ubuntu GNOME terminal. Colors + typography
// mirror the VS Code integrated-terminal palette in ../home.nix
// (workbench.colorCustomizations "Ubuntu 24" + UbuntuMono Nerd Font 16).
//
// Terminal.app stores colors/font as NSKeyedArchiver blobs, which Nix has no
// native way to emit, so the profile is a committed pre-generated artifact.
// Regenerate (only needed if the palette/font here changes) with:
//
//   osascript -l JavaScript modules/shared/terminal/generate-ubuntu-terminal.js
//   # writes to $OUT (default: ./Ubuntu.terminal), then: plutil -convert xml1 <file>
//
// Uses JXA's ObjC bridge (system Python lost pyobjc on modern macOS). The
// activation step in ../home.nix imports the artifact into com.apple.Terminal.
ObjC.import('AppKit');
ObjC.import('Foundation');

function hexColor(hex) {
  const r = parseInt(hex.slice(1, 3), 16) / 255.0;
  const g = parseInt(hex.slice(3, 5), 16) / 255.0;
  const b = parseInt(hex.slice(5, 7), 16) / 255.0;
  return $.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, 1.0);
}
function archive(obj) {
  // archivedDataWithRootObject: — the exact (non-secure) keyed-archive format
  // Terminal.app writes for its own color/font blobs.
  return $.NSKeyedArchiver.archivedDataWithRootObject(obj);
}

// Resolve the UbuntuMono font, preferring the Nerd Font variants, else fall back.
const fm = $.NSFontManager.sharedFontManager;
const fams = ObjC.deepUnwrap(fm.availableFontFamilies);
const ubu = fams.filter(f => f.toLowerCase().indexOf('buntu') >= 0);
let font = null, used = null;
for (const name of ['UbuntuMono Nerd Font', 'UbuntuMono Nerd Font Mono', 'Ubuntu Mono', 'Ubuntu Mono derivative Powerline']) {
  const f = $.NSFont.fontWithNameSize(name, 16.0);
  if (f && !f.isNil()) { font = f; used = name; break; }
}
if (!font) { font = $.NSFont.userFixedPitchFontOfSize(16.0); used = '(fallback fixed-pitch)'; }

const palette = {
  bg: '#300A24', fg: '#FFFFFF', bold: '#FFFFFF', cursor: '#FFFFFF', sel: '#5A2A48',
  ansi: ['#2E3436','#CC0000','#4E9A06','#C4A000','#3465A4','#75507B','#06989A','#D3D7CF',
         '#555753','#EF2929','#8AE234','#FCE94F','#729FCF','#AD7FA8','#34E2E2','#EEEEEC'],
};
const ansiKeys = ['ANSIBlackColor','ANSIRedColor','ANSIGreenColor','ANSIYellowColor',
  'ANSIBlueColor','ANSIMagentaColor','ANSICyanColor','ANSIWhiteColor',
  'ANSIBrightBlackColor','ANSIBrightRedColor','ANSIBrightGreenColor','ANSIBrightYellowColor',
  'ANSIBrightBlueColor','ANSIBrightMagentaColor','ANSIBrightCyanColor','ANSIBrightWhiteColor'];

const d = $.NSMutableDictionary.alloc.init;
d.setObjectForKey($('Ubuntu'), $('name'));
d.setObjectForKey($('Window Settings'), $('type'));
d.setObjectForKey(archive(hexColor(palette.bg)), $('BackgroundColor'));
d.setObjectForKey(archive(hexColor(palette.fg)), $('TextColor'));
d.setObjectForKey(archive(hexColor(palette.bold)), $('TextBoldColor'));
d.setObjectForKey(archive(hexColor(palette.cursor)), $('CursorColor'));
d.setObjectForKey(archive(hexColor(palette.sel)), $('SelectionColor'));
d.setObjectForKey(archive(font), $('Font'));
d.setObjectForKey($.NSNumber.numberWithBool(true), $('FontAntialias'));
d.setObjectForKey($.NSNumber.numberWithInt(0), $('CursorType')); // 0 = block
d.setObjectForKey($.NSNumber.numberWithBool(true), $('useOptionAsMetaKey'));
d.setObjectForKey($.NSNumber.numberWithInt(110), $('columnCount'));
d.setObjectForKey($.NSNumber.numberWithInt(30), $('rowCount'));
d.setObjectForKey($.NSNumber.numberWithBool(false), $('ShouldLimitScrollback'));
palette.ansi.forEach((hex, i) => d.setObjectForKey(archive(hexColor(hex)), $(ansiKeys[i])));

const outEnv = $.NSProcessInfo.processInfo.environment.objectForKey('OUT');
const outPath = (outEnv && !outEnv.isNil()) ? outEnv.js : 'Ubuntu.terminal';
const ok = d.writeToFileAtomically($(outPath), true);
console.log('ubuntu-families=' + JSON.stringify(ubu));
console.log('font-used=' + used);
console.log('wrote=' + ok + ' -> ' + outPath);
