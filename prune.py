import json, os, re, subprocess
org, pkg, keep = os.environ["ORG"], os.environ["PKG"], int(os.environ["KEEP"])
dry = os.environ["DRY_RUN"] == "true"
api = f"/orgs/{org}/packages/container/{pkg}/versions"
out = subprocess.run(["gh", "api", "--paginate", "--slurp", f"{api}?per_page=100"],
                     check=True, capture_output=True, text=True).stdout
versions = [v for page in json.loads(out) for v in page]
tagged = [v for v in versions if v["metadata"]["container"]["tags"]]
sha = re.compile(r"^[0-9a-f]{12}$")
# A publish = one bare <sha12> tag, dated by the version it sits on; newest first.
pubs = sorted({(v["created_at"], t) for v in tagged for t in v["metadata"]["container"]["tags"] if sha.match(t)}, reverse=True)
order = []
for _, t in pubs:
    if t not in order:
        order.append(t)
kept = set(order[:keep])
for v in tagged:
    if {"latest", "1"} & set(v["metadata"]["container"]["tags"]):
        kept |= {t for t in v["metadata"]["container"]["tags"] if sha.match(t)}
def owner(tag):
    return tag.split("-", 1)[0] if sha.match(tag.split("-", 1)[0]) else None
print(f"publishes: {len(order)}; kept: {sorted(kept)}")
for v in tagged:
    tags = v["metadata"]["container"]["tags"]
    owners = {owner(t) for t in tags}
    if None in owners or owners & kept:
        continue
    if dry:
        print(f"would delete version {v['id']} {tags}")
    else:
        subprocess.run(["gh", "api", "-X", "DELETE", f"{api}/{v['id']}"], check=True, capture_output=True)
        print(f"deleted version {v['id']} {tags}")
