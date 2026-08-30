// ==UserScript==
// @name         Google Photos — icon-only nav rail
// @namespace    kattakath.com
// @version      1.1.0
// @description  Collapse the Google Photos left navigation to an icon-only rail and hand the reclaimed width to the photo grid.
// @homepageURL  https://github.com/kattakath/nix-config
// @downloadURL  https://raw.githubusercontent.com/kattakath/nix-config/main/userscripts/google-photos-icon-nav.user.js
// @updateURL    https://raw.githubusercontent.com/kattakath/nix-config/main/userscripts/google-photos-icon-nav.user.js
// @match        https://photos.google.com/*
// @run-at       document-start
// @grant        GM_addStyle
// @noframes
// ==/UserScript==

// Why a userscript and not a userstyle: the effect is pure CSS, but every class
// name in this nav is JSCompiler-generated (RSjvib, oUj9s, U1Qaj, JBVD2d, …) and
// rotates without notice. The only durable handles are ARIA roles and structure,
// and the grid additionally has to be told to re-measure — see the resize kick
// at the bottom. Both selectors and geometry below were read off the live
// logged-in DOM at 1452px, not inferred.
(() => {
  'use strict';

  const root = document.documentElement;
  if (!root || root.dataset.nixGooglePhotosRail) return;
  root.dataset.nixGooglePhotosRail = '1';

  // 80px is Material 3's navigation-rail width — also what Photos itself uses at
  // narrow viewports, so the icons land on Google's own grid rather than a made-up
  // one. 256px is the expanded drawer's natural width (measured).
  const RAIL = 80;
  const DRAWER = 256;

  GM_addStyle(`
    :root {
      --nix-rail: ${RAIL}px;
      --nix-drawer: ${DRAWER}px;
    }

    /* The rail. overflow-x prevents re-wrapping: the inner column stays laid out
       at 256px and the rail shows its leftmost 80px. Note the consequence —
       clipping is NOT hiding. Any text-only block left visible gets sliced
       mid-word ("Collec…", "Unlimit…"), so every such block needs its own
       display:none rule below; overflow-x alone is not enough. */
    div[role="navigation"] {
      width: var(--nix-rail) !important;
      min-width: var(--nix-rail) !important;
      overflow-x: hidden !important;
    }

    /* Pin the inner column at the drawer's natural width so NOTHING reflows.
       Measured: this column has exactly TWO children — the scrolling tab list
       (256x740) and the storage footer (256x57), handled separately below. */
    div[role="navigation"] > div {
      width: var(--nix-drawer) !important;
      min-width: var(--nix-drawer) !important;
    }

    /* Icons only. The label wrapper is "the grandchild div holding no <svg>" —
       the one class-free way to tell it from the icon/badge wrapper. Shrinking
       the row to 56px turns the 232px selected-item pill back into a circle. */
    div[role="navigation"] a[role="tab"] > div > div:not(:has(svg)) {
      display: none !important;
    }
    div[role="navigation"] a[role="tab"] {
      width: 56px !important;
      min-width: 56px !important;
      max-width: 56px !important;
    }
    div[role="navigation"] a[role="tab"] > div {
      justify-content: center !important;
    }

    /* Text-only blocks the tab rules above do not reach. Both are pure labels
       with no icon, so at 80px they can only ever be clipped garbage.

       1. The "Collections" section heading — a bare class-only <div> with no
       role and no aria, so the durable handle is "direct child of the tab list
       that contains no tab". Verified: exactly ONE visible match. */
    div[role="navigation"] > div > div:first-child > div:not(:has(a[role="tab"])) {
      display: none !important;
    }

    /* 2. The "Unlimited storage" footer — the second of the column's two
       children (256x57 at the bottom). nth-child(2) rather than :last-child on
       purpose: if Google ever ships a one-child nav, :last-child would resolve
       to the tab list and blank the whole rail, while this degrades to a
       no-op. */
    div[role="navigation"] > div > div:nth-child(2) {
      display: none !important;
    }

    /* Hand the reclaimed 176px to the grid. Both boxes are position:absolute,
       but in DIFFERENT containing blocks: the wrapper sits against the app root
       (left:256px) while [role="main"] sits against the wrapper (left:0), so
       only the wrapper may be moved — shifting both would push the grid to
       160px. Gated on the nav existing so any view that renders no nav is left
       completely untouched. */
    body:has(div[role="navigation"]) div:has(> [role="main"]) {
      left: var(--nix-rail) !important;
      right: 0 !important;
      width: auto !important;
    }
    body:has(div[role="navigation"]) [role="main"] {
      right: 0 !important;
      width: auto !important;
    }
  `);

  // The grid is JS-virtualised: tile geometry AND the thumbnail request size
  // (…=w126-h213-k-no) are computed from the measured pane width, so CSS alone
  // leaves it laid out for the old 1196px pane. Photos re-measures on `resize`.
  // Coalesced into one rAF so a burst of route changes fires a single kick.
  let queued = false;
  const kick = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      window.dispatchEvent(new Event('resize'));
    });
  };

  // Photos is an SPA: navigating Albums → Places re-renders the grid without a
  // reload. Patching history is cheaper and quieter than a MutationObserver on a
  // ~1.8 MB DOM, and the CSS itself needs no re-application (a stylesheet
  // applies to nodes created later — which is why nothing here tags DOM nodes;
  // several nav entries are lazily materialised by c-wiz renderers).
  for (const method of ['pushState', 'replaceState']) {
    const original = history[method];
    history[method] = function patched(...args) {
      const result = original.apply(this, args);
      kick();
      return result;
    };
  }
  window.addEventListener('popstate', kick);

  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', kick, { once: true });
  } else {
    kick();
  }
  window.addEventListener('load', kick, { once: true });
})();
