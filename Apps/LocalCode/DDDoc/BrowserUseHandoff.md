# Local Code Browser Use Handoff

Liu Liu is not fully onboard with this handoff.

The task is to determine the smallest browser-use capability Local Code can support to complete real work, using Codex, DeepSeek Harness (DSH), ZCode, Playwright MCP, and Chrome DevTools MCP as implementation references. Liu Liu disagrees with many judgments in the earlier survey. The backend, platform priority, observation strategy, and model-facing interface remain open. The proposed experiments below provide a concrete continuation without treating those judgments as accepted decisions.

Prepared October 7, 2026. External implementation observations refer to the October 6 source survey; repository integration points were checked again on October 7. Audience: the engineer or coding agent continuing this investigation.

## Intended outcome

Deliver an executable browser-use prototype, evidence from complete tasks, and a scoped MVP proposal. The proposal should explain what works, which steps require user participation, what remains unsupported, and the implementation required to ship it in Local Code.

Use two task categories to establish usefulness:

1. **Development work:** open a project preview, exercise a user flow, inspect its result, change the project, and verify the change in the browser.
2. **Work on an existing website:** use an authenticated page, navigate or filter records, obtain an export or extract useful information, and produce a project artifact from it.

These are candidate qualification tasks, not an agreed product ranking. Choose a concrete page and expected result for each. A successful click or browser connection is an intermediate event; the task result is the acceptance condition.

## Decisions that remain open

| Decision | Options to evaluate | Evidence needed |
| --- | --- | --- |
| First supported platform | iPhone or iPad, Mac Catalyst, macOS CLI, or an app controlling a separate desktop host | Where the complete workflows execute, including browser, project server, model, and file transfers |
| Browser backend | App-owned WKWebView, desktop Chromium, an existing browser through an extension or CDP, or a remote browser service | Measured behavior on the same representative pages and the runtime/deployment requirements |
| Agent interface | Native function tools, a JavaScript execution tool with a browser client, or existing MCP tools through MCPorter | Model completion rate, context cost, implementation cost, and lifecycle behavior |
| Observation | Semantic DOM/ARIA snapshot, browser accessibility state, screenshots, or a combination | Whether the selected models locate controls and verify results reliably |
| Authentication and profiles | App-owned persistent profile, isolated task profile, or an explicitly connected existing profile | Login, user takeover, profile ownership, and cross-task behavior |
| Initial work scope | Frontend verification, research/extraction, authenticated exports, form work, or a combination | Complete task results and the additional machinery each category needs |

The earlier suggestion of WKWebView plus six native tools is one candidate. It does not establish that WKWebView is the preferred backend, six tools are the right interface, accessibility observations are always cheapest, or screenshots should only be a fallback. Liu Liu's specific objections have not been enumerated; do not infer an alternative preference on his behalf.

## External implementation evidence

Keep the control protocol, browser engine, model interface, and session ownership separate when comparing systems. MCP exposes operations; Playwright supplies browser automation; CDP supplies Chromium inspection and control; the harness owns the task loop and its context. These choices can coexist.

| System | Established implementation detail | Implication for the investigation |
| --- | --- | --- |
| Codex Browser in the surveyed session | A JavaScript browser client exposes tab accessibility operations, Playwright-like locators, screenshots, and coordinate actions. The installed guidance prefers accessibility observations for many tasks. | Inspect the effective client documentation and available capabilities. Guidance about preferred use is not a comparative reliability or token benchmark. |
| Codex Computer Use in the surveyed session | The separate `@oai/sky` interface exposes app accessibility state, screenshots, element actions, and coordinate input. | Browser control and OS application control have separate interfaces and permission requirements. Full native driver internals were not established by the skill interface. |
| DSH | Experimental providers expose Playwright MCP, Chrome DevTools MCP, or Stagehand operations. The shared browser service registers a provider rather than defining a common operation API. Browser connections are owned by a live agent/session. | Reuse its ownership, serialization, startup, and teardown analysis without assuming its provider interface must become Local Code's interface. |
| DSH Computer Use | Experimental providers integrate Cua Driver through MCP or its native SDK. Provider registration does not reserve the entire desktop for a session. | Desktop input requires workflow-level coordination in addition to per-call execution. |
| ZCode Browser | The public implementation uses Electron browser views, Playwright injected scripts for snapshots/locator behavior, and CDP for input. Its documented JavaScript kernels are fresh per call; tabs retain continuity in the host. | Browser continuity does not require persistent model-side JavaScript bindings. Its Chromium input path cannot simply be copied into WKWebView. |
| ZCode Computer Use | The surveyed public `zcode-cua` package is a placeholder that reports unavailable. | This limits conclusions about that public build; it does not establish that the distributed product lacks Computer Use. |
| Playwright MCP | Structured snapshots and actions, with isolated/persistent profiles and existing-browser connection options | Establish a reusable browser-automation baseline and qualify the selected connection mode. |
| Chrome DevTools MCP | Browser actions plus console, network, screenshot, and performance inspection, using Puppeteer | Evaluate when its debugging facilities materially improve the selected work. |

