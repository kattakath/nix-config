// ==UserScript==
// @name         LeoList — listings only
// @namespace    kattakath.com
// @version      1.0.0
// @description  Hide LeoList listing-page chrome (header, filters, footer, safety tips, ad column, overlays) and sponsored cards, leaving the organic listing results.
// @author       Ismail Kattakath
// @license      MIT
// @homepageURL  https://github.com/kattakath/nix-config
// @supportURL   https://github.com/kattakath/nix-config/issues
// @match        https://www.leolist.cc/personals/*
// @match        https://leolist.cc/personals/*
// @run-at       document-start
// @grant        none
// @noframes
// ==/UserScript==

// LeoList does not ship a listings-only view. Measured 2026-08-31 on
// https://www.leolist.cc/personals/female-escorts/greater-toronto/york
// (headless dump-dom, innerWidth 1440): the organic cards live in
// #main_list as div.group > div.lst.lst-item[data-testid="ad-item"],
// and the chrome around them is named, not a breakpoint. Cross-origin
// sheets (10 of them) so there is nothing to lift. Detail pages under
// the same @match have no #main_list — the script stays a no-op there
// (the page renders stock). Pagination stays: it is how you see page 2.
//
// Selectors, all from that dump:
//   header.main-header                    site header (92px, position:relative)
//   .main-list-filter                     category/location picker + its modal
//   .filters.js-filters                   desktop filter bar (heading lives in it)
//   #modal-filters                        mobile filter modal
//   #ethnicities                          ethnicity filter dialog
//   footer.footer                         site footer
//   .human-rights                         trafficking banner under the footer
//   #menu, #menu-backdrop                 burger menu
//   aside.main-list__safety-tips          safety-tips block mid-list
//   #rightColumn                          desktop-right-column ad banners
//   .main-list-sponsors                   "SPONSORS" tab strip above the cards
//   .sticky-side                          Take Cover / back-to-top
//   #alert-rails                          sliding alert rail
//   #m-terms, .modal-backdrop             terms overlay (body.modal-open in the dump)
//   .ll-modal, .ll-modal__backdrop        auth and the other stacked modals
//   #dialog-authorization                 login/register modal
//   dialog#language-dialog                language picker
//   .group:has(.lst-item__label--sponsored)
//                                         five sponsored cards mixed into #main_list
//                                         (itemtype Offer, no data-testid="ad-item")
(() => {
  'use strict';

  if (document.documentElement.dataset.nixLeolistListingsOnlyInit !== undefined) return;
  document.documentElement.dataset.nixLeolistListingsOnlyInit = '';

  const CSS = [
    'html[data-nix-leolist-listings-only] header.main-header',
    'html[data-nix-leolist-listings-only] .main-list-filter',
    'html[data-nix-leolist-listings-only] .filters.js-filters',
    'html[data-nix-leolist-listings-only] #modal-filters',
    'html[data-nix-leolist-listings-only] #ethnicities',
    'html[data-nix-leolist-listings-only] footer.footer',
    'html[data-nix-leolist-listings-only] .human-rights',
    'html[data-nix-leolist-listings-only] #menu',
    'html[data-nix-leolist-listings-only] #menu-backdrop',
    'html[data-nix-leolist-listings-only] aside.main-list__safety-tips',
    'html[data-nix-leolist-listings-only] #rightColumn',
    'html[data-nix-leolist-listings-only] .main-list-sponsors',
    'html[data-nix-leolist-listings-only] .sticky-side',
    'html[data-nix-leolist-listings-only] #alert-rails',
    'html[data-nix-leolist-listings-only] #m-terms',
    'html[data-nix-leolist-listings-only] .modal-backdrop',
    'html[data-nix-leolist-listings-only] .ll-modal',
    'html[data-nix-leolist-listings-only] .ll-modal.ll-modal--open',
    'html[data-nix-leolist-listings-only] .ll-modal__backdrop',
    'html[data-nix-leolist-listings-only] #dialog-authorization',
    'html[data-nix-leolist-listings-only] dialog#language-dialog',
    'html[data-nix-leolist-listings-only] .group:has(.lst-item__label--sponsored)',
  ].join(',\n') + ' {\n  display: none;\n}\n' +
    'html[data-nix-leolist-listings-only] body.modal-open {\n  overflow: auto;\n}\n';

  const sheet = new CSSStyleSheet();
  sheet.replaceSync(CSS);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];

  const unlockScroll = () => {
    const body = document.body;
    if (body && body.classList.contains('modal-open')) body.classList.remove('modal-open');
  };

  const arm = () => {
    if (!document.getElementById('main_list')) return false;
    if (document.documentElement.dataset.nixLeolistListingsOnly === undefined) {
      document.documentElement.dataset.nixLeolistListingsOnly = '';
    }
    unlockScroll();
    return true;
  };

  if (arm()) return;

  const obs = new MutationObserver(() => {
    if (arm()) obs.disconnect();
  });
  obs.observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener(
    'DOMContentLoaded',
    () => {
      if (!arm()) obs.disconnect();
    },
    { once: true },
  );
})();
