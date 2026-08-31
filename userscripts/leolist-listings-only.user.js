// ==UserScript==
// @name         LeoList — listings only
// @namespace    kattakath.com
// @version      1.23.0
// @description  Listings-only LeoList: keep #view-cont > div.col-left, drop sponsored chrome, filmstrip extra photos beside the hero from the lightbox a.href (w:1024), clamp the ad description. Parsed extras persist in localStorage with no hit TTL.
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
// fetch; #preview-description textContent; .account-photos__item a[href]
// (w:1024/h:0 lightbox, not the 304 img.src thumb). Phone stays locked.
// IntersectionObserver + concurrency 3;
// visibilitychange reconnects IO so a hidden tab fills on focus.
// v1.4.0: parsed {desc, photos} live in localStorage (key nix-leolist.v1:<href>,
// TTL 6h, cap 400, 15min negative cache). Refresh/revisit hits the store, not
// the origin. In-memory Map is L1 for the current document. Fair-use: we never
// crawl pagination; we only fetch a card that is near-viewport AND uncached.
// v1.5.0: #view-cont full width. The 960px well is the parent
// .main-list-container.container (measured 2026-08-31, col-left x=276 w=960
// on a 1512px viewport); widening #view-cont alone is a no-op.
// v1.6.0: store a.href not img.src. Signed imgproxy paths cannot be
// rewritten from 304→1024. Cache prefix bumped to v2 so stale 304 URLs
// are not reused (one HTML refetch of near-viewport misses).
// v1.7.0: successful rows do not expire. imx filenames are content-hashed
// UUIDs; a URL is that blob forever. Ads can still swap in new hashes —
// we only refetch HTML when the listing is unknown or LRU-evicted (cap).
// v1.8.0: drop 160px height locks (auto). .lst-item is 256px.
// v1.9.0: every .lst-item img is width/height auto (site CSS still pins some).
// v1.10.0: height 256px lives on img, not .lst-item. width auto. Card is
// height auto so title/desc still fit. Drop 3/4 crop so w:1024/h:0 aspect holds.
// v1.11.0: stack 304 img.src under 1024 a.href in one 256px slot (LQIP).
// Store {lo,hi}; prefix v3. 304 paints first; 1024 fades on load. Same box
// (object-fit cover) so the square thumb sets width — no blank rail.
// v1.12.0: constructed dark surface. Dump body was class "light"; no .dark
// rules in the sheets we fetched, so we don't replay a site theme.
// v1.13.0: Catppuccin Mocha palette (crust/base/text/subtext0/surface0/blue).
// Hex only — no @require. Photos unchanged.
// v1.14.0: match Catppuccin style-guide + sample.png — page=base, cards=surface0,
// labels=subtext1, links=blue. Headline is a link so blue, not text.
// v1.15.0: enrich only #main_list > div listing rows (Chrome JS path
// #main_list > div:nth-child(N)). Skip section/aside/sponsors/pagination.
// v1.16.0: fair use — one listing at a time (HTML), then that row's 304
// thumbs one by one, then 1024s one by one. Rows already come from page 1.
// v1.17.0: never lose the page-1 rows. HTML fetches wait 2.5s apart. 403/429/503
// pauses origin HTML for this tab (1h). Cache hits still paint extras.
// v1.18.0: slower on purpose — 10s between ad HTML, 1s between images.
// v1.19.0: rows are ours (.nix-leolist-row). Stock .lst-item is hidden.
// Page-1 title/hero paint immediately; extras still serial.
// v1.20.0: Open button on the extreme right of the photo rail.
// v1.21.0: hide #main_list > section (and any non-div sibling). Enrich
// already skipped them; they still painted.
// v1.22.0: drop 304 overlay. Thumb is a square crop; original is not.
// Extras are a.href only (w:1024/h:0), one by one. Store prefix v4.
// v1.23.0: Cache API stores image bytes (www.leolist.cc → imx URLs). localStorage
// only has URL strings — that is why Application>Cache Storage was empty and
// Cmd-R still hit the CDN. Hits skip the 1s gap. DevTools "Disable cache"
// still bypasses HTTP cache; Cache API does not.
//
// Selectors (listing + detail dumps, 2026-08-31):
//   #view-cont > div.col-left             KEEP island
//   .lst-item__img / .lst-item__info      card slots extras compose into
//   [data-testid="listing-pic"]            hero (skip duplicate via s3 payload)
//   .lst-item img.huge                    stock hover popup — hide
//   .group:has(.lst-item__label--sponsored)
//   .main-list-sponsors
//   aside.main-list__safety-tips
//   a.lst-item__link.mainlist-item
//   [data-testid="ad-item"]
//   #preview-description
//   .account-photos__item a[href]         lightbox URL (w:1024/h:0)
//
// Invented (constructed UI):
//   .nix-leolist-row / -rail / -photos / -go / -title / -desc
(() => {
  'use strict';

  if (document.documentElement.dataset.nixLeolistListingsOnlyInit !== undefined) return;
  document.documentElement.dataset.nixLeolistListingsOnlyInit = '';

  const KEEP = '#view-cont > div.col-left';
  const IMX = 'https://imx.leolist.cc/';
  const CONCURRENCY = 1;
  const MAX_EXTRAS = 6;
  const STORE_PREFIX = 'nix-leolist.v4:';
  const STORE_LEGACY = ['nix-leolist.v1:', 'nix-leolist.v2:', 'nix-leolist.v3:'];
  const NEG_TTL_MS = 15 * 60 * 1000;
  const MAX_STORE = 400;
  const HTML_GAP_MS = 10000;
  const IMG_GAP_MS = 1000;
  const ORIGIN_PAUSE_MS = 60 * 60 * 1000;
  const PAUSE_KEY = 'nix-leolist.originPauseUntil';
  const IMG_CACHE = 'nix-leolist-img-v4';

  const CSS = [
    'html[data-nix-leolist-listings-only] .group:has(.lst-item__label--sponsored)',
    'html[data-nix-leolist-listings-only] .main-list-sponsors',
    'html[data-nix-leolist-listings-only] aside.main-list__safety-tips',
    'html[data-nix-leolist-listings-only] #main_list > section',
    'html[data-nix-leolist-listings-only] #main_list > :not(div)',
    'html[data-nix-leolist-listings-only] .lst-item img.huge',
  ].join(',\n') + ' {\n  display: none;\n}\n' +
    'html[data-nix-leolist-listings-only] body.modal-open {\n  overflow: auto;\n}\n' +
    'html[data-nix-leolist-listings-only] [hidden] {\n  display: none;\n}\n' +
    'html[data-nix-leolist-listings-only] .wrap,\nhtml[data-nix-leolist-listings-only] .main-list,\nhtml[data-nix-leolist-listings-only] .main-list-container.container,\nhtml[data-nix-leolist-listings-only] #view-cont {\n  width: 100%;\n  max-width: none;\n  margin-left: 0;\n  margin-right: 0;\n  box-sizing: border-box;\n  padding-left: 0;\n  padding-right: 0;\n}\n' +
    'html[data-nix-leolist-listings-only] #view-cont > div.col-left {\n  float: none;\n  width: 100%;\n  padding-right: 0;\n}\n' +
    'html[data-nix-leolist-listings-only] .col-left .group {\n  float: none;\n  width: 100%;\n  margin: 0 0 12px;\n}\n' +
    'html[data-nix-leolist-listings-only] #main_list > div > .lst-item {\n  display: none;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-row {\n  display: flex;\n  flex-direction: column;\n  gap: 8px;\n  padding: 12px;\n  background: #313244;\n  color: #cdd6f4;\n  border: 1px solid #45475a;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-rail {\n  display: flex;\n  flex-direction: row;\n  align-items: stretch;\n  gap: 8px;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-photos {\n  display: flex;\n  flex-wrap: nowrap;\n  gap: 2px;\n  overflow-x: auto;\n  overflow-y: hidden;\n  flex: 1 1 auto;\n  min-width: 0;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-go {\n  flex: 0 0 56px;\n  margin-left: auto;\n  display: flex;\n  align-items: center;\n  justify-content: center;\n  min-height: 256px;\n  background: #89b4fa;\n  color: #1e1e2e;\n  text-decoration: none;\n  font-weight: 700;\n  letter-spacing: 0.02em;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-go:hover {\n  background: #89dceb;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-row img {\n  width: auto;\n  height: 256px;\n  object-fit: contain;\n  object-position: top center;\n  flex: 0 0 auto;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-more {\n  flex: 0 0 auto;\n  height: 256px;\n  min-width: 48px;\n  display: flex;\n  align-items: center;\n  justify-content: center;\n  font-size: 14px;\n  font-weight: 650;\n  color: #a6adc8;\n  background: #45475a;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-title {\n  color: #89b4fa;\n  font-size: 1.1em;\n  font-weight: 650;\n  text-decoration: none;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-title:hover {\n  color: #89dceb;\n}\n' +
    'html[data-nix-leolist-listings-only] .nix-leolist-desc {\n  margin: 0;\n  color: #bac2de;\n  display: -webkit-box;\n  -webkit-box-orient: vertical;\n  -webkit-line-clamp: 3;\n  overflow: hidden;\n}\n' +
    'html[data-nix-leolist-listings-only] {\n  color-scheme: dark;\n}\n' +
    'html[data-nix-leolist-listings-only] body,\nhtml[data-nix-leolist-listings-only] .wrap,\nhtml[data-nix-leolist-listings-only] .main-list,\nhtml[data-nix-leolist-listings-only] .main-list-container,\nhtml[data-nix-leolist-listings-only] #view-cont,\nhtml[data-nix-leolist-listings-only] .col-left,\nhtml[data-nix-leolist-listings-only] #main_list {\n  background: #1e1e2e;\n  color: #cdd6f4;\n}\n';

  const sheet = new CSSStyleSheet();
  sheet.replaceSync(CSS);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];

  const unlockScroll = () => {
    const body = document.body;
    if (body && body.classList.contains('modal-open')) body.classList.remove('modal-open');
  };

  const paintDark = () => {
    const body = document.body;
    if (!body) return;
    body.classList.remove('light');
    body.classList.add('dark');
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
        paintDark();
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
    const legacy = [];
    for (let i = 0; i < localStorage.length; i += 1) {
      const k = localStorage.key(i);
      if (!k) continue;
      let isLegacy = false;
      for (let j = 0; j < STORE_LEGACY.length; j += 1) {
        if (k.indexOf(STORE_LEGACY[j]) === 0) {
          isLegacy = true;
          break;
        }
      }
      if (isLegacy) legacy.push(k);
      else if (k.indexOf(STORE_PREFIX) === 0) keys.push(k);
    }
    for (const k of legacy) localStorage.removeItem(k);
    const kept = [];
    for (const k of keys) {
      let row = null;
      try {
        row = JSON.parse(localStorage.getItem(k) || '');
      } catch {
        row = null;
      }
      if (!row || typeof row.t !== 'number') {
        localStorage.removeItem(k);
        continue;
      }
      if (row.miss && now - row.t > NEG_TTL_MS) {
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
      if (row.miss) {
        if (Date.now() - row.t > NEG_TTL_MS) {
          localStorage.removeItem(storeKey(href));
          return null;
        }
        return { miss: true };
      }
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

  const imxPayload = (url) => {
    const i = url.indexOf('/czM6Ly9');
    if (i === -1) return url;
    return url.slice(i + 1).split('.')[0];
  };

  const parseDetail = (html) => {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const descEl = doc.getElementById('preview-description');
    const desc = descEl ? descEl.textContent.replace(/\s+/g, ' ').trim() : '';
    const photos = [];
    const seen = new Set();
    for (const a of doc.querySelectorAll('.account-photos__item a[href]')) {
      const hi = a.getAttribute('href') || '';
      if (hi.indexOf(IMX) !== 0) continue;
      const key = imxPayload(hi);
      if (seen.has(key)) continue;
      seen.add(key);
      photos.push(hi);
    }
    return { desc, photos };
  };

  const originPaused = () => {
    try {
      const until = parseInt(sessionStorage.getItem(PAUSE_KEY) || '0', 10);
      return until > Date.now();
    } catch {
      return false;
    }
  };

  const pauseOrigin = () => {
    try {
      sessionStorage.setItem(PAUSE_KEY, String(Date.now() + ORIGIN_PAUSE_MS));
    } catch {
      /* sessionStorage blocked */
    }
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
    if (originPaused()) return null;
    let res;
    try {
      res = await fetch(href, { credentials: 'same-origin', cache: 'default' });
    } catch {
      return null;
    }
    if (res.status === 403 || res.status === 429 || res.status === 503) {
      pauseOrigin();
      return null;
    }
    if (!res.ok) {
      const miss = { miss: true };
      cache.set(href, miss);
      writeStore(href, { t: Date.now(), miss: true });
      return null;
    }
    const parsed = parseDetail(await res.text());
    cache.set(href, parsed);
    writeStore(href, { t: Date.now(), d: parsed.desc, p: parsed.photos });
    await wait(HTML_GAP_MS);
    return parsed;
  };

  const wait = (ms) =>
    new Promise((resolve) => {
      setTimeout(resolve, ms);
    });

  let imgCacheP = null;
  const imgCache = () => {
    if (!imgCacheP) imgCacheP = caches.open(IMG_CACHE);
    return imgCacheP;
  };

  const paintImg = (img, src) =>
    new Promise((resolve) => {
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        resolve();
      };
      img.addEventListener('load', done, { once: true });
      img.addEventListener('error', done, { once: true });
      img.src = src;
      if (img.complete) done();
    });

  const loadOne = async (img, url) => {
    if (!img || !url) return;
    const cache = await imgCache();
    const hit = await cache.match(url);
    if (hit && hit.type !== 'opaque') {
      try {
        const blob = await hit.blob();
        if (blob && blob.size) {
          const obj = URL.createObjectURL(blob);
          await paintImg(img, obj);
          URL.revokeObjectURL(obj);
          return;
        }
      } catch {
        /* fall through */
      }
    }
    let stored = false;
    try {
      const res = await fetch(url, { mode: 'cors', credentials: 'omit', cache: 'force-cache' });
      if (res.ok) {
        const blob = await res.blob();
        await cache.put(
          url,
          new Response(blob, { headers: { 'Content-Type': blob.type || 'image/webp' } }),
        );
        stored = true;
        const obj = URL.createObjectURL(blob);
        await paintImg(img, obj);
        URL.revokeObjectURL(obj);
        await wait(IMG_GAP_MS);
        return;
      }
    } catch {
      /* imx likely no CORS */
    }
    await paintImg(img, url);
    if (!stored) {
      try {
        const opaque = await fetch(url, { mode: 'no-cors', credentials: 'omit', cache: 'force-cache' });
        await cache.put(url, opaque);
      } catch {
        /* ignore */
      }
    }
    await wait(IMG_GAP_MS);
  };

  const ensureRow = (wrap) => {
    const existing = wrap.querySelector(':scope > .nix-leolist-row');
    if (existing) return existing;
    const stock = wrap.querySelector('.lst-item');
    const link = wrap.querySelector('a.lst-item__link.mainlist-item');
    const href = link ? link.getAttribute('href') || '' : '';
    const titleEl = wrap.querySelector('.lst-item__title');
    const title = titleEl ? titleEl.textContent.replace(/\s+/g, ' ').trim() : '';
    const hero = wrap.querySelector('[data-testid="listing-pic"]');
    const heroSrc = hero ? hero.getAttribute('src') || '' : '';
    const row = document.createElement('article');
    row.className = 'nix-leolist-row';
    const rail = document.createElement('div');
    rail.className = 'nix-leolist-rail';
    const photos = document.createElement('div');
    photos.className = 'nix-leolist-photos';
    if (heroSrc) {
      const heroImg = document.createElement('img');
      heroImg.className = 'nix-leolist-hero';
      heroImg.alt = '';
      heroImg.src = heroSrc;
      photos.appendChild(heroImg);
    }
    const go = document.createElement('a');
    go.className = 'nix-leolist-go';
    go.href = href;
    go.textContent = 'Open';
    rail.appendChild(photos);
    rail.appendChild(go);
    const heading = document.createElement('a');
    heading.className = 'nix-leolist-title';
    heading.href = href;
    heading.textContent = title;
    const desc = document.createElement('p');
    desc.className = 'nix-leolist-desc';
    row.appendChild(rail);
    row.appendChild(heading);
    row.appendChild(desc);
    wrap.appendChild(row);
    const kids = wrap.children;
    for (let i = 0; i < kids.length; i += 1) {
      if (kids[i] !== row) kids[i].hidden = true;
    }
    return row;
  };

  const renderExtra = async (wrap, data) => {
    const row = ensureRow(wrap);
    const photos = row.querySelector('.nix-leolist-photos');
    const descEl = row.querySelector('.nix-leolist-desc');
    const hero = row.querySelector('.nix-leolist-hero');
    const heroSrc = hero ? hero.getAttribute('src') : '';
    const heroKey = heroSrc ? imxPayload(heroSrc) : '';
    if (descEl && data.desc && !descEl.textContent) descEl.textContent = data.desc;
    if (!photos || photos.querySelector('.nix-leolist-extra')) return;

    const extras = [];
    for (const src of data.photos) {
      const hi = typeof src === 'string' ? src : src.hi;
      if (!hi) continue;
      if (heroKey && imxPayload(hi) === heroKey) continue;
      extras.push(hi);
    }
    const shown = extras.slice(0, MAX_EXTRAS);
    const pending = [];
    for (const url of shown) {
      const img = document.createElement('img');
      img.className = 'nix-leolist-extra';
      img.alt = '';
      photos.appendChild(img);
      pending.push({ el: img, url });
    }
    if (extras.length > MAX_EXTRAS) {
      const more = document.createElement('span');
      more.className = 'nix-leolist-more';
      more.textContent = '+' + String(extras.length - MAX_EXTRAS);
      photos.appendChild(more);
    }
    for (let i = 0; i < pending.length; i += 1) await loadOne(pending[i].el, pending[i].url);
  };

  const enrichCard = async (wrap) => {
    if (wrap.dataset.nixLeolistEnrich !== undefined) return;
    const link = wrap.querySelector('a.lst-item__link.mainlist-item');
    const href = link ? link.getAttribute('href') : '';
    if (!href || href.indexOf('/personals/') === -1) return;
    ensureRow(wrap);
    wrap.dataset.nixLeolistEnrich = 'pending';
    try {
      const data = await loadDetail(href);
      if (!data) {
        wrap.dataset.nixLeolistEnrich = 'fail';
        return;
      }
      await renderExtra(wrap, data);
      wrap.dataset.nixLeolistEnrich = 'done';
    } catch {
      wrap.dataset.nixLeolistEnrich = 'fail';
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

  const listingCard = (wrap) => {
    if (!wrap || wrap.tagName !== 'DIV') return null;
    const cls = ' ' + (wrap.className || '') + ' ';
    if (cls.indexOf(' main-list-sponsors ') !== -1) return null;
    if (cls.indexOf(' main-list-pagination ') !== -1) return null;
    const card = wrap.classList.contains('lst-item')
      ? wrap
      : wrap.querySelector('.lst-item');
    if (!card) return null;
    if (card.querySelector('.lst-item__label--sponsored')) return null;
    if (!card.querySelector('a.lst-item__link.mainlist-item')) return null;
    return wrap;
  };

  const eachListing = (fn) => {
    const list = document.getElementById('main_list');
    if (!list) return;
    const kids = list.querySelectorAll(':scope > div');
    for (let i = 0; i < kids.length; i += 1) {
      const wrap = listingCard(kids[i]);
      if (wrap) fn(wrap);
    }
  };

  const scan = () => {
    eachListing((wrap) => {
      ensureRow(wrap);
      observeCard(wrap);
    });
  };

  const reconnectIo = () => {
    if (document.hidden || !io) return;
    io.disconnect();
    eachListing((card) => {
      if (card.dataset.nixLeolistEnrich !== undefined) return;
      io.observe(card);
    });
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
    paintDark();
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
