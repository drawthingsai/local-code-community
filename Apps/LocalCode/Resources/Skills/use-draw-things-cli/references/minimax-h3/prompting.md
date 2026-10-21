# MiniMax H3 prompting

Write a complete audiovisual timeline using the format for the selected input
mode. Describe visible actions and audible events in playback order, with explicit
shot transitions and stable identities.

## Setup and input modes

Use the H3 FL2VA checkpoint for text-to-video-and-audio (T2VA), first-frame
animation (I2VA), and first/last-frame animation. These are input modes of the
same checkpoint: FL2VA accepts no frames, a first frame only, or both a first
and last frame. Select the exact model ID from `draw-things-cli models list`.

Use a Ref2VA checkpoint when images provide reference content rather than fixed
endpoint frames, or when supplying reference audio.

| Checkpoint | Input mode | CLI inputs |
| --- | --- | --- |
| FL2VA | T2VA: generate video and audio from text | Text prompt; omit `--image` |
| FL2VA | I2VA: develop forward from a supplied first frame | `--image first.png` |
| FL2VA | First/last-frame animation: connect two supplied endpoint frames | `--image first.png --image last.png`, in that order |
| Ref2VA | Generate using reference content and/or audio | Reference images via `--image` and/or audio via `--audio` |

Match every prompt reference to an attached input. For reference footage, check
current CLI help for the required input capability. H3 generates audio from
`--audio` conditioning; place
the original recording in the final edit when exact soundtrack reuse is required.

## Base prompt structure

All FL2VA input modes use these fields, in this order. For text-only T2VA, start
directly with the fields:

```text
integrated_multimodal_description: [Shot 1] ...

overall_soundscape: ...

non_diegetic_music: ...
```

When supplying a first frame, with or without a last frame, put this exact
instruction before the fields, followed by a blank line:

```text
For the target video, at 0.00 seconds into the target video, <Picture 1> (from [Shot 1]) is fully referenced.
```

Establish the supplied image's composition, subject identity, clothing, props, and
lighting, then develop observable motion from that state. Describe the movement
between states: opening pose, action onset, continuous development, result, and
reaction. Preserve clothing, colors, props, and spatial relationships throughout.

When also supplying a last frame, describe the motion connecting the opening
state to that final composition. Plan the action to reach the supplied ending
within the clip's duration.

## Reference prompt structure

Ref2VA uses six sections in order:

1. `subject_definitions`: define the actual reference content and stable labels.
2. `summary`: summarize the target and reference roles, starting with `[reference generation]`, `[audio reference]`, or `[reference generation + audio reference]` as appropriate.
3. `retention_analysis`: identify what each reference preserves, changes, or transfers.
4. `detailed_description`: describe the complete audiovisual timeline shot by shot.
5. `overall_soundscape`: ambient sound and physical/nonverbal sounds.
6. `non_diegetic_music`: music heard by the audience but not by the characters.

Define labels once and keep their meaning consistent:

- `<Subject N>`: reusable visible content, such as a person, object, setting, or
  costume. Cite the image it comes from in the definition. One picture may define
  several subjects.
- `<Picture N>`: an attached image serving as a composition or frame anchor. Give
  it a separate definition when the image itself has a role beyond defining a subject.
- `<Audio N>`: an attached audio reference. State whether it guides voice timbre,
  delivery, music style, rhythm, or sound texture. When it guides a speaker, include
  that speaker's global `(Sx)` ID in the definition.

In `retention_analysis`, give each visible reference a line with its appearance
locations and one of these markers:

| Marker | Meaning |
| --- | --- |
| `fully_preserved` | Preserve all features established in its definition |
| `partially_preserved` | Keep the named features and explicitly change the others |
| `attribute_transfer` | Transfer named features to another target subject |
| `weak_reference` | Use broad style, composition, or atmosphere |

For audio conditioning, use `reference` and identify the audible properties to
carry forward. For example:

```text
<Subject 1> (appears in [Shot 1], [Shot 2]): fully_preserved - retain the presenter's face, short brown hair, and green apron.
<Audio 1>: reference - its calm vocal timbre guides <Subject 1> (S1).
```

Begin `detailed_description` with one or two sentences establishing the visual
style, then `[Shot 1]`. Introduce reference labels where their content first appears
and describe the actual composition and action. Treat normal movement and changing
expressions as events in the scene, rather than losses of identity fidelity.

## Timing, language, and sound

Write descriptive sections in English. Preserve dialogue, lyrics, and visible
text in their original language. Shot 1 has no initial timestamp. Later shots
start with an increasing cut time within the clip, for example:

