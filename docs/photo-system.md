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

## Optional nicety

`scripts/find`:

```bash
#!/usr/bin/env bash
cd "$(dirname "$0")/../assets" && exec rclip "$@"
```

## The rule

Words = treasure. Index = cache.
