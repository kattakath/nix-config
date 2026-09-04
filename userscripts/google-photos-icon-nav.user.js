// ==UserScript==
// @name         Google Photos — icon-only nav rail
// @namespace    kattakath.com
// @version      2.2.0
// @description  Make Google Photos render its own narrow-viewport icon rail at every window width, by replaying its responsive breakpoint unconditionally and muting the wide-viewport block that fights it.
// @author       Ismail Kattakath
// @license      MIT
// @homepageURL  https://github.com/kattakath/nix-config
// @supportURL   https://github.com/kattakath/nix-config/issues
// @match        https://photos.google.com/*
// @run-at       document-start
// @grant        none
// @noframes
// ==/UserScript==

// Photos ALREADY ships the layout we want: below a viewport breakpoint it
// collapses the nav to an 80px icon rail that peeks back to 256px on hover,
// hides the storage footer, and turns the "Collections" heading into a 1px
// divider. Measured: identical DOM either side of the breakpoint — same classes,
// same attributes — so the switch is a pure CSS media query and there is nothing
// a selector can force.
//
// So don't reimplement the rail (v1.x did, and lost: `overflow-x:hidden` clips
// rather than hides, so every text-only block had to be chased down by hand and
// three were still leaking). Instead lift Google's own breakpoint rules out of
// their @media wrapper and re-serve them unconditionally. Consequence worth
// stating: this file contains NOT ONE Google class name, so the JSCompiler
// churn that breaks every hand-written Photos userscript cannot break it.
(() => {
  'use strict';

  // Which breakpoint to lift. Photos' rail currently sits at max-width:1007px,
  // but hardcoding that re-couples us to a number Google owns, so instead pick
  // the BIGGEST `screen and (max-width: Npx)` block in this band. The band's job
  // is to exclude the neighbours: phone layouts below it (599px hides the rail
  // entirely behind a hamburger — not what we want) and the incidental
  // wide-viewport queries above it (1423px).
  //
  // Biggest, not widest — measured in-page 2026-09-04. A chunk that loads on SPA
  // back-nav (collection → item → back arrow) adds a 5-rule `max-width:1008px`
  // block, 1px wider than the rail's 1007, so "widest in band" served 372 chars
  // of scrim CSS and dropped all 83 rail rules until a reload. Rule count
  // separates the two by an order of magnitude without naming a Google number.
  const BAND_MIN = 800;
  const BAND_MAX = 1200;
  const CONDITION = /^screen\s+and\s+\(max-width:\s*(\d+)px\)$/;
  const MIN_WIDTH = /\(min-width:\s*(\d+)px\)/;

  let styleEl = null;

  // Photos' CSS is ~11 inline <style> blocks, same-origin, so cssRules reads
  // fine. A cross-origin sheet throws on access instead of returning null —
  // hence the try. If Google ever moves this CSS to a no-CORS gstatic URL every
  // sheet becomes unreadable and this whole script degrades to a no-op, which
  // is the correct failure: the page renders stock, nothing is mangled.
  const collectBreakpointCss = () => {
    const byWidth = new Map();

    for (const sheet of document.styleSheets) {
      let rules;
      try {
        rules = sheet.cssRules;
      } catch {
        continue;
      }
      if (!rules) continue;

      for (const rule of rules) {
        if (rule.type !== CSSRule.MEDIA_RULE) continue;
        const match = CONDITION.exec(rule.conditionText.trim());
        if (!match) continue;
        const width = Number(match[1]);
        if (width < BAND_MIN || width > BAND_MAX) continue;

        // Several separate @media blocks share the one breakpoint (the rail, the
        // content offset, the header's collapsed search), so accumulate rather
        // than take the first.
        const bucket = byWidth.get(width) ?? [];
        for (const inner of rule.cssRules) bucket.push(inner.cssText);
        byWidth.set(width, bucket);
      }
    }

    if (byWidth.size === 0) return null;
    let best = null;
    for (const [width, rules] of byWidth) {
      const better =
        best === null ||
        rules.length > best.rules.length ||
        (rules.length === best.rules.length && width > best.width);
      if (better) best = { width, rules };
    }
    return { width: best.width, css: best.rules.join('\n') };
  };

  // Lifting can only ADD rules, so it cannot cancel what Photos serves in the
  // OTHER direction. Measured 2026-09-04: one `min-width:1008px` block gives the
  // nav list a -12px overhang and the selected item a +12px margin, which at
  // 1512px stretch the active pill from a 48px circle into a 60px oval and push
  // the 92px list past the 80px rail (documentElement 1528 > 1512). At a real
  // narrow viewport that block is simply OFF, so mute every min-width block above
  // the rail's own breakpoint — flipping `mediaText` is the only edit that needs
  // no guess at what each declaration's narrow value should be, and re-serving
  // `initial` would be a guess (the block also sets display/flex/overflow).
  // Idempotent by construction: a muted block reads `not all` and stops matching.
  const muteAboveRail = (railWidth) => {
    const walk = (rules) => {
      for (const rule of rules) {
        if (rule.type !== CSSRule.MEDIA_RULE) continue;
        const match = MIN_WIDTH.exec(rule.conditionText);
        if (match && Number(match[1]) > railWidth) {
          rule.media.mediaText = 'not all';
          continue;
        }
        walk(rule.cssRules);
      }
    };
    for (const sheet of document.styleSheets) {
      let rules;
      try {
        rules = sheet.cssRules;
      } catch {
        continue;
      }
      if (rules) walk(rules);
    }
  };

  const apply = () => {
    const picked = collectBreakpointCss();
    if (picked === null) return false;
    muteAboveRail(picked.width);
    const css = picked.css;

    if (styleEl === null) {
      styleEl = document.createElement('style');
      styleEl.dataset.nixGooglePhotosRail = '';
    }
    // Downgrade guard. Photos tears sheets down as well as adding them, so a
    // collect can legitimately come back thinner — but never by half. Holding
    // the working payload beats trading it for a stub that renders stock.
    const collapsed = css.length * 2 < styleEl.textContent.length;
    if (!collapsed && styleEl.textContent !== css) styleEl.textContent = css;

    // The lifted rules have the same specificity as the ones they must beat, so
    // order decides: ours has to stay LAST in head. Photos keeps appending
    // <style> blocks as it lazy-loads views, which is why this re-checks rather
    // than appending once. Re-appending only when we are not already last is
    // also what stops the observer below from feeding itself.
    if (document.head !== null && document.head.lastElementChild !== styleEl) {
      document.head.appendChild(styleEl);
    }
    return styleEl.textContent.length > 0;
  };

  // Tile geometry AND the thumbnail request size (…=w126-h213-k-no) are computed
  // from the measured pane width, so widening the pane by 176px leaves the grid
  // laid out for the old one until something makes Photos re-measure. Coalesced
  // into one rAF so a burst of mutations fires a single kick.
  let queued = false;
  const kick = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      window.dispatchEvent(new Event('resize'));
    });
  };

  const applyAndKick = () => {
    if (apply()) kick();
  };

  // At document-start there is no head and no CSS yet, and Photos keeps adding
  // <style> blocks as it lazy-loads views, so this watches instead of running
  // once. Deliberately childList-only on head, never `subtree` and never the
  // grid: the photo grid is virtualised and mutates continuously, so a subtree
  // observer over this ~1.8 MB DOM would fire thousands of times a scroll.
  // Every sheet we care about arrives as a direct child of head.
  const watchHead = () => {
    if (document.head === null) return false;
    new MutationObserver(applyAndKick).observe(document.head, { childList: true });
    return true;
  };

  if (!watchHead()) {
    // head does not exist yet — wait for it, again childList-only (documentElement
    // gains exactly two children in its life, so this fires ~twice).
    const rootObserver = new MutationObserver(() => {
      if (watchHead()) {
        rootObserver.disconnect();
        applyAndKick();
      }
    });
    rootObserver.observe(document.documentElement, { childList: true });
  }

  applyAndKick();
  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', applyAndKick, { once: true });
  }
  window.addEventListener('load', applyAndKick, { once: true });
})();