```text
[Shot 2] At 00:03.500, the camera cuts to a close-up of the folded paper bird.
```

Describe each shot's composition, subjects, actions, camera movement, and sound.
Camera direction should distinguish a physical push from a lens zoom; add speed
and amplitude when they matter. Avoid unnecessary cuts for small viewpoint changes.

Give vocalizing characters stable `(S1)`, `(S2)` IDs across shots. Keep delivery
instructions outside the dialogue block; inside it, put only the language tag and
exact spoken words:

```text
The child with a soft, bright voice (S1) says: <d>[English] It can fly!</d>
```

Assign speaker IDs by first vocal appearance, including off-screen voices. Describe
each speaker's voice when first introduced and reuse the same ID in every shot and
audio-reference definition. For group speech, combine IDs as `(S1,S2)`. Characters
who never vocalize need no speaker ID.

For voiceover, use `says in an off-screen voiceover` and state immediately after
the dialogue block that the corresponding visible character's lips remain closed:

```text
The presenter (S1) says in an off-screen voiceover: <d>[English] A new leaf opens every morning.</d> while her lips remain completely closed.
```

When a line crosses a cut, place `<scenetrans>` at the connecting points in both
parts and explicitly state that the voice continues across the transition. Use
`<cutoff>` when speech is truncated by the clip ending. Keep delivery instructions
outside `<d>` and preserve the spoken words and punctuation inside it.

Put visible text in double quotes, preserving its spelling and punctuation.
Summarize ambience, physical sounds, and nonverbal sounds in `overall_soundscape`
using one to four sentences. Put dialogue, singing, and music audible within the
scene into the timeline. Describe audience-only music in `non_diegetic_music`
using one to three sentences about instruments, tempo, rhythm, and dynamics.
Use `non_diegetic_music: N/A` for no background score, and
`overall_soundscape: N/A` for an explicitly silent clip.

Plan short clips around a 4–15-second action. The CLI currently accepts
H3 frame counts of `1`, or `17k + 5` within `5...362`; its default is 124 frames.
The usual H3 rate is 24 fps, with model metadata able to override it. Thus 124
frames is approximately 5.17 seconds, not exactly five. Set timing from the actual
frame count and frame rate, keep all events within that duration, and conform an
exact delivery duration in editing when needed. A 30-second film requires multiple
clips and assembly. Use current help and model metadata to confirm these settings.

## Example: short text-to-video clip

For a roughly five-second clip with one shot and no dialogue:

```text
integrated_multimodal_description: [Shot 1] A layered papercraft scene, framed in a static medium shot. A small blue paper bird rests on a cream cardboard branch at center. During the first second its folded head tilts toward a loose red paper leaf. The bird taps the leaf with its beak; the leaf rocks on a visible paper hinge, then settles. The bird makes one short, jointed hop along the branch and holds still for the final second. Thick cut edges and tiny contact shadows remain visible throughout.

overall_soundscape: Quiet paper creaks accompany the head tilt and hop. A dry cardboard tap coincides with the beak touching the leaf, followed by a soft rustle as it settles.

non_diegetic_music: N/A
```

## Example: image and voice references

For a roughly five-second Ref2VA clip, attach an image of the presenter as
`--image` and a voice recording as `--audio`:

```text
subject_definitions:
<Subject 1> is the presenter in <Picture 1>, with short brown hair and a green apron.
<Audio 1> is the calm, clear voice-timbre reference for <Subject 1> (S1).

summary:
[reference generation + audio reference] <Subject 1> notices a new leaf on a potted plant, points to it, and speaks using the vocal qualities of <Audio 1>.

retention_analysis:
<Subject 1> (appears in [Shot 1]): fully_preserved - retain her face, short brown hair, and green apron.
<Audio 1>: reference - use its calm vocal timbre and unhurried delivery.

detailed_description:
Naturalistic live-action footage with soft window light and a quiet indoor setting.
[Shot 1] A static medium shot frames <Subject 1> (S1) beside a small potted plant on a table. She looks down at a fresh green leaf, brings one hand beside it without covering it, and says with the calm voice timbre referenced from <Audio 1>, <d>[English] Look at that new leaf.</d> She lowers her hand and holds a small smile through the final second.

overall_soundscape:
Quiet room tone continues beneath a soft sleeve rustle as the presenter moves her hand.

non_diegetic_music:
N/A
```

Write the final prompt to a UTF-8 file and use `--prompt-file`, with the exact
discovered model ID and explicit output path. Retain the model's recommended
settings unless the task requires a change. Inspect the exported clip's duration,
motion, reference adherence, text, and audio before reporting completion.

For multi-asset production, read the shared [production workflow](production.md).