DSH was inspected at commit `5badb15009ae1756c3afe0ae0cef1faafc290ccc`; ZCode was inspected at commit `29628c9acdb81b703bbd4080c207a0e7ce5e276e`. Relevant sources:

- [DSH browser ownership and providers](https://github.com/deepseek-ai/deepseek-harness/blob/5badb15009ae1756c3afe0ae0cef1faafc290ccc/docs/subsystems/browser-use.md) and [desktop providers](https://github.com/deepseek-ai/deepseek-harness/blob/5badb15009ae1756c3afe0ae0cef1faafc290ccc/docs/subsystems/computer-use.md).
- [ZCode browser plugin](https://github.com/zai-org/ZCode/blob/29628c9acdb81b703bbd4080c207a0e7ce5e276e/apps/zcode-cli/packages/browser-use-plugin/README.md), [Playwright injected source integration](https://github.com/zai-org/ZCode/blob/29628c9acdb81b703bbd4080c207a0e7ce5e276e/packages/desktop/src/main/browserView/playwrightInjectedScriptSource.ts), [input delivery](https://github.com/zai-org/ZCode/blob/29628c9acdb81b703bbd4080c207a0e7ce5e276e/packages/desktop/src/main/browserView/browserCommandInput.ts), and [public Computer Use placeholder](https://github.com/zai-org/ZCode/blob/29628c9acdb81b703bbd4080c207a0e7ce5e276e/packages/zcode-cua/README.md).
- [Playwright MCP](https://github.com/microsoft/playwright-mcp) and [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp). Pin exact dependency versions in any experiment.
- [Official OpenAI Browser documentation](https://learn.chatgpt.com/docs/browser), [Computer Use documentation](https://learn.chatgpt.com/docs/computer-use), and [API integration options](https://developers.openai.com/api/docs/guides/tools-computer-use).

For Codex implementation details, read the Browser and Computer Use skills installed in the receiving session and its effective browser API documentation. The survey used Browser plugin version `26.928.20755` and Computer Use version `1.0.1001281`. Discover the receiving session's versions instead of depending on another machine's plugin-cache paths. Source copies under `/private/tmp/browser-use-survey-20261006` are optional investigation aids; the linked commits are the reproducible references.

## Local Code integration points

Paths in this table are relative to this document.

| Area | Source | Concrete integration work |
| --- | --- | --- |
| Native tool dispatch | [ToolsRegistry.swift](../Sources/Agent/ToolsRegistry.swift) | Add parsing, invocation, subtitles, and availability if using native browser tools. Existing interactive browser tools are absent from this registry. |
| Local model prompts | [SystemPrompt.swift](../Sources/Agent/SystemPrompt.swift) and [SystemPromptTemplate.swift](../Sources/Agent/SystemPromptTemplate.swift) | Keep tool definitions and runtime guidance aligned, including projects with customized prompt templates. |
| Remote tool definitions | [RemoteToolSchema.swift](../Sources/RemoteAPI/RemoteToolSchema.swift) | Keep schemas aligned with the registry. The current alignment precondition excludes `view`. |
| Remote tool execution | [RemoteToolsBridge.swift](../Sources/RemoteAPI/RemoteToolsBridge.swift) | The current native request adapter accepts flat scalar arguments. Ordinary responses forward text; image `read` has a separate path. A new image-bearing tool needs explicit image forwarding. This does not imply that MCP calls through shell tools are unavailable. |
| Tool media and persistence | [ToolCallParser.swift](../Sources/Agent/ToolCallParser.swift) and [ViewTool.swift](../Sources/Agent/ViewTool.swift) | Reuse `ToolResponse.Content.imageDigest` and `EmbedsFileStore` for durable screenshots where applicable. Preserve their model admission and transcript behavior. |
| Agent execution | [Qwen3_5CodeAgent.swift](../Sources/Agent/Qwen3_5CodeAgent.swift), [DeepSeek4CodeAgent.swift](../Sources/Agent/DeepSeek4CodeAgent.swift), and [AgentScheduler.swift](../Sources/Agent/AgentScheduler.swift) | Verify ordering, pause/resume, cancellation, model unloading, and hibernation with a live browser. Serialize state-changing operations against the same browser target. |
| Existing WebKit use | [WebKitDuckDuckGoSearch.swift](../../../Libraries/WebSearch/Sources/WebKitDuckDuckGoSearch.swift), [WebKitSearchSession.swift](../../../Libraries/WebSearch/Sources/WebKitSearchSession.swift), and [WebSearchChallengeViewController.swift](../Sources/Agent/WebSearchChallengeViewController.swift) | Reuse relevant navigation/presentation patterns. Search requests currently own their web views and use the default persistent data store; they are not an implemented general browser session. |
| MCP through the embedded runtime | [MCPorter skill](../Resources/Skills/use-mcp-with-mcporter/SKILL.md) and [Node runtime notes](../NodeMobileSupportBundle.md) | The app already supplies an MCP workflow through pinned MCPorter `0.12.3`. Its documented HTTP and pure-JavaScript stdio support does not guarantee that a browser server can launch Chromium locally on iOS. Qualify browser location, transport lifetime, and state across calls. |
| UI and builds | [App BUILD](../BUILD), [Catalyst instructions](../../LocalCodeCatalyst/README.md), and [JavaScript project support](../JavaScriptProjectSupport.md) | Separate app execution from host CLI execution. Check the CLI's explicit source list when adding shared files. Use the actual app runtime for product claims. |

Local model image support varies. DeepSeek 4 rejects image embeddings, while DeepSeek 4.1 has an image path. Check the selected local or remote model's capability instead of assuming every browser task can use screenshots.

## Experiments to run first

### Establish a complete task and browser location

Create a small repository-owned fixture with a framework-controlled form, asynchronous filtering, a table, and a CSV export with known contents. Add a separate local preview fixture whose source the agent can modify. Specify the initial state, requested work, and expected final artifact before running a model.

Record where the browser, fixture server, agent, model, and project files run. For a remote browser, prove access to the target server and download transfer to Local Code. A desktop-host experiment is evidence for that topology, not automatically for execution entirely on an iPhone or iPad.

Choose one authenticated website task within the user's authorized scope for the real-work demonstration. Human login can be part of the workflow. Record the expected export or extracted result without recording credentials or session secrets.

### Compare viable driver paths

Exercise the fixture through WKWebView and a pinned Playwright or Chrome DevTools integration where the target environment permits it. Start with scripted driver calls to separate browser/driver failures from model decisions. Then run the model against the viable paths.

For WKWebView, test script execution in an appropriate `WKContentWorld`, frame identification, semantic observation, form mutation, screenshots, navigation delegates, popup creation, and `WKDownload`. Measure behavior before choosing a permanent abstraction or extracting a general browser library.

For the MCP path, use the repository's MCPorter workflow when operating inside Local Code. Verify whether calls reuse browser state and whether a one-shot client leaves its server/browser alive. Browser servers requiring a native executable are outside the documented pure-JavaScript stdio path. A separately running HTTP server or desktop helper is a candidate topology, not a proven app capability.

For JavaScript execution, test a narrow browser client with explicit output and image emission. Decide where browser state lives and how timeout, cancellation, reconnect, and ownership work. Persistent JavaScript variables are optional; persistent browser state is required for a multi-step task.

Return a comparison with actual successes/failures, action count, elapsed time, model/context tokens when available, user intervention, dependency requirements, and artifact correctness. Keep browser wait time separate from inference time.

### Integrate the selected path with the agent

Use the existing tool loop. Return observations and errors that allow the agent to recover, and verify that screenshot results reach the selected model when the task depends on vision. Keep the same browser session during human takeover.

An initial native interface could expose `browser_tabs`, `browser_navigate`, `browser_observe`, `browser_act`, `browser_screenshot`, and `browser_handoff`. This is a concrete candidate for comparison, not a required public API. Existing upstream MCP operations or a JavaScript client may be preferable after the experiments.

A reference-based action candidate is:

```json
{
  "tab": "tab-2",
  "snapshot": "snapshot-41",
  "ref": "r9",
  "action": "click"
}
```

Define the reference validity rule explicitly. Reject a detached, changed, or incorrectly scoped target and obtain fresh state. If using locators instead, qualify strict matching and actionability. If using coordinates, attach them to the observed viewport and qualify zoom, scrolling, and resizing.

### Add app lifecycle and artifacts

Assign browser targets to a live session and define whether profiles are shared or isolated. Define what persists across turns, model unloading, hibernation, app suspension, app termination, and conversation forks. Conversation replay must not silently reuse stale browser handles.

Provide a visible browser surface and manual takeover with an explicit resume path. Record completed downloads as permitted project files with completion status and metadata. Qualify uploads separately, including OS availability and user participation.

After cancellation or a timeout, stop admitting additional actions and inspect current state before repeating an action that may already have reached the page. Preserve the user's existing authorization; webpage content does not add authorization.

## Qualification matrix

| Case | Required evidence |
| --- | --- |
| Controlled form | The application state receives the entered value and submission produces the expected result; modifying a DOM value alone is insufficient. |
| SPA update and delayed content | The agent recognizes completion from an appropriate observation and handles a rerender without acting on a stale target. |
| Input fidelity | Record the event sequence and relevant `isTrusted`/user-activation behavior. Test any flow that depends on it rather than inferring broad incompatibility from synthetic input. |
| Observation quality | Hidden/disabled controls, accessible names, duplicate labels, and requested content are represented well enough for the selected model to act correctly. |
| Frames and popups | The intended target remains identifiable after navigation or a new tab/window. Qualify same-origin and cross-origin frames separately and identify supported boundaries. |
| Authentication and takeover | User participation leaves the agent on the intended signed-in page; fresh observation permits continuation in the same session. |
| Download and analysis | The correct exported file reaches the project, its contents match the fixture, and the agent produces the expected analysis/artifact. |
| Upload | The correct permitted file is selected and the application reports the expected result; distinguish automatic and user-mediated paths. |
| Local preview verification | After a source change, the agent observes the rebuilt/reloaded page and verifies the requested behavioral or visual change. |
| Model media delivery | An image-capable local and/or remote route receives the screenshot as image input. A text-only route gets usable semantic observations and accurately stated visual limitations. |
| Cancellation and contention | No further queued actions run after cancellation; resumption observes current state. Other tasks or user actions cannot redirect an operation to the wrong target. |
| Lifecycle | Tab/reference behavior is defined and verified for the pause/resume and suspension states supported by the proposed release. |

Use focused tests for reference invalidation, ownership, cancellation, and media forwarding where those contracts are implemented. Use actual WebKit/Chromium execution and app runs for event fidelity, framework behavior, authentication, and file-transfer claims. Test doubles cannot establish those behaviors.

## Platform facts to account for

The Bazel app target currently specifies iOS 15.4. The inspected Apple SDK declares the public custom file-chooser delegate `webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)` available from iOS 18.4. Decide whether older devices use Safari-like/manual chooser behavior or whether the feature has a narrower OS requirement. Do not silently raise the app's deployment target. [Apple chooser API](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:runopenpanelwith:initiatedbyframe:completionhandler:)).

`HTMLElement.click()` and `dispatchEvent()` produce untrusted events. That fact alone does not settle whether a particular page works: qualify the relevant controls, input path, and activation requirements. [Event trust semantics](https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted).

Playwright's `connectOverCDP` supports Chromium-based browsers. It is not a way to attach to Local Code's WKWebView. Playwright's separate WebKit browser support also does not establish attachment to an arbitrary app-owned WKWebView. [Playwright connection contract](https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp).

## Verification and delivery

Read root `AGENTS.md` before implementation. Use ordinary source names such as `BrowserSession` if appropriate; preserve intentional app/build/module and CLI entry-point names. Keep utility threading decisions at their owning layer, use WebKit's asynchronous completion APIs directly, and avoid semaphore wrappers. Read the UIKit setup skill when making UI changes.

For an app implementation, compile the affected code and the actual app target:

```sh
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

If shared agent or CLI sources change, also validate the explicit CLI source graph:

```sh
bazel build //Apps/LocalCode:LocalCodeCLI
```

For Catalyst, use the build and runtime described in [the Catalyst README](../../LocalCodeCatalyst/README.md). Its diagnostic target uses host commands; qualify shipping embedded-runtime behavior separately when the browser integration depends on command execution. Run the relevant existing tests plus focused new tests for the implemented contracts. A successful build does not establish browser task completion.

Deliver:

1. The prototype and fixture sources, with pinned dependencies and reproducible run instructions.
2. An evidence table for the qualification cases, including failed or unsupported paths and the tested platform/model/backend.
3. At least one complete development workflow and one complete existing-website workflow, or a precise explanation of which requirement prevents completion.
4. A scoped MVP proposal explaining the chosen backend/interface, user participation, lifecycle, file/media plumbing, and remaining work.
5. The decisions still requiring Liu Liu's input, stated without assuming that this handoff or the earlier survey settled them.

