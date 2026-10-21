# Bash inline image support handoff

Liu Liu is not fully onboard with this handoff.

The implementation order is settled: Liu Liu will first implement image support
in the existing bash execution path before doing further browser work. The
proposed first transport is a small subset of iTerm2 OSC 1337. Its details remain
implementation choices; this handoff does not settle the broader browser or
computer-use architecture.

Prepared October 10, 2026. Bash image transport subsequently landed on main in
`827abcfeb` (Adding image support for BashTool). The browser commands now use
that transport for inline screenshots and `snapshot --image`, as described in
[Browser API](BrowserAPI.md). The checklist below records the original proposed
requirements; it does not imply every item was implemented by that commit.

## First milestone

An ordinary command can print text and an inline PNG. Local Code extracts that
PNG from captured output and returns it to the model in the same bash tool
response. A command that is still running can deliver the image through a later
status or wait response. The chat renders the image using the existing media
path, and an image-capable model receives its pixels without another `view`
invocation.

Use the current `bash`, `bash_status`, `bash_wait`, and `bash_stop` entries. No
additional model-visible tool or browser dependency is needed for this
milestone. A standalone image emitter is enough to implement and exercise it.

The existing browser API is described in [Browser API](BrowserAPI.md). Browser
inline screenshot output, region capture, scroll settling, accessibility
observations, and model guidance follow after the bash milestone. The earlier
[Browser Use Handoff](BrowserUseHandoff.md) remains a proposal.

## Proposed terminal protocol

Start with the iTerm2 inline file form, accepting PNG data and both standard
terminators:

```text
ESC ] 1337;File=inline=1;size=<byte-count>:<base64-png> BEL
ESC ] 1337;File=inline=1;size=<byte-count>:<base64-png> ESC \
```

The diagram separates control characters for readability. Actual output uses
`0x1b` for ESC and `0x07` for BEL, with no added spaces or wrapped base64. The
second terminator is ST, the two bytes `0x1b 0x5c`.

