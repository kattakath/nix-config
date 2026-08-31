// ==UserScript==
// @name         LeoList — listings only
// @namespace    kattakath.com
// @version      1.4.0
// @description  Listings-only LeoList: keep #view-cont > div.col-left, drop sponsored chrome, filmstrip extra photos beside the hero, clamp the ad description. Parsed extras persist in localStorage for 6h so a refresh does not re-hit the ad pages.
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
// (headless dump-dom, innerWidth 1440): organic cards live in #main_list
// inside #view-cont > div.col-left. v1.2 sibling-hides the island; v1.3
// kills the salad (wrap-dump 96px thumbs + unbounded paragraph under the
// stock row) by composing extras into .lst-item__img as a same-height
// filmstrip and clamping #preview-description to 3 lines in .lst-item__info.
//
// Enrichment still: a.lst-item__link.mainlist-item[href] → same-origin
// fetch; #preview-description textContent; .account-photos__item img on
// imx.leolist.cc; phone stays locked. IntersectionObserver + concurrency 3;
// visibilitychange reconnects IO so a hidden tab fills on focus.
// v1.4.0: parsed {desc, photos} live in localStorage (key nix-leolist.v1:<href>,
// TTL 6h, cap 400, 15min negative cache). Refresh/revisit hits the store, not
// the origin. In-memory Map is L1 for the current document. Fair-use: we never
// crawl pagination; we only fetch a card that is near-viewport AND uncached.
//
// Selectors (listing + detail dumps, 2026-08-31):
//   #view-cont > div.col-left             KEEP island
//   .lst-item__img / .lst-item__info      card slots extras compose into
//   [data-testid="listing-pic"]            hero (skip duplicate src)
//   .lst-item img.huge                    stock hover popup — hide
//   .group:has(.lst-item__label--sponsored)
//   .main-list-sponsors
//   aside.main-list__safety-tips
//   a.lst-item__link.mainlist-item
//   [data-testid="ad-item"]
//   #preview-description
//   .account-photos__item img
//
// Invented (constructed UI):
//   .nix-leolist-photos / -more / -desc
(() => {
  'use strict';

  if (document.documentElement.dataset.nixLeolistListingsOnlyInit !== undefined) return;
  document.documentElement.dataset.nixLeolistListingsOnlyInit = '';

  const KEEP = '#view-cont > div.col-left';
  const IMX = 'https://imx.leolist.cc/';
  const CONCURRENCY = 3;
  const MAX_EXTRAS = 6;
  const STORE_PREFIX = 'nix-leolist.v1:';
  const TTL_MS = 6 * 60 * 60 * 1000;
  const NEG_TTL_MS = 15 * 60 * 1000;
  const MAX_STORE = 400;

  const CSS = [
    'html[data-nix-leolist-listings-only] .group:has(.lst-item__label--sponsored)',
    'html[data-nix-leolist-listings-only] .main-list-sponsors',
    'html[data-nix-leolist-listings-only] aside.main-list__safety-tips',
    'html[data-nix-leolist-listings-only] .lst-item img.huge',
  ].join(',\n') + ' {\n  display: none;\n}\n' +
    'html[data-nix-leolist-listings-only] body.modal-open {\n  overflow: auto;\n}\n' +
    'html[data-nix-leolist-listings-only] [hidden] {\n  display: none;\n}\n' +
    'html[data-nix-leolist-listings-only] #view-cont > div.col-left {\n  float: none;\n  width: 100%;\n  padding-right: 0;\n}\n' +
    'html[data-nix-leolist-listings-only] .col-left .group {\n  float: none;\n  width: 100%;\n  margin: 0 0 10px;\n}\n' +
    'html[data-nix-leolist-listings-only] .lst-item.lst-item {\n  height: auto;\n  overflow: visible;\n}\n' +
    'html[data-nix-leolist-listings-only] .lst-item__img {\n  display: flex;\n  flex-direction: row;\n  align-items: stretch;\n  height: 160px;\n  width: auto;\n  max-width: 100%;\n  overflow: hidden;\n  gap: 2px;\n}\n' +
    'html[data-nix-leolist-listings-only] .lst-item__img__thumbnail--main {\n  height: 160px;\n  width: auto;\n  aspect-ratio: 3 / 4;\n  object-fit: cover;\n  object-position: top center;\n  flex: 0 0 auto;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-photos {\n  display: flex;\n  flex-wrap: nowrap;\n  gap: 2px;\n  height: 160px;\n  min-width: 0;\n  flex: 1 1 auto;\n  overflow-x: auto;\n  overflow-y: hidden;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-photos img {\n  height: 160px;\n  width: auto;\n  aspect-ratio: 3 / 4;\n  object-fit: cover;\n  object-position: top center;\n  flex: 0 0 auto;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-more {\n  flex: 0 0 auto;\n  height: 160px;\n  min-width: 48px;\n  display: flex;\n  align-items: center;\n  justify-content: center;\n  font-size: 14px;\n  font-weight: 650;\n}\n' +
    'html[data-nix-leolist-listings-only] .lst-item__info {\n  white-space: normal;\n  height: auto;\n  overflow: hidden;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-desc {\n  margin: 8px 0 0;\n  display: -webkit-box;\n  -webkit-box-orient: vertical;\n  -webkit-line-clamp: 3;\n  overflow: hidden;\n}\n';

  const sheet = new CSSStyleSheet();
  sheet.replaceSync(CSS);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];

  const unlockScroll = () => {
    const body = document.body;
    if (body && body.classList.contains('modal-open')) body.classList.remove('modal-open');
  };

  const applyIsland = () => {
    const keep = document.querySelector(KEEP);
    if (!keep) return false;
    let node = keep;
    while (node.parentElement && node !== document.body) {
      const parent = node.parentElement;
      for (let i = 0; i < parent.children.length; i += 1) {
        const sib = parent.children[i];
        if (sib !== node && !sib.hidden) sib.hidden = true;
      }
      node = parent;
    }
    return true;
  };

  let islandWatching = false;
  const watchIsland = () => {
    if (islandWatching) return;
    const keep = document.querySelector(KEEP);
    if (!keep) return;
    islandWatching = true;
    let queued = false;
    const coalesce = () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        applyIsland();
        unlockScroll();
      });
    };
    let node = keep;
    while (node.parentElement && node !== document.body) {
      new MutationObserver(coalesce).observe(node.parentElement, { childList: true });
      node = node.parentElement;
    }
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

  const storeKey = (href) => STORE_PREFIX + href;

  const pruneStore = (aggressive) => {
    const now = Date.now();
    const keys = [];
    for (let i = 0; i < localStorage.length; i += 1) {
      const k = localStorage.key(i);
      if (k && k.indexOf(STORE_PREFIX) === 0) keys.push(k);
    }
    const kept = [];
    for (const k of keys) {
      let row = null;
      try {
        row = JSON.parse(localStorage.getItem(k) || '');
      } catch {
        row = null;
      }
      const ttl = row && row.miss ? NEG_TTL_MS : TTL_MS;
      if (!row || typeof row.t !== 'number' || now - row.t > ttl) {
        localStorage.removeItem(k);
        continue;
      }
      kept.push({ k, t: row.t });
    }
    const limit = aggressive ? Math.floor(MAX_STORE / 2) : MAX_STORE;
    if (kept.length <= limit) return;
    kept.sort((a, b) => a.t - b.t);
    const drop = kept.length - limit;
    for (let i = 0; i < drop; i += 1) localStorage.removeItem(kept[i].k);
  };

  const readStore = (href) => {
    try {
      const raw = localStorage.getItem(storeKey(href));
      if (!raw) return null;
      const row = JSON.parse(raw);
      if (!row || typeof row.t !== 'number') return null;
      const ttl = row.miss ? NEG_TTL_MS : TTL_MS;
      if (Date.now() - row.t > ttl) {
        localStorage.removeItem(storeKey(href));
        return null;
      }
      if (row.miss) return { miss: true };
      if (typeof row.d !== 'string' || !Array.isArray(row.p)) return null;
      return { desc: row.d, photos: row.p };
    } catch {
      return null;
    }
  };

  const writeStore = (href, payload) => {
    try {
      pruneStore(false);
      localStorage.setItem(storeKey(href), JSON.stringify(payload));
    } catch {
      try {
        pruneStore(true);
        localStorage.setItem(storeKey(href), JSON.stringify(payload));
      } catch {
        /* quota — in-memory still works this document */
      }
    }
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
    if (cache.has(href)) {
      const mem = cache.get(href);
      return mem && mem.miss ? null : mem;
    }
    const stored = readStore(href);
    if (stored && stored.miss) {
      cache.set(href, stored);
      return null;
    }
    if (stored) {
      cache.set(href, stored);
      return stored;
    }
    const res = await fetch(href, { credentials: 'same-origin', cache: 'default' });
    if (!res.ok) {
      const miss = { miss: true };
      cache.set(href, miss);
      writeStore(href, { t: Date.now(), miss: true });
      return null;
    }
    const parsed = parseDetail(await res.text());
    cache.set(href, parsed);
    writeStore(href, { t: Date.now(), d: parsed.desc, p: parsed.photos });
    return parsed;
  };

  const renderExtra = (card, data) => {
    if (card.querySelector('.nix-leolist-photos') || card.querySelector('.nix-leolist-desc')) return;
    const imgBox = card.querySelector('.lst-item__img');
    const info = card.querySelector('.lst-item__info');
    const hero = card.querySelector('[data-testid="listing-pic"]');
    const heroSrc = hero ? hero.getAttribute('src') : '';

    const extras = [];
    for (const src of data.photos) {
      if (src === heroSrc) continue;
      extras.push(src);
    }

    if (imgBox && extras.length) {
      const row = document.createElement('div');
      row.className = 'nix-leolist-photos';
      const shown = extras.slice(0, MAX_EXTRAS);
      for (const src of shown) {
        const img = document.createElement('img');
        img.src = src;
        img.alt = '';
        img.loading = 'lazy';
        row.appendChild(img);
      }
      if (extras.length > MAX_EXTRAS) {
        const more = document.createElement('span');
        more.className = 'nix-leolist-more';
        more.textContent = '+' + String(extras.length - MAX_EXTRAS);
        row.appendChild(more);
      }
      imgBox.appendChild(row);
    }

    if (info && data.desc) {
      const p = document.createElement('p');
      p.className = 'nix-leolist-desc';
      p.textContent = data.desc;
      info.appendChild(p);
    }
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
      renderExtra(card, data);
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

  const reconnectIo = () => {
    if (document.hidden || !io) return;
    const list = document.getElementById('main_list');
    if (!list) return;
    io.disconnect();
    for (const card of list.querySelectorAll('[data-testid="ad-item"]')) {
      if (card.dataset.nixLeolistEnrich !== undefined) continue;
      io.observe(card);
    }
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
    document.addEventListener('visibilitychange', reconnectIo);
    scan();
  };

  const arm = () => {
    if (!applyIsland()) return false;
    if (document.documentElement.dataset.nixLeolistListingsOnly === undefined) {
      document.documentElement.dataset.nixLeolistListingsOnly = '';
    }
    unlockScroll();
    watchIsland();
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
