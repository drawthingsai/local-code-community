---
name: embedded-captions
description: Add readable foreground captions to existing footage using supplied timed text. Use for plain captions or subtitles without changing the footage. Unclear → hyperframes.
---

# Embedded captions

Add captions to the supplied video using the supplied word or phrase timings. Keep the video unchanged.

## Caption model

Every spoken phrase is one of three things:

|           | What                                             | How it's shown                                                                                                                                                    |
| --------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **drop**  | filler — um/uh, stutters, self-corrections       | not shown                                                                                                                                                         |
| **rail**  | the default — ordinary spoken content (verbatim) | clean lower-third subtitle, **in front**, readable. A punch word can get an inline `emphasis` highlight (accent colour / active-word pop) — it stays on the rail. |

## Author captions

Read [references/rail.md](references/rail.md) for placement, safe area, typography, and active-word emphasis. Read [references/caption-grouping.md](references/caption-grouping.md) to group supplied word timings into readable phrases. Preserve the supplied timestamps; phrase-level cues use their supplied start and end times without inventing word alignment.

Use [hyperframes-core](../hyperframes-core/GUIDE.md) for the video and caption clips. Each caption group's `data-start` and `data-duration` follow its timing window; animate a child of the clip on the paused composition timeline. Keep one group visible at a time.

## Verify and deliver

Run `hyperframes check` and `hyperframes snapshot --at <caption-midpoints>`. Inspect readability, safe margins, cue boundaries, and synchronization with speech. Preview with `hyperframes preview --foreground --no-open`. After approval, prepare the [compiled export page](../hyperframes-cli/references/preview-render.md#render), then export with `html2video .hyperframes-export.htm --output renders/video.mp4`.
