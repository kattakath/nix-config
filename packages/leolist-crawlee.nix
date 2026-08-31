# `leolist-crawlee` — same catalog as the listings-only userscript, via Crawlee
# (BeautifulSoup HTTP crawler). Ephemeral `uv` env, same model as jobspy.nix.
#
# Serial, slow, robots.txt on. Does NOT download images (URLs only, matching
# userscript v4 `p[]`). Same public IP as Chromium — do not run while the
# userscript is fetching, and do not raise concurrency.
#
#   leolist-crawlee https://www.leolist.cc/personals/female-escorts/greater-toronto/york
#   leolist-crawlee --max-details 20 --delay 10 URL
#
# Dataset: $XDG_DATA_HOME/leolist-crawlee/ (default ~/.local/share/leolist-crawlee/)
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
    import os
    import sys
    from datetime import timedelta
    from pathlib import Path
    from urllib.parse import urljoin

    from crawlee import ConcurrencySettings, Request
    from crawlee.configuration import Configuration
    from crawlee.crawlers import BeautifulSoupCrawler, BeautifulSoupCrawlingContext

    IMX = "https://imx.leolist.cc/"
    DEFAULT_DELAY = 10


    def data_dir() -> Path:
        xdg = os.environ.get("XDG_DATA_HOME")
        root = Path(xdg) if xdg else Path.home() / ".local/share"
        d = root / "leolist-crawlee"
        d.mkdir(parents=True, exist_ok=True)
        return d


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
        p.add_argument("url", help="listing index URL (e.g. .../personals/female-escorts/greater-toronto/york)")
        p.add_argument("--max-details", type=int, default=20, help="max ad pages to enqueue (default 20)")
        p.add_argument("--delay", type=float, default=DEFAULT_DELAY, help="seconds between HTTP requests (default 10)")
        p.add_argument("-o", "--output", default=None, help="write JSON to this path (default: dataset under XDG)")
        args = p.parse_args()

        if args.max_details < 0:
            print("leolist-crawlee: --max-details must be >= 0", file=sys.stderr)
            return 2

        dest = data_dir()
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
    exec uv run --quiet --python 3.12 --with 'crawlee[beautifulsoup]' python ${runner} "$@"
  '';
}