The [iTerm2 specification](https://iterm2.com/documentation-images.html) defines
`inline=1` as display and `size` as optional progress metadata. Require
`inline=1` to admit an image; absent or false `inline` is not an image observation.
Do not allocate from the declared `size` or make its presence a requirement.
Allow optional metadata such as `name`, `width`, `height`, and
`preserveAspectRatio` without using it to determine the model's image contents.
Verify the decoded bytes themselves are PNG.

This is a protocol subset. iTerm2 also has multipart transfer commands;
[Kitty graphics](https://sw.kovidgoyal.net/kitty/graphics-protocol/) supports PNG,
chunking, and richer image management; [SIXEL](https://vt100.net/dec/ek-vt3xx-hr-002.pdf)
uses a separate pixel and palette encoding. Those can be considered later.
For the first slice, OSC 1337 carries the existing PNG bytes directly. Handling
that escape sequence is sufficient; a terminal graphics renderer is not needed.

Set explicit limits for buffered frame bytes, decoded image bytes, and image
dimensions or pixel count. Choose and document the numeric limits in the
implementation. The remote image path's existing 10 MiB limit is a useful
reference, not an agreed limit for every bash image. Oversized frames need a
bounded discard path that resumes normal output after the terminator.

## Independent emitter

Use a known PNG fixture before connecting any browser producer. The following
can be saved as `emit-inline-image.py` and run with
`python emit-inline-image.py fixture.png` through the app's bash tool:

```python
import base64
from pathlib import Path
import sys

png = Path(sys.argv[1]).read_bytes()
sys.stdout.write("before image\n")
sys.stdout.flush()
sys.stdout.buffer.write(
    b"\x1b]1337;File=inline=1;size="
    + str(len(png)).encode("ascii")
    + b":"
    + base64.b64encode(png)
    + b"\x07\n"
)
sys.stdout.buffer.flush()
sys.stdout.write("after image\n")
sys.stdout.flush()
```

This emitter exercises the wire format only. Automated tests should also emit
ST and deliberately split a frame across writes and polls. Use the existing
test command registration in `BashUserInteractionTests` when a shell runtime
does not provide Python.

## Integration points before image support

| Source | Current behavior and required change |
| --- | --- |
| [BashTools.swift](../Sources/Agent/BashTools.swift) | `readOutput` converts captured bytes to UTF-8, and `renderTerminalOutput` strips OSC. Decode image frames before that stripping. Give each `BashJob` independent decoder state for stdout and stderr. Change response construction and all four bash completions to carry media. |
| [ToolsRegistry.swift](../Sources/Agent/ToolsRegistry.swift) | The four bash branches use `textCompletion`, which wraps a `String` in `ToolResponse`. Pass their multipart `ToolResponse` through directly. |
| [ToolCallParser.swift](../Sources/Agent/ToolCallParser.swift) | `ToolResponse.Content` already has `.text` and `.imageDigest`. Reuse these and preserve decoding of existing text-only transcripts. |
| [EmbedsFileStore.swift](../../../Libraries/ProjectHistoryManager/Sources/EmbedsFileStore.swift) | `insert(data:)` stores bytes in the project's `.localc/cas` and returns a digest. Store validated PNG bytes here before returning `.imageDigest`. |
| [ViewTool.swift](../Sources/Agent/ViewTool.swift) | Reference for ImageIO validation, image storage, and an image-bearing response. The new bash path should use this machinery without invoking `view`. |
| [Qwen3_5CodeAgent.swift](../Sources/Agent/Qwen3_5CodeAgent.swift) and [DeepSeek4CodeAgent.swift](../Sources/Agent/DeepSeek4CodeAgent.swift) | Existing image response handling connects stored media to model input. Exercise an image-capable configuration; support varies by model. |
| [RemoteToolsBridge.swift](../Sources/RemoteAPI/RemoteToolsBridge.swift) | The general response adapter currently keeps only `.text`, discarding `.imageDigest`. Remote image delivery requires fixing this adapter as described below. |

The intended data path is:

```text
command writes text and OSC image bytes
  -> per-job stream decoder emits text and complete image payloads
  -> validate PNG and store it in the project image store
  -> ToolResponse contains text and imageDigest parts
  -> existing chat and model media paths consume the result
```

A synchronous `TerminalImageDecoder.swift` is one possible implementation. Keep
parsing independent of the image store so byte-boundary behavior can be tested
directly. Leave scheduling with the current bash job machinery. New ordinary
Swift source names and types should follow the repository naming policy and
avoid an app-name prefix.

## Streaming and response behavior

Read raw `Data` from the capture files. An image header, payload, terminator,
ANSI sequence, or multibyte UTF-8 character can cross any read boundary. Retain
incomplete state between reads; an empty poll while the process is running is
not end of stream. Never expose partial base64 as ordinary text.

Preserve the existing job header, status, exit code, stop reason, terminal text
rendering, and diagnostics. Within each stream, return text and image parts in
emission order. Keep the current stdout and stderr grouping: separate capture
files do not establish a total ordering between the two streams.

Commit decoder state and file offsets together under the existing output
consumption lock. `response(consumeOutput: false)` must remain a peek: use a copy
of decoder state or equivalent handling so peeking cannot consume an image or
alter the next real response. Repeated consuming polls with no new bytes must
return no repeated image. Two separately emitted frames with identical PNG
bytes remain two observations, even though the store deduplicates their file.

Keep the current read-failure retry behavior. If a capture file is truncated
and its offset resets, reset that stream's decoder too. Finalize a partial
frame only when the stream is finished, including cancellation; return a short
diagnostic for an unfinished image without dumping the payload. `bash_stop`
also drains output and must preserve completed images from that drain.

For malformed base64, invalid PNG, excessive size, or storage failure, consume
the offending frame and return a bounded diagnostic. Resume subsequent normal
output and valid frames. Unsupported OSC commands should retain the existing
terminal handling. Do not insert raw image payloads into text truncation,
archival, or model context.

Use ImageIO properties to check dimensions before creating a full decoded
image, then validate the image. Store the encoded PNG as received; no image
reencoding is needed for transport. Return its digest only after storage
succeeds, so history can resolve the image after capture files are removed.

## Remote model delivery

The remote bridge already handles images specially for `read`, using
`RemoteImage` and `RemoteToolExecutionResult.images`. Its general tool response
loop currently iterates only over `.text` parts. A bash image would therefore
be lost there even if local model delivery worked.

Resolve `.imageDigest` through the project's image store, create `RemoteImage`
values, and pass them through the existing remote result image field when
`supportsImageInput` is true. Preserve text and image order as far as the
provider's result representation permits. For a model without image input,
return a clear text note that the image was captured but could not be supplied
to that model; keep the stored artifact accessible.

Local delivery can be the first checkpoint. Mark remote delivery complete only
after verifying the bridge and provider request; rendering an image in the chat
alone does not prove that a remote model received it.

## Implementation sequence

1. Implement the byte decoder and its boundary tests using a PNG fixture.
2. Integrate per-stream state into `BashJob`, preserving peek, poll, stop, and
   terminal text behavior. Store images and construct multipart responses.
3. Update the four bash completions and registry dispatch. Check transcript
   serialization and the existing chat and local model image path.
4. Forward stored images through the remote bridge and verify an image-capable
   provider configuration if remote support is included in the first patch.
5. Run the emitter through the app and verify that the model can identify
   information visible only in the fixture image without calling `view`.

Check [BUILD](../BUILD) source lists and dependencies. The app source glob can
pick up a decoder file, but `BashUserInteractionTests`, `LocalCodeCLILib`, and
`AgentSchedulerHarness` explicitly list `BashTools.swift`; a new shared file
must be included wherever it is used. Check any applicable
[SwiftPM](../../../Package.swift) source coverage as well.

## Verification

Add meaningful coverage alongside
[BashUserInteractionTests](../Tests/BashUserInteractionTests/BashUserInteractionTests.swift):

| Case | Expected result |
| --- | --- |
| Valid PNG with BEL and ST | One stored image for each complete frame; no escape sequence or base64 in text. |
| Splits at every byte boundary | Header, payload, and ST survive arbitrary reads and polls. Split UTF-8 text remains intact. |
| Text, image, text and multiple images | Parts retain order within each stream, including separately emitted identical images. |
| Running command and repeated status or wait | An image appears once when its complete frame is consumed; later empty polls do not repeat it. |
| Peek followed by consumption | Peeking does not advance the real stream decoder or offsets. |
| Stop or cancellation | Completed images survive the final drain; incomplete images produce a bounded diagnostic. Existing stop behavior remains correct. |
| Separate jobs and streams | Partial frames never share decoder state across jobs or stdout and stderr. |
| Malformed, oversized, and truncated frames | Buffering remains bounded, payload stays out of text, and later valid output resumes. |
| Plain text, ANSI, carriage return, backspace, other OSC | Existing terminal rendering and bash diagnostics remain usable. |
| Serialization and capture cleanup | Multipart responses survive history reload and the image resolves from the project store after temporary files are deleted. |
| Local and remote vision input | The model identifies a visible fixture detail. Remote requests retain images through the adapter when image input is supported. |

Run the focused regressions and integration builds appropriate to the patch:

```sh
bazel test //Apps/LocalCode:BashUserInteractionTests --test_output=errors
bazel test //Apps/LocalCode:ToolCallParserTests --test_output=errors
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
bazel build //Apps/LocalCode:LocalCodeCLI
```

The first milestone is complete when the independent emitter works through
ordinary bash, including delivery through a later poll, and an image-capable
model uses the resulting image without a `view` call. Report local and remote
verification separately if only one has been exercised.

## Browser work after the milestone

Browser commands now emit PNGs using the same transport:

```sh
web-browse-cli screenshot
web-browse-cli screenshot --file /tmp/browser.png --inline --full-page
web-browse-cli snapshot --boxes --image
```

`screenshot` defaults to inline output when no file is requested. `--file`
remains available for saved artifacts, and `--inline` combines saving with
display. `snapshot --image` combines accessibility inspection and viewport
capture in the same bash response.

Then return to the browser questions: how to capture a viewport or region, how
to observe the result of scrolling, and how accessibility references and image
coordinates guide actions. The bash transport should remain reusable by any
command that emits an inline PNG.
