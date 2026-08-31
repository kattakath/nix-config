// ==UserScript==
// @name         LeoList — listings only
// @namespace    kattakath.com
// @version      1.1.0
// @description  Hide LeoList listing-page chrome and sponsored cards; fetch each organic ad and append its description plus extra photos under the card.
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
// Enrichment (v1.1.0), same date, second dump on
// /personals/female-escorts/greater-toronto/york_outcall_party_girl_100_duo-8313854:
// each organic card's a.lst-item__link.mainlist-item[href] is a same-origin
// ad page. That page's extra fields are #preview-description (ad body) and
// .account-photos__item img (extra thumbs on imx.leolist.cc). Phone/WhatsApp
// sit behind .unlock-contacts-btn with an empty #preview-phone — left alone.
// Fetch is same-origin, @grant none, concurrency 3, IntersectionObserver so
// off-screen cards are not requested. A failed fetch leaves the card stock.
//
// Hide selectors, all from the listing dump:
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
//
// Enrich selectors, from the ad-page dump:
//   a.lst-item__link.mainlist-item        card permalink (listing dump)
//   [data-testid="ad-item"]               organic card (listing dump)
//   #preview-description                  ad body (detail dump)
//   .account-photos__item img             extra thumbs (detail dump)
//
// Invented (no site class for "description under the card"):
//   .nix-leolist-extra / -photos / -desc  measured 2026-08-31 as constructed UI
(() => {
  'use strict';

  if (document.documentElement.dataset.nixLeolistListingsOnlyInit !== undefined) return;
  document.documentElement.dataset.nixLeolistListingsOnlyInit = '';

  const IMX = 'https://imx.leolist.cc/';
  const CONCURRENCY = 3;

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
    'html[data-nix-leolist-listings-only] body.modal-open {\n  overflow: auto;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-extra {\n  margin: 8px 0 16px;\n  padding: 0 8px;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-photos {\n  display: flex;\n  flex-wrap: wrap;\n  gap: 6px;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-photos img {\n  width: 96px;\n  height: 96px;\n  object-fit: cover;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-desc {\n  margin: 8px 0 0;\n}\n';

  const sheet = new CSSStyleSheet();
  sheet.replaceSync(CSS);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];

  const unlockScroll = () => {
    const body = document.body;
    if (body && body.classList.contains('modal-open')) body.classList.remove('modal-open');
  };

  const cache = new Map();
  let active = 0;
  const queue = [];
  const pump = () => {
    while (active < CONCURRENCY && queue.length) {
      const job = queue.shift();
      active += 1;
      job().finally(() => {
        active -= 1;
        pump();
      });
    }
  };
  const enqueue = (job) => {
    queue.push(job);
    pump();
  };

  const parseDetail = (html) => {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const descEl = doc.getElementById('preview-description');
    const desc = descEl ? descEl.textContent.replace(/\s+/g, ' ').trim() : '';
    const photos = [];
    const seen = new Set();
    for (const img of doc.querySelectorAll('.account-photos__item img')) {
      const src = img.getAttribute('src') || '';
      if (src.indexOf(IMX) !== 0) continue;
      if (seen.has(src)) continue;
      seen.add(src);
      photos.push(src);
    }
    return { desc, photos };
  };

  const loadDetail = async (href) => {
    const hit = cache.get(href);
    if (hit) return hit;
    const res = await fetch(href, { credentials: 'same-origin' });
    if (!res.ok) return null;
    const parsed = parseDetail(await res.text());
    cache.set(href, parsed);
    return parsed;
  };

  const renderExtra = (card, href, data) => {
    if (card.querySelector('.nix-leolist-extra')) return;
    const extra = document.createElement('div');
    extra.className = 'nix-leolist-extra';

    if (data.photos.length) {
      const hero = card.querySelector('[data-testid="listing-pic"]');
      const heroSrc = hero ? hero.getAttribute('src') : '';
      const row = document.createElement('div');
      row.className = 'nix-leolist-photos';
      for (const src of data.photos) {
        if (src === heroSrc) continue;
        const a = document.createElement('a');
        a.href = href;
        const img = document.createElement('img');
        img.src = src;
        img.alt = '';
        a.appendChild(img);
        row.appendChild(a);
      }
      if (row.childNodes.length) extra.appendChild(row);
    }

    if (data.desc) {
      const p = document.createElement('p');
      p.className = 'nix-leolist-desc';
      p.textContent = data.desc;
      extra.appendChild(p);
    }

    if (!extra.childNodes.length) return;
    card.appendChild(extra);
  };

  const enrichCard = async (card) => {
    if (card.dataset.nixLeolistEnrich !== undefined) return;
    const link = card.querySelector('a.lst-item__link.mainlist-item');
    const href = link ? link.getAttribute('href') : '';
    if (!href || href.indexOf('/personals/') === -1) return;
    card.dataset.nixLeolistEnrich = 'pending';
    try {
      const data = await loadDetail(href);
      if (!data) {
        card.dataset.nixLeolistEnrich = 'fail';
        return;
      }
      renderExtra(card, href, data);
      card.dataset.nixLeolistEnrich = 'done';
    } catch {
      card.dataset.nixLeolistEnrich = 'fail';
    }
  };

  let io = null;
  const observeCard = (card) => {
    if (card.dataset.nixLeolistEnrich !== undefined) return;
    if (!io) {
      enqueue(() => enrichCard(card));
      return;
    }
    io.observe(card);
  };

  const scan = () => {
    const list = document.getElementById('main_list');
    if (!list) return;
    for (const card of list.querySelectorAll('[data-testid="ad-item"]')) observeCard(card);
  };

  let watching = false;
  const watchList = () => {
    if (watching) return;
    const list = document.getElementById('main_list');
    if (!list) return;
    watching = true;

    if (self.IntersectionObserver) {
      io = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (!entry.isIntersecting) continue;
            io.unobserve(entry.target);
            enqueue(() => enrichCard(entry.target));
          }
        },
        { rootMargin: '600px 0px' },
      );
    }

    let queued = false;
    const coalesce = () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        scan();
      });
    };
    new MutationObserver(coalesce).observe(list, { childList: true });
    scan();
  };

  const arm = () => {
    if (!document.getElementById('main_list')) return false;
    if (document.documentElement.dataset.nixLeolistListingsOnly === undefined) {
      document.documentElement.dataset.nixLeolistListingsOnly = '';
    }
    unlockScroll();
    watchList();
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
