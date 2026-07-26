# `jobspy` — scrape jobs from LinkedIn/Indeed/Glassdoor/Google/ZipRecruiter/etc. into
# CSV or JSON. A thin, reproducible CLI around the off-the-shelf `python-jobspy` library
# (github.com/speedyapply/JobSpy) — JobSpy has no CLI of its own, so this wraps its
# `scrape_jobs()` behind argparse and runs it in an EPHEMERAL uv environment
# (`uv run --with python-jobspy`), so nothing is pip-installed globally and the tool is
# reproducible per-invocation. uv + Python are pinned from Nix; python-jobspy is fetched
# by uv at first run (cached after) — the same runtime-fetch model the uvx MCP servers use.
#
#   jobspy --search "principal engineer" --location "Toronto, ON" \
#          --sites linkedin,indeed --results 40 --hours-old 168 --output jobs.csv
#
# No API keys are needed. LinkedIn rate-limits hard (~page 10 on one IP) — pass
# --proxies for heavy scraping. Output is a pandas DataFrame rendered to CSV (default)
# or JSON, to --output FILE or stdout.
{
  writeShellApplication,
  writeText,
  uv,
  coreutils,
}:
let
  # The actual scrape logic. argparse owns all flag parsing; the shell wrapper just
  # forwards "$@". Avoids bash arg-parsing entirely. (No triple-single-quotes or ''${}
  # here — they collide with Nix '' strings.)
  runner = writeText "jobspy_run.py" ''
    import argparse
    import sys

    from jobspy import scrape_jobs

    ALL_SITES = [
        "linkedin", "indeed", "glassdoor", "google",
        "zip_recruiter", "bayt", "naukri", "bdjobs",
    ]


    def main() -> int:
        p = argparse.ArgumentParser(
            prog="jobspy",
            description="Scrape jobs from multiple boards into CSV/JSON (python-jobspy).",
        )
        p.add_argument("-s", "--search", required=True, help="search term (job title/keywords)")
        p.add_argument("-l", "--location", default="", help="location, e.g. 'Toronto, ON'")
        p.add_argument("--sites", default="linkedin,indeed",
                       help="comma-separated boards (default: linkedin,indeed). "
                            "choices: " + ",".join(ALL_SITES))
        p.add_argument("-n", "--results", type=int, default=20,
                       help="results wanted PER site (default 20)")
        p.add_argument("--hours-old", type=int, default=None,
                       help="only jobs posted within the last N hours")
        p.add_argument("--country", default="Canada",
                       help="country for Indeed/Glassdoor (default: Canada)")
        p.add_argument("--remote", action="store_true", help="remote jobs only")
        p.add_argument("--job-type", default=None,
                       help="fulltime|parttime|contract|internship")
        p.add_argument("--distance", type=int, default=None, help="radius in miles")
        p.add_argument("--proxies", default=None,
                       help="comma-separated proxies (host:port[,host:port...])")
        p.add_argument("--linkedin-description", action="store_true",
                       help="fetch full LinkedIn descriptions (slower)")
        p.add_argument("-o", "--output", default=None,
                       help="output file (default: stdout)")
        p.add_argument("-f", "--format", choices=["csv", "json"], default="csv",
                       help="output format (default csv)")
        args = p.parse_args()

        sites = [s.strip() for s in args.sites.split(",") if s.strip()]
        bad = [s for s in sites if s not in ALL_SITES]
        if bad:
            print("jobspy: unknown site(s): " + ",".join(bad), file=sys.stderr)
            print("jobspy: valid sites: " + ",".join(ALL_SITES), file=sys.stderr)
            return 2

        proxies = None
        if args.proxies:
            proxies = [x.strip() for x in args.proxies.split(",") if x.strip()]

        kwargs = dict(
            site_name=sites,
            search_term=args.search,
            location=args.location,
            results_wanted=args.results,
            country_indeed=args.country,
            is_remote=args.remote,
            linkedin_fetch_description=args.linkedin_description,
        )
        if args.hours_old is not None:
            kwargs["hours_old"] = args.hours_old
        if args.job_type is not None:
            kwargs["job_type"] = args.job_type
        if args.distance is not None:
            kwargs["distance"] = args.distance
        if proxies is not None:
            kwargs["proxies"] = proxies

        try:
            jobs = scrape_jobs(**kwargs)
        except Exception as e:  # noqa: BLE001 — surface any scraper error to stderr, fail
            print("jobspy: scrape failed: " + str(e), file=sys.stderr)
            return 1

        n = 0 if jobs is None else len(jobs)
        print("jobspy: " + str(n) + " jobs from " + ",".join(sites), file=sys.stderr)

        if args.format == "json":
            text = "[]" if n == 0 else jobs.to_json(orient="records", indent=2)
            if args.output:
                with open(args.output, "w") as fh:
                    fh.write(text)
            else:
                sys.stdout.write(text + "\n")
        else:
            if args.output:
                jobs.to_csv(args.output, index=False)
            else:
                jobs.to_csv(sys.stdout, index=False)

        if args.output:
            print("jobspy: wrote " + args.output, file=sys.stderr)
        return 0


    if __name__ == "__main__":
        sys.exit(main())
  '';
in
writeShellApplication {
  name = "jobspy";
  runtimeInputs = [
    uv
    coreutils
  ];
  text = ''
    # Run python-jobspy in an ephemeral uv env (pinned Python; library fetched+cached
    # by uv). argparse in the runner owns all flags — just forward "$@".
    exec uv run --quiet --python 3.12 --with python-jobspy python ${runner} "$@"
  '';
}
