// ==UserScript==
// @name         LeoList — listings only
// @namespace    kattakath.com
// @version      1.2.0
// @description  Keep only LeoList's listing column (#view-cont > div.col-left); hide every sibling up to body, drop sponsored cards, and append each ad's description plus extra photos.
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
// inside #view-cont > div.col-left (operator-named keep; dump confirms
// #view-cont's only children are div.col-left and div.col-right). Chrome
// is siblings of that island, not a breakpoint. v1.0–1.1 hid a named
// list and leaked whatever the list missed (header, filters, wrap extras).
// v1.2 walks keep → body and sets hidden on every sibling; missing keep
// is a no-op (the page renders stock). Inside the island, sponsored cards
// and the SPONSORS strip are still not listings.
//
// Enrichment (v1.1.0), same date, dump on
// /personals/female-escorts/greater-toronto/york_outcall_party_girl_100_duo-8313854:
// a.lst-item__link.mainlist-item[href] is the ad page; extra fields are
// #preview-description and .account-photos__item img on imx.leolist.cc.
// Phone/WhatsApp sit behind .unlock-contacts-btn / empty #preview-phone.
// Fetch is same-origin, @grant none, concurrency 3, IntersectionObserver.
// A failed fetch leaves the card stock.
//
// Selectors:
//   #view-cont > div.col-left             KEEP island (listing dump + operator)
//   .group:has(.lst-item__label--sponsored)
//                                         sponsored cards inside the island
//   .main-list-sponsors                   SPONSORS tab strip inside #main_list
//   aside.main-list__safety-tips          safety-tips block mid-list
//   a.lst-item__link.mainlist-item        card permalink
//   [data-testid="ad-item"]               organic card
//   #preview-description                  ad body (detail dump)
//   .account-photos__item img             extra thumbs (detail dump)
//
// Invented (constructed UI, 2026-08-31):
//   .nix-leolist-extra / -photos / -desc
//   #view-cont > div.col-left { width:100%; float:none } after col-right is gone
(() => {
  'use strict';

  if (document.documentElement.dataset.nixLeolistListingsOnlyInit !== undefined) return;
  document.documentElement.dataset.nixLeolistListingsOnlyInit = '';

  const KEEP = '#view-cont > div.col-left';
  const IMX = 'https://imx.leolist.cc/';
  const CONCURRENCY = 3;

  const CSS = [
    'html[data-nix-leolist-listings-only] .group:has(.lst-item__label--sponsored)',
    'html[data-nix-leolist-listings-only] .main-list-sponsors',
    'html[data-nix-leolist-listings-only] aside.main-list__safety-tips',
  ].join(',\n') + ' {\n  display: none;\n}\n' +
    'html[data-nix-leolist-listings-only] body.modal-open {\n  overflow: auto;\n}\n' +
    'html[data-nix-leolist-listings-only] [hidden] {\n  display: none;\n}\n' +
    'html[data-nix-leolist-listings-only] #view-cont > div.col-left {\n  float: none;\n  width: 100%;\n}\n' +
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
