# The photo system

**Words live inside the photo. The vibe index lives beside the folder.**

## Two tools

| | photo-describe | rclip |
|---|---|---|
| Writes | words INSIDE each file | an index beside the folder |
| Searches | exact words, dates, camera | the pixels |
| Travels when you copy the file | yes | no |
| If deleted | rerun the model | rebuild in minutes |
| Gitignore | no (it's in the file) | yes |

## Ingest: two tools, two jobs

```
┌────────────────────────┐                          
│bulk download to assets/├─────────────┐            
└────────────┬───────────┘             │            
             │                         │            
             ▼                         ▼            
┌────────────────────────┐ ┌───────────────────────┐
│     photo-describe     │ │         rclip         │
└────────────┬───────────┘ └───────────┬───────────┘
             │                         │            
             ▼                         ▼            
┌────────────────────────┐ ┌───────────────────────┐
│ words INSIDE each file │ │index beside the folder│
└────────────────────────┘ └───────────────────────┘
```

## Setup, per project

```bash
cd assets
photo-describe .          # writes words into the files
rclip -t 5 "anything"     # builds the index (first run)
```

## Finding a photo

```
┌────────────────┐        
│you need a photo│        
└────────┬───────┘        
         │                
         ▼                
┌────────────────┐        
│ know the word? ├────┐   
└────────┬───────┘    │   
         │            │   
         ▼            ▼   
┌────────────────┐ ┌─────┐
│     mdfind     │ │rclip│
└────────┬───────┘ └──┬──┘
         │            │   
         ▼            │   
┌────────────────┐    │   
│    pick one    │◄───┘   
└────────────────┘
```

## Searching

```bash
mdfind -onlyin . "bathroom"          # know the word
rclip "cold lonely morning"          # just a feeling
rclip --interactive "beach"          # thumbnail grid
exiftool -r -if '$XMP:Rating >= 4' -filename .   # by rating
```

## What lands in a photo

```
Description : Two people lie on a bed: a woman in dark top and a
              shirtless man, with pink and dark geometric pillows.
Keywords    : people, adult, consumer electronics
Rating      : 3
```

Finder Get Info shows it. Spotlight indexes it. Survives copy/upload/move.

## Three surprises

- **Re-indexing is automatic.** rclip updates its index every time you search. No cron, no daemon.
- **Per-project scoping is right.** In social-media/assets you want those assets, not your 2013 trip.
- **Keywords are the weak half.** Apple's tagger gave `people, adult` on 3 of 4 test photos. The caption carries the value.

## Is a describe job actually running?

**Never trust file mtimes.** `photo-describe` writes with exiftool's `-P`,
which deliberately *preserves* the original modification time — a
successful write never bumps it. `ls -lt`, `find -newermt`, anything
mtime-based reads as "nothing happening" no matter how many photos have
actually been described. MEASURED, 2026-09-05: this, stacked with
`nix-media-queue.log` only flushing a job's output at the end (fixed —
`media-worker` now `tail -f`s the in-flight job's scratch file live), turned
a perfectly healthy ~4-hour batch into a "hung job" call.

The real probes:

```bash
# authoritative: how many are actually described right now
exiftool -q -q -m -if '$XMP:Description' -p '1' "<folder>" | wc -l

# is a model call in flight right now
pgrep -afl curl | grep 11434

# live progress of the current queue job
tail -f ~/Library/Logs/nix-media-queue.log

# top/htop-style live dashboard of the whole queue (running/queued/failed),
# refreshed every 2s with changed lines highlighted — media-queue-status,
# wrapped in nixpkgs' viddy (a "modern watch"); press q to quit
media queue top       # or the bare name, media-queue-top

# one-shot instead of live; `media queue` with no subcommand is the status read
media queue
```

## Optional nicety

`scripts/find`:

```bash
#!/usr/bin/env bash
cd "$(dirname "$0")/../assets" && exec rclip "$@"
```

## Where these tools live

`media-describe` (once `photo-describe`), `media` and the queue live in nix-config's
**`modules/features/media-cli/` capsule**. They left for
[`kattakath/nix-media-cli`](https://github.com/kattakath/nix-media-cli) on 2026-09-05 and came
back in-tree on 2026-09-12 (ADR-002 wave 5); either way they reach the Mac as
`programs.mediaCli.enable`, which is the whole point of the switch. `rclip` stays outside the
capsule: it is the VECTOR half, a third-party tool this repo merely installs, and it reaches
the stack through that module's `extraSearchPackages` seam.

Nothing about the workflow on this page changed. The commands are the same.

## The rule

Words = treasure. Index = cache.
