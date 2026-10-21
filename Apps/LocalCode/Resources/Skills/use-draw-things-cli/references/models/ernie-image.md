# ERNIE Image

Use for ERNIE Image and ERNIE Image Turbo. Expand the brief into a concrete
description of the finished image, with complete visible text and explicit layout.

## Turn the request into a finished visual description

Work from the user's brief, target width and height, reference material, and any
exact copy. Think of the result as a description of the finished image: a reader
should be able to locate every important subject, understand what it is doing,
and transcribe the requested visible text from the description alone.

Write the descriptive prose in Chinese by default, unless the user requests
another prompt language. Keep names and visible text in their requested language,
including English copy inside Chinese prose. Choose image-text language from the
brief and audience.

Build the description in a coherent visual order:

1. Establish the medium and overall arrangement: photograph, illustrated poster,
   infographic, screenshot, comic, or another requested format. Start directly
   with the visual description, avoiding a preamble such as “this is an image of”.
2. Place the main subjects. State counts, appearance, actions, contact points,
   and relationships. Bind an attribute to its owner instead of listing detached
   colors, clothes, or objects that might be assigned to the wrong subject.
3. Describe the environment and spatial organization. Use the actual aspect ratio:
   a tall poster can have a headline, central image, and footer; a wide diagram
   may need a left-to-right sequence. Preserve relationships the user specified.
4. Explain the rendering: light direction and quality, palette, materials,
   depth, camera angle, and artistic technique where relevant to the brief.
5. Place the complete visible copy, with its hierarchy, grouping, and appearance.

Aim for at most 1,000 tokens of useful, nonredundant detail. Preserve all required
copy even when that calls for a longer prompt.

## Make information-bearing images concrete

Turn abstract visual requirements into concrete content.
“A diagram explaining evaporation” needs the water, vapor path, heat source,
arrows, and labels that communicate evaporation. “An app screen” needs actual
controls and readable labels, not a promise that interface elements are present.

For a sparse creative brief, supply coherent details needed to express the idea.
For a detailed brief, preserve its subjects, counts, copy, and relationships.
Keep completion proportional to the request: a minimalist product photo should
remain minimal. Do not invent product specifications, prices, measurements, or
brand claims and present them as supplied facts. Use the provided facts or obtain
the missing information when it is essential to the requested deliverable.

Name recognizable entities when their identity is known; do not guess an identity
from an ambiguous reference. Preserve the name of a requested fictional character
without adding a long speculative inventory of traits that may conflict with it.

For charts whose proportions must match supplied data, follow
[Precise infographics](../workflows/precise-infographics.md): correct printed
values do not make bar lengths accurate. Use ERNIE for the poster's composition
and typography, and draw the chart itself in code.

## Exact text

- Enclose each literal text span in ASCII single quotes, for example 'OPEN' or
  '春日市集'. Preserve spelling, capitalization, accents, punctuation, and language.
- Include all requested text. A label such as “contact details” does not substitute
  for an email address the user supplied.
- Associate each span with a visible location and visual treatment. Specify which
  words are the headline, secondary copy, labels, or footer.
- If working from a reference, copy text only when it is legible. Ask for an exact
  transcription when uncertain copy is necessary; do not silently reconstruct it.
- Keep the typography plan compatible with the canvas. Reduce decoration and
  simplify grouping before making mandatory copy too small to read.

## Worked examples

### Poster with mixed-language copy

Brief: a portrait spring-market poster, with exactly '春日市集', 'SPRING MARKET',
and '周六 10:00–17:00'. Botanical illustration, cream and green palette.

```text
竖版植物插画海报，米白色纸张背景，深绿色与嫩绿色为主色，画面按上方标题、中部插画、下方时间三个层次组织。顶部居中写着清晰的大标题 '春日市集'，采用笔画饱满、间距舒展的深绿色中文字体；紧接下方用较小的深绿色无衬线大写字母写着 'SPRING MARKET'。中部是一组向两侧舒展的春季枝叶，叶片以细线勾勒并用平涂绿色表现，枝叶围绕中心留白，避开上下文字区域。底部居中独立写着 '周六 10:00–17:00'，字号足够清晰，与标题形成明确层级。纸面带有细微纤维质感，整体光线均匀柔和，版面整洁，边缘留出宽裕空白，画面中的文字仅包含上述三处。
```

### Scientific explainer with an explicit layout

Brief: a wide classroom illustration of the water cycle. The labels must be
'蒸发', '凝结', and '降水'.

```text
横版课堂科普插画，以清晰的循环路径展示水循环，浅蓝色天空与下方的湖泊、山坡构成背景。左下方是蓝色湖面，左上方的太阳照亮湖水；从湖面向上绘制一条粗而清晰的橙色箭头，箭头旁写着 '蒸发'。画面上方中央是一团由浅灰蓝色轮廓勾勒的白云，云的正上方写着 '凝结'，从上升箭头到白云之间用连续的小水汽点连接。右侧白云下方绘制向山坡和湖面落下的蓝色雨滴，旁边写着 '降水'；山坡底部用蓝色弧形箭头表现水流返回湖泊，使路线形成闭合循环。三个中文标签使用一致的大号深蓝色无衬线字体，分别紧邻各自过程，互不遮挡。插画采用简洁平涂、圆润轮廓和柔和色彩，重点突出过程之间的方向关系。
```

### Restrained photographic brief

Brief: one red ceramic cup on a bare oak table beside a window; no text.

```text
自然光静物摄影，一只红色陶瓷杯放在空旷的橡木桌面上，杯身和弧形把手完整可见。窗户位于画面左侧之外，柔和侧光照亮杯口与杯身左侧，在桌面上留下向右延伸的淡影。桌面的浅棕色木纹清晰而不过分突出，背景是轻微虚化的浅色墙面。构图保留杯子周围充足的空白，画面只呈现陶瓷杯、桌面和背景墙，不添加文字或装饰图案。
```

## CLI handoff and review

Write the finished description as plain UTF-8 text and pass it with `--prompt-file`.
Keep planning and commentary outside the generation prompt.

Select the exact ERNIE variant from `models list` and retain its recommended
sampling settings. Standard and Turbo are separate variants; prompt guidance
does not make their step/CFG settings interchangeable.

Inspect the output against the brief: exact copy, subject count, attribute
ownership, arrow directions, spatial relationships, and aspect ratio. For missing
text, make its location and hierarchy clearer. For confused relationships, group
each subject with its own attributes and simplify competing scene detail. Preserve
the requested content through the correction.
