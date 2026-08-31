# `leolist-crawlee` — same catalog as the listings-only userscript, via Crawlee
# (BeautifulSoup HTTP crawler). Ephemeral `uv` env, same model as jobspy.nix.
#
# Serial, slow, robots.txt on. Does NOT download images (URLs only, matching
# userscript v4 `p[]`). Same public IP as Chromium — do not run while the
# userscript is fetching, and do not raise concurrency.
#
#   leolist-crawlee https://www.leolist.cc/personals/female-escorts/greater-toronto/york
#   leolist-crawlee --max-details 20 --delay 10 URL
#   leolist-crawlee --import-ls            # dataset.json → leolist.cc localStorage
#   leolist-crawlee --import-ls --force    # overwrite existing v4 hits
#
# Dataset: $XDG_DATA_HOME/leolist-crawlee/ (default ~/.local/share/leolist-crawlee/)
# Import writes nix-leolist.v4:<pathname> {t,d,p} so the tab skips those ad HTML
# fetches. Prefers a connected Kapture tab (localhost:61822); else prints a
# paste-into-DevTools JS file next to the dataset.
{
  writeShellApplication,
  writeText,
  uv,
  coreutils,
}:
let
  runner = writeText "leolist_crawlee_run.py" ''
    import argparse
    import asyncio
    import json
    import os
    import sys
    import urllib.error
    import urllib.request
    from pathlib import Path
    from urllib.parse import urljoin, urlparse

    IMX = "https://imx.leolist.cc/"
    DEFAULT_DELAY = 10
    STORE_PREFIX = "nix-leolist.v4:"
    KAPTURE_BASE = "http://127.0.0.1:61822"


    def data_dir() -> Path:
        xdg = os.environ.get("XDG_DATA_HOME")
        root = Path(xdg) if xdg else Path.home() / ".local/share"
        d = root / "leolist-crawlee"
        d.mkdir(parents=True, exist_ok=True)
        return d


    def catalog_items(rows: list) -> list[dict]:
        items = []
        seen = set()
        for row in rows:
            if not isinstance(row, dict):
                continue
            url = row.get("url") or ""
            path = urlparse(url).path
            if not path.startswith("/personals/") or path in seen:
                continue
            photos = row.get("photos") or []
            if not isinstance(photos, list):
                photos = []
            clean = []
            pseen = set()
            for href in photos:
                if not isinstance(href, str) or not href.startswith(IMX):
                    continue
                if href in pseen:
                    continue
                pseen.add(href)
                clean.append(href)
            seen.add(path)
            items.append({"href": path, "d": row.get("desc") or "", "p": clean})
        return items


    def emit_js(items: list[dict], force: bool) -> str:
        payload = json.dumps(items, separators=(",", ":"), ensure_ascii=False)
        force_js = "true" if force else "false"
        return (
            "(function(){"
            "var PREFIX='" + STORE_PREFIX + "';"
            "var force=" + force_js + ";"
            "var now=Date.now();"
            "var items=" + payload + ";"
            "var wrote=0,skip=0,replaced=0;"
            "for(var i=0;i<items.length;i++){"
            "var it=items[i];"
            "var key=PREFIX+it.href;"
            "var raw=localStorage.getItem(key);"
            "var hit=false;"
            "if(raw){"
            "var row=null;try{row=JSON.parse(raw);}catch(e){row=null;}"
            "hit=row && typeof row.t==='number' && !row.miss && typeof row.d==='string' && Array.isArray(row.p);"
            "}"
            "if(hit && !force){skip++;continue;}"
            "localStorage.setItem(key,JSON.stringify({t:now,d:it.d,p:it.p}));"
            "if(hit) replaced++; else wrote++;"
            "}"
            "return {wrote:wrote,skip:skip,replaced:replaced,origin:location.origin,keys:items.length};"
            "})()"
        )


    def kapture_tabs():
        try:
            with urllib.request.urlopen(KAPTURE_BASE + "/tabs", timeout=2) as resp:
                return json.loads(resp.read().decode())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
            return None


    def kapture_evaluate(tab_id: str, code: str):
        req = urllib.request.Request(
            KAPTURE_BASE + "/tab/" + tab_id + "/evaluate",
            data=json.dumps({"code": code, "timeout": 30000}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=40) as resp:
            return json.loads(resp.read().decode())


    def import_ls(dataset: Path, force: bool) -> int:
        if not dataset.is_file():
            print("leolist-crawlee: no dataset at " + str(dataset), file=sys.stderr)
            return 2
        with dataset.open(encoding="utf-8") as fh:
            rows = json.load(fh)
        if not isinstance(rows, list):
            print("leolist-crawlee: dataset is not a JSON list", file=sys.stderr)
            return 2
        items = catalog_items(rows)
        if not items:
            print("leolist-crawlee: dataset has no /personals/ rows", file=sys.stderr)
            return 2
        js = emit_js(items, force)
        js_path = dataset.with_name("import-ls.js")
        js_path.write_text(js, encoding="utf-8")
        print(
            "leolist-crawlee: " + str(len(items)) + " ads -> " + str(js_path),
            file=sys.stderr,
        )

        tabs = kapture_tabs()
        if tabs is None:
            print("leolist-crawlee: kapture not on " + KAPTURE_BASE, file=sys.stderr)
        else:
            leolist = [
                t
                for t in tabs
                if isinstance(t, dict) and "leolist.cc" in (t.get("url") or "")
            ]
            if not leolist:
                print("leolist-crawlee: kapture up, no leolist.cc tab", file=sys.stderr)
            elif not leolist[0].get("evalAllowed"):
                print(
                    "leolist-crawlee: kapture tab evalAllowed=false — enable Allow JS execution",
                    file=sys.stderr,
                )
            else:
                tab = leolist[0]
                try:
                    resp = kapture_evaluate(str(tab.get("tabId")), js)
                except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as err:
                    print("leolist-crawlee: kapture evaluate failed: " + str(err), file=sys.stderr)
                    resp = None
                if resp and resp.get("success"):
                    print(
                        "leolist-crawlee: imported " + json.dumps(resp.get("value")),
                        file=sys.stderr,
                    )
                    return 0
                if resp is not None:
                    print("leolist-crawlee: kapture evaluate: " + json.dumps(resp), file=sys.stderr)

        print(
            "leolist-crawlee: paste " + str(js_path) + " in the leolist.cc DevTools console",
            file=sys.stderr,
        )
        return 0


    def listing_hrefs(soup, base: str) -> list[str]:
        out = []
        seen = set()
        for div in soup.select("#main_list > div"):
            classes = " " + " ".join(div.get("class") or []) + " "
            if " main-list-sponsors " in classes or " main-list-pagination " in classes:
                continue
            if div.select_one(".lst-item__label--sponsored"):
                continue
            a = div.select_one("a.lst-item__link.mainlist-item")
            if a is None:
                continue
            href = a.get("href") or ""
            if not href:
                continue
            absu = urljoin(base, href)
            if absu in seen:
                continue
            seen.add(absu)
            out.append(absu)
        return out


    def detail_photos(soup) -> list[str]:
        out = []
        seen = set()
        for a in soup.select(".account-photos__item a[href]"):
            href = a.get("href") or ""
            if not href.startswith(IMX):
                continue
            if href in seen:
                continue
            seen.add(href)
            out.append(href)
        return out


    def main() -> int:
        p = argparse.ArgumentParser(
            prog="leolist-crawlee",
            description="Slow Crawlee catalog of LeoList listings (description + 1024 photo URLs). Same IP as the browser — keep it serial.",
        )
        p.add_argument("url", nargs="?", default=None, help="listing index URL (e.g. .../personals/female-escorts/greater-toronto/york)")
        p.add_argument("--max-details", type=int, default=20, help="max ad pages to enqueue (default 20)")
        p.add_argument("--delay", type=float, default=DEFAULT_DELAY, help="seconds between HTTP requests (default 10)")
        p.add_argument("-o", "--output", default=None, help="write JSON to this path (default: dataset under XDG)")
        p.add_argument("--import-ls", action="store_true", help="write dataset.json into leolist.cc localStorage (nix-leolist.v4:) and stop; does not crawl")
        p.add_argument("--force", action="store_true", help="with --import-ls, overwrite existing v4 hits (default: skip hits, replace misses)")
        args = p.parse_args()

        dest = data_dir()
        if args.import_ls:
            dataset = Path(args.output) if args.output else (dest / "dataset.json")
            return import_ls(dataset, args.force)

        if not args.url:
            p.error("url is required unless --import-ls")

        if args.max_details < 0:
            print("leolist-crawlee: --max-details must be >= 0", file=sys.stderr)
            return 2

        from crawlee import ConcurrencySettings, Request
        from crawlee.configuration import Configuration
        from crawlee.crawlers import BeautifulSoupCrawler, BeautifulSoupCrawlingContext

        os.environ["CRAWLEE_STORAGE_DIR"] = str(dest)
        print(
            "leolist-crawlee: storage " + str(dest) + " delay=" + str(args.delay) + "s max-details=" + str(args.max_details),
            file=sys.stderr,
        )
        print(
            "leolist-crawlee: same public IP as Chromium — do not run while the userscript is fetching",
            file=sys.stderr,
        )

        configuration = Configuration(storage_dir=str(dest))
        crawler = BeautifulSoupCrawler(
            parser="html.parser",
            configuration=configuration,
            concurrency_settings=ConcurrencySettings(
                min_concurrency=1,
                max_concurrency=1,
                desired_concurrency=1,
            ),
            max_request_retries=0,
            retry_on_blocked=False,
            respect_robots_txt_file=True,
            max_requests_per_crawl=args.max_details + 2,
        )

        @crawler.router.default_handler
        async def handler(context: BeautifulSoupCrawlingContext) -> None:
            soup = context.soup
            url = context.request.url
            status = getattr(context, "http_response", None)
            code = getattr(status, "status_code", None) if status is not None else None
            if code in (403, 429, 503):
                context.log.error("blocked HTTP " + str(code) + " — stopping")
                crawler.stop(reason="blocked")
                return

            if soup.select_one("#preview-description") is not None:
                desc_el = soup.select_one("#preview-description")
                desc = " ".join(desc_el.get_text(" ", strip=True).split()) if desc_el else ""
                photos = detail_photos(soup)
                await context.push_data({"url": url, "desc": desc, "photos": photos})
                context.log.info("detail " + url + " photos=" + str(len(photos)))
            elif soup.select_one("#main_list") is not None:
                hrefs = listing_hrefs(soup, url)[: args.max_details]
                context.log.info("list " + url + " enqueue=" + str(len(hrefs)))
                reqs = [Request.from_url(h, user_data={"kind": "detail"}) for h in hrefs]
                if reqs:
                    await crawler.add_requests(reqs)
            else:
                context.log.warning("unrecognized page " + url)

            await asyncio.sleep(args.delay)

        @crawler.failed_request_handler
        async def failed(context: BeautifulSoupCrawlingContext, error: Exception) -> None:
            msg = str(error)
            context.log.error("failed " + context.request.url + " " + msg)
            if "403" in msg or "429" in msg or "503" in msg:
                crawler.stop(reason="blocked")

        asyncio.run(crawler.run([args.url]))

        out = args.output
        if out is None:
            out = str(dest / "dataset.json")
        asyncio.run(crawler.export_data(out))
        print("leolist-crawlee: wrote " + out, file=sys.stderr)
        return 0


    if __name__ == "__main__":
        sys.exit(main())
  '';
in
writeShellApplication {
  name = "leolist-crawlee";
  runtimeInputs = [
    uv
    coreutils
  ];
  text = ''
    import_ls=0
    for arg in "$@"; do
      if [ "$arg" = "--import-ls" ]; then
        import_ls=1
      fi
    done
    if [ "$import_ls" -eq 1 ]; then
      exec uv run --quiet --python 3.12 python ${runner} "$@"
    fi
    exec uv run --quiet --python 3.12 --with 'crawlee[beautifulsoup]' python ${runner} "$@"
  '';
}
