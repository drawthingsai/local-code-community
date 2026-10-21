# 3D animation short

Use for a stylized character-driven short with a causal story and consistent
characters. Use the shared [production workflow](../production.md) for assets and
assembly, and [H3 prompting](../prompting.md) for generation.

## Story before coverage

Define the protagonist's want, underlying need, and flaw. The protagonist should
make choices that cause the next event. Establish the world's governing rule and
an emotional anchor—a prop, gesture, place, or relationship—to revisit at the end.
A useful eight-beat spine is setup, desire, first attempt, complication, escalation,
crisis, changed choice, and payoff. Let the protagonist's flaw intensify the crisis
and the changed choice resolve it. Dialogue should reveal a relationship change.
Scale the story to the running time; one clip needs one achievable dramatic action.

Lock the stylized 3D treatment. Character sheets should establish named roles,
proportions, colors, costume, important props, expressions, and useful views. Keep
environment reference images free of accidental characters. Review sheets are
planning artifacts; use an appropriate clean shot image for generation.

## Make continuity explicit

For a multi-shot film, write a table with these six columns:

| Column | What to record |
| --- | --- |
| Shot ID & Duration | Shot number and actual planned duration |
| Continuity Handoff | State inherited from the previous shot and state passed to the next |
| Reference Anchors (Spatial + Identity) | Character/scene asset names, fixed landmarks, character positions, off-screen characters, and lighting |
| Hook Type | The shot's purpose: reveal, reversal, visual joke, suspense, tenderness, chase, callback, or expression beat |
| Shot Description (Per-Second Directives) | Timed action, expression, camera, spatial relationships, sound cues, and the resulting state |
| Audio & Dialogue Track | Exact narration/dialogue, speaker and delivery, effects, and their time ranges |

Name landmarks and their screen positions: “doorframe at right third,” for example.
For each character, record position, facing, pose, and held objects. Track a character
who just exited by stating where they went. Carry key/fill/rim directions into the
next shot, explaining any change caused by the camera or action.

Break each shot into timed beats that cover its whole duration. Each beat should
specify action/pose/expression, camera movement, spatial position, an audio cue,
and the state it leaves for the next beat. Use half-second intervals for a critical
impact or reaction. Keep anticipation, arcs, squash-and-stretch, overshoot, and
follow-through coherent with the chosen animation style. Vary framing to reveal
new information, and use tilted compositions when imbalance serves the action.

Before rendering, read the handoff column as one continuous chain. Check that all
time is covered, every shot advances the story, locations and props stay coherent,
and dialogue fits. Split an overloaded shot; a small cast and one primary action
per beat are easier to keep legible.

The written shot table is authoritative. Optional pencil storyboards illustrate
it and should not silently change it. Keep panels aligned with shot IDs. Do not
send a labeled storyboard grid as the opening video frame unless the intended
output actually contains that grid.

Translate each selected shot into H3 syntax, preserving global speaker identities
and exact dialogue. Keep mouths closed for off-screen narration, and describe
visible delivery for on-screen speech.

## Review and assemble

Check each clip's identity, landmarks, screen direction, prop state, expressions,
speech intelligibility, and synchronized effects. Final frames should contain the
rendered scene without storyboard borders, arrows, labels, or timing notes.
Diagnose a failure before rerunning: simplify impossible action, repair an ambiguous
anchor, or split an overloaded shot. Preserve successful clips.

Assemble clips in table order using their current versions. Mix a continuous music
bed when requested, keeping dialogue and key effects audible. Watch the whole edit
for cause and effect, the emotional anchor's payoff, pacing, and audio continuity.
