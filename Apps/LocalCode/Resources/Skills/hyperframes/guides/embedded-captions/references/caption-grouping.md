# Caption Grouping

How to turn the supplied word-level transcript into the `groups[]` array of plan.json.

## Goal

**Each group is one visual phrase**: enters, reveals word-by-word, exits. Rule of thumb: 1 group ≈ 1 comma-to-comma clause or 1 breath of speech.

## Input

Supplied `transcript.json`:

```json
{
  "words": [
    { "text": "Some", "start": 0.24, "end": 0.44, "type": "word" },
    { "text": " ", "start": 0.44, "end": 0.48, "type": "spacing" },
    { "text": "memories", "start": 0.48, "end": 0.82, "type": "word" }
  ]
}
```

Drop `type: "spacing"` entries; you only need words.

## Break boundaries

Cut a new group at ANY of:

1. **Pause ≥ 500ms** (gap between word.end[i] and word.start[i+1]) — speaker took a breath.
2. **Sentence terminator** — word ends with `.`, `?`, `!`, or an em-dash-like pause.
3. **Strong comma** — `,` followed by pause ≥ 250ms.
4. **Discourse reset** — words like "but", "so", "and then", "you know" starting a clause often merit their own or new group.
5. **Group reaches 6 words OR 2.5 seconds** — whichever first.

Hard constraints:

- Minimum 2 words per group (1-word exceptions: interjections like "Wait." a short complete phrase).
- Minimum 0.5s on screen. If a group is less, merge into neighbor.
- No overlapping groups — at most one visible at a time.

## Timing the group

For a group with words `w[0]..w[n-1]`:

- `in` = `w[0].start - 0.08` (enter slightly before first word)
- `out` = `min(next_group.in - 0.05, w[n-1].end + 0.6)` (linger ~0.6s after last word, but don't collide with next)

The last group extends to the video end if needed.

## Editorial surgery is allowed

You do NOT have to caption every word. It's fine to:

- **Drop filler** like extra "you know"s, "um"s, "I mean"s if they bloat the visual pace.
- **Condense** a 6-word run into 4 by cutting function words, as long as the meaning and timing remain truthful.
- **Skip the whole thing** during obvious silence or non-speech (laugh, music interlude).

Editorial rule: you are writing typography to support the speech, not a court transcript. Keep meaning, trim noise.

## word.start/end inside groups

Pass through the original timestamps from the transcript. Don't retime individual words — only the group `in`/`out`. The word-level karaoke reveal inside each group uses the original w.start.
