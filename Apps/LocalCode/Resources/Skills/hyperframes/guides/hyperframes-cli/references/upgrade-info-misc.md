# compositions and timeline

## timeline

```bash
hyperframes timeline          # tracks and clips as a table with bars
hyperframes timeline --json
```

Reach for `timeline` instead of opening `index.html` and each `data-composition-src` file when you need to know what is on the timeline: which clips exist, when they start and end, what they play, and how loud. It reads the project's files statically (no browser).

Text output is `timeline <N>s`, then one block per track kind (`video`, `graphics`, `captions`, `audio`) with one row per clip of that kind, ordered by absolute start:

```
graphics (2: 1 top-level, 1 nested)
  |██████                                  | sec-connector 0-6.7s src=compositions/connector-morph.html
  |██████████████                          | box 15.67-17.99s (local 0-2.32s) nested in sec-connector compositions/connector-morph.html
audio (1)
  | █                                      | vo 1.6-3.6s src=vo.mp3 vol=0.5 group=vo volume[0:0.2 2:1]
```

- The bar is 40 columns over the whole timeline. Times are seconds.
- `src=`, `vol=`, `rate=` (playback rate, only when not 1), `group=` (audio group), and `<target>[t:v ...]` (automation lane points, `t` in seconds from the clip start) appear only when the clip has them.
- The header counts every clip of that kind, nested ones included: `video (6: 2 top-level, 4 nested)`. The list is in absolute order, so the Nth row is the Nth clip of that kind on the main timeline. A clip inside a sub-composition prints its absolute start-end, then `(local <start>-<end>s)` (time inside that sub-composition), then `nested in <host row id> <file that declares it>`. Only one level of nesting is read: a sub-composition inside a sub-composition is listed as a row saying `children=unread`, and the clips inside it are not counted.
- With no `data-duration`/`data-end`, a media row still gets a resolved length and says where it came from: `duration=media` means the media probe measured the source (with playback start and rate applied); `duration=default` means an `img` got the 3s default; `duration=inferred` means a composition host summed its children; `pending: <reason>` (dotted bar, `duration` 0) means the source could not be probed (missing file, remote `src`, probe error). A non-media leaf with nothing to resolve prints no source.
- `lanes unreadable: ...` means the clip's `data-automation` or `data-fx-chain` did not parse; fix the attribute.

`--json` prints `{ timeline: { duration, tracks: [{ kind, rows: [...] }] } }`. A track's `rows` are every clip of that kind, nested ones included, by `absStart`; read them, never only the top level. Each row has `id`, `kind` (tag), `trackKind`, `start`, `duration`, `end` (local to the row's own file), **`absStart`, `absEnd`, `file`** (main-timeline time and the project-relative file that declares the clip — use these, not `start`/`end`, to compare clips across nesting), `trackIndex`, `src`, `sourceFile`, `volume`, `lanes`, `playbackRate`, `audioGroup`, `durationAuthored`, **`durationSource`** (`"authored" | "media" | "default" | "inner" | "pending"`, or `null` for a non-media leaf with nothing to resolve), **`pendingReason`** (why nothing resolved; `null` unless `durationSource` is `"pending"`), `laneError`, **`index`** (the row's position in its kind's `rows`; a position, not an id), **`nested`** (declared inside a sub-composition), **`host`** (plain id of the row that hosts a nested clip, else `null`), **`hostRow`** (`{kind, index}` of that host row), and `children` (`{kind, index}` pointers to the sub-composition's clips, one level; every clip is already a full row in its kind's `rows`, so nothing needs following).

### Query one-liners

```bash
TL=$(hyperframes timeline --json)
# 1. what plays at absolute time T=12.5
node -e 'const t=12.5,j=JSON.parse(require("fs").readFileSync(0,"utf8"));j.timeline.tracks.forEach(tr=>tr.rows.forEach(x=>{if(x.absStart<=t&&x.absEnd>t)console.log(x.id,x.file)}))' <<<"$TL"
# 2. find a clip by id or src -> file, track, absStart, absEnd
node -e 'const q="tsfx-pet2",j=JSON.parse(require("fs").readFileSync(0,"utf8"));j.timeline.tracks.forEach(tr=>tr.rows.forEach(x=>{if(x.id===q||x.src===q)console.log(x.file,x.trackKind,x.absStart,x.absEnd)}))' <<<"$TL"
# 3. every clip of one kind, nested included, in absolute order
node -e 'const k="video",j=JSON.parse(require("fs").readFileSync(0,"utf8"));j.timeline.tracks.find(t=>t.kind===k).rows.forEach(r=>console.log(r.id,r.absStart,r.absEnd))' <<<"$TL"
# 4. gaps and overlaps within a kind (positive = gap, negative = overlap)
node -e 'const k="video",j=JSON.parse(require("fs").readFileSync(0,"utf8"));const r=j.timeline.tracks.find(t=>t.kind===k).rows;for(let i=0;i<r.length-1;i++)console.log(r[i].id,r[i+1].id,r[i+1].absStart-r[i].absEnd)' <<<"$TL"
# 5. the Nth clip of a kind by absolute start (N=2)
node -e 'const k="video",n=2,j=JSON.parse(require("fs").readFileSync(0,"utf8"));const r=j.timeline.tracks.find(t=>t.kind===k).rows[n-1];console.log(r.index,r.id,r.absStart,r.file)' <<<"$TL"
```

## compositions

```bash
hyperframes compositions           # list compositions in project
hyperframes compositions --json
```

`compositions` lists every `data-composition-id` in the project (including sub-comps) with duration, resolution, and element count.

