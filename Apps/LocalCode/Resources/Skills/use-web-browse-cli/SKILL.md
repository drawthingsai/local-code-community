---
name: use-web-browse-cli
description: Drive a WebKit browser with web-browse-cli. Open websites or local HTML, click, type, and fill forms, read the accessibility tree, DOM, and console, and capture screenshots. Use to test or visually check web pages being built, or for sites that need JavaScript, interaction, or a sign-in. To find or read a page's text, WebSearch and WebFetch are faster.
---

# Use the browser through web-browse-cli

Run `web-browse-cli` with the bash tool. Its tabs stay open between commands in this chat.
`web-browse-cli --help` lists the commands and `web-browse-cli help <command>` shows a
command's options. If it reports that browser commands require an app chat, the current
environment has no browser; tell the user instead of retrying.

## Work in a loop

```sh
web-browse-cli open localhost:5173
web-browse-cli snapshot
web-browse-cli run --code 'async tab => { await tab.playwright.getByLabel("Search").fill("lamps"); await tab.playwright.getByRole("button", {name: "Search"}).click(); }'
web-browse-cli snapshot
```

1. `open` a URL, a bare host such as `localhost:5173` or `example.com`, or a local HTML file.
2. Observe with `snapshot`. Add `--image` when how the page looks matters.
3. Act with `run`, building locators from the roles, names, and text the snapshot shows.
4. Observe again before the next step: actions change the page. When a click loads a new
   page, the command waits for it and its output gives the new `url` and `title`.

## Tabs and the user

`open` creates and selects a tab, `goto <url>` navigates the selected tab, `tabs` lists
them, and `close` closes the selected one. `--tab <id>` addresses another tab and selects
it; `tabs --tab <id>` switches tabs without acting on a page. A window the page opens becomes the selected tab and is listed under `openedTabs`; when
the page closes it, its opener is selected again.

`reload` loads the selected tab again. When a page shows stale content, `reload --from-origin`
fetches the page and its scripts, styles, and images from their servers instead of the cache.
`clear-cache` empties the cache for every tab and keeps cookies and sign-ins; tabs that are
already open show fresh content once they reload.

`show` presents the live tab to the user. Use it when they need to sign in, solve a
CAPTCHA, choose a file, or see what you found; the tab keeps their changes after they close
it. Tabs belong to this chat and last while the app runs; cookies and the cache are shared by
this project's chats and kept between launches.

## Observe

`snapshot` prints the accessibility tree with `[ref=e5]` references; `--json` gives
structured nodes, `--boxes` adds bounds, and `--depth <n>` limits depth.
`locator("aria-ref=e5")` targets a ref from the latest snapshot when no role or name fits.
`dom` lists visible elements with bounds and `node_id`s. Both stop at 20000 characters and
say so under `notes`: raise `--max-chars`, lower `--depth`, or read one region with
`locator(...).ariaSnapshot()`. `console` returns console output, uncaught errors, failed
loads, and dialogs; `--clear` empties it after reading.

## Act with scripts

`run --code` takes an `async tab => …` function; its return value appears under `result`
in the JSON output. Save longer scripts in the selected project and pass `run --file <script.js>`.

```js
async tab => {
  const pw = tab.playwright;
  await pw.getByLabel("Email").fill("ada@example.com");
  await pw.getByRole("checkbox", { name: "Remember me" }).check();
  await pw.getByRole("button", { name: "Continue", exact: true }).click();
  await pw.getByRole("heading", { name: "Welcome" }).waitFor();
  return await pw.getByRole("status").innerText();
}
```

Locators follow Playwright: `getByRole`, `getByLabel`, `getByText`, `getByPlaceholder`,
`getByTestId`, and `locator`, narrowed with `filter`, `nth`, `first`, or `last`. They act
with `click`, `hover`, `fill`, `press`, `pressSequentially`, `check`, `uncheck`,
`selectOption`, and `waitFor`, and read with `innerText`, `inputValue`, `getAttribute`,
`isVisible`, `count`, and `ariaSnapshot`. `tab.playwright.keyboard.press` presses a key on
the focused element. An action waits up to 5 seconds for its element (`{timeout: ms}`
changes that), and a command ends after 30 seconds, so split long flows across commands.

Keys behave as in a browser: in fields, arrows, Home, and End move the caret (Shift
selects, Alt or Control by word, Meta to the edge), Backspace and Delete edit, and Control
or Meta with A selects all; elsewhere, navigation keys scroll. A key the client cannot
carry out, such as copy or paste, fails after the page receives it.

`tab.playwright.evaluate(fn)` sees the DOM but not the page's JavaScript globals.
`tab.page.evaluate(fn, arg)` runs in the page's own world, like Playwright's
`page.evaluate`, so it can read application state; its argument and result must be
JSON-like. `tab.dom_cua.click({node_id})` and `scroll({node_id?, x?, y?})` act on `dom`
results.

## See the page

`screenshot` returns the viewport as a PNG in the bash response, one pixel per CSS pixel,
so `--boxes` coordinates map onto it; `--full-page` captures the whole document. A running
job delivers the image through `bash_wait` or `bash_status`. `--file <path.png>` saves the
PNG instead, and `--inline` with it also shows it. Models without image input receive text
only.

## When something does not work

Common errors and what to do:

- `Strict locator matched N elements`: add `exact: true`, a name, `filter`, or `nth()`.
- `Locator timed out waiting for…`: the element is missing, hidden, or disabled; observe
  again.
- `Element is obscured by…`: dismiss the dialog, banner, or overlay that covers it.
- `The page navigated before the script finished`: the steps after the navigation did not
  run. End a script with the action that navigates.
- `Browser request timed out`: check the page before repeating an action that may have run.
- The web process ended: run the `goto` command the error gives.

Input is synthetic, so some pages need another route:

| You see | Do this |
| --- | --- |
| An action guarded by `confirm()` does nothing; `console` shows `confirm (dismissed)` | Dialogs are dismissed automatically. If the user asked for that action, run `await tab.page.evaluate(() => { window.confirm = () => true; })` before the click; replace `prompt` the same way. |
| A menu that opens on hover stays closed | CSS `:hover` never matches scripted pointers. Click its trigger, or read the item's `href` and `goto` it. |
| The snapshot shows `iframe [ref=…]` with nothing inside | Locators do not enter frames. Read the frame's `src` and `open` it. |
| A file input, drag and drop, or a control that ignores scripted clicks and typing | `show` the tab and ask the user to do that step. |
