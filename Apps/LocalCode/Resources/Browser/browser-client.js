// Browser-side adapter. Selector construction, accessible names, and snapshots
// come from the pinned Playwright InjectedScript; input below uses public DOM APIs.
globalThis.createBrowserClient = function(injected) {
  injected.consoleApi.install();
  const selectors = injected.window.playwright;
  const bridge = globalThis.webkit?.messageHandlers?.browser;
  const documentId = Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('');
  // Observations go into a model's context, so they stop at this many characters unless asked otherwise.
  const defaultMaxChars = 20000;
  let activeRun;
  // The element the pointer is over, so the next move can send it leave/out events.
  let hovered;

  const clip = (text, limit) => text.length > limit ? text.slice(0, limit) + '…' : text;
  const collapse = text => text.replace(/\s+/g, ' ').trim();
  const parentOf = element => element.parentElement ?? element.getRootNode().host ?? null;
  const ancestry = element => { const chain = []; for (let e = element; e; e = parentOf(e)) chain.push(e); return chain; };
  const deepActiveElement = () => {
    let element = document.activeElement;
    while (element?.shadowRoot?.activeElement) element = element.shadowRoot.activeElement;
    return element;
  };
  const elementAt = ({ x, y }) => {
    let element = document.elementFromPoint(x, y);
    while (element?.shadowRoot) {
      const inner = element.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === element) break;
      element = inner;
    }
    return element;
  };
  const textTypes = new Set(['', 'text', 'search', 'email', 'number', 'password', 'tel', 'url']);
  const isEditable = element => !element.disabled && !element.readOnly && (element.isContentEditable ||
    element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement && textTypes.has(element.type));

  // Untrusted events have no browser default actions, so the pointer and keyboard below send the
  // events a person's input would and then perform the common defaults themselves.
  // Pages run on Apple platforms, so ControlOrMeta is Meta (Command).
  const modifierKeys = { Alt: 'altKey', Control: 'ctrlKey', ControlOrMeta: 'metaKey', Meta: 'metaKey', Shift: 'shiftKey' };
  const modifierFlags = modifiers => {
    const flags = {};
    for (const name of modifiers ?? []) {
      if (!modifierKeys[name]) throw new Error(`Unsupported modifier ${name}; use Alt, Control, ControlOrMeta, Meta, or Shift`);
      flags[modifierKeys[name]] = true;
    }
    return flags;
  };
  const pointerInit = (point, flags, extra) => ({
    bubbles: true, cancelable: true, composed: true, view: window,
    clientX: point.x, clientY: point.y, screenX: point.x, screenY: point.y,
    button: 0, buttons: 0, detail: 0, pointerId: 1, pointerType: 'mouse', isPrimary: true, width: 1, height: 1,
    ...flags, ...extra,
  });
  const movePointer = (target, point, flags) => {
    if (hovered !== target) {
      const previous = hovered?.isConnected ? ancestry(hovered) : [];
      const next = ancestry(target);
      const leaving = { ...pointerInit(point, flags), bubbles: false, cancelable: false };
      if (previous.length) {
        previous[0].dispatchEvent(new PointerEvent('pointerout', pointerInit(point, flags)));
        previous[0].dispatchEvent(new MouseEvent('mouseout', pointerInit(point, flags)));
      }
      for (const element of previous.filter(e => !next.includes(e))) {
        element.dispatchEvent(new PointerEvent('pointerleave', leaving));
        element.dispatchEvent(new MouseEvent('mouseleave', leaving));
      }
      target.dispatchEvent(new PointerEvent('pointerover', pointerInit(point, flags)));
      target.dispatchEvent(new MouseEvent('mouseover', pointerInit(point, flags)));
      for (const element of next.filter(e => !previous.includes(e)).reverse()) {
        element.dispatchEvent(new PointerEvent('pointerenter', leaving));
        element.dispatchEvent(new MouseEvent('mouseenter', leaving));
      }
      hovered = target;
    }
    target.dispatchEvent(new PointerEvent('pointermove', pointerInit(point, flags)));
    target.dispatchEvent(new MouseEvent('mousemove', pointerInit(point, flags)));
  };
  // A mouse press focuses the nearest focusable ancestor, or blurs the focused element.
  const focusFrom = hit => {
    for (let element = hit; element; element = parentOf(element)) {
      if (element instanceof HTMLLabelElement) return;
      if (element.isContentEditable && parentOf(element)?.isContentEditable) continue;
      if (!element.disabled && (element.isContentEditable || element.hasAttribute('tabindex') || element.tabIndex >= 0)) {
        if (deepActiveElement() !== element) element.focus({ preventScroll: true });
        return;
      }
    }
    const active = deepActiveElement();
    if (active && active !== document.body) active.blur();
  };
  const insertText = (target, text) => {
    if (document.execCommand('insertText', false, text)) return;
    if (!(target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement)) throw new Error('Text insertion failed');
    try {
      target.setRangeText(text, target.selectionStart, target.selectionEnd, 'end');
    } catch {
      target.value += text;
    }
    target.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
  };
  const moveFocus = (from, step) => {
    const candidates = Array.from(document.querySelectorAll('a[href], area[href], button, input, select, textarea, summary, iframe, [tabindex], [contenteditable]'))
      .filter(e => e.tabIndex >= 0 && !e.disabled && !(e instanceof HTMLInputElement && e.type === 'hidden') && injected.elementState(e, 'visible', true).matches);
    const ordered = [...candidates.filter(e => e.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex), ...candidates.filter(e => e.tabIndex === 0)];
    const index = ordered.indexOf(from);
    const next = ordered[index < 0 ? (step > 0 ? 0 : ordered.length - 1) : index + step];
    if (next) next.focus();
    else from?.blur?.();
  };
  const pressEnter = (target, shiftKey) => {
    if (target instanceof HTMLTextAreaElement) return insertText(target, '\n');
    if (target.isContentEditable) return document.execCommand(shiftKey ? 'insertLineBreak' : 'insertParagraph');
    if (target instanceof HTMLAnchorElement && target.href || target instanceof HTMLButtonElement ||
        target instanceof HTMLInputElement && ['button', 'submit', 'reset', 'image'].includes(target.type)) return target.click();
    const form = target.form;
    if (!(target instanceof HTMLInputElement) || !form) return;
    // Implicit submission clicks the form's default button, or submits a form without one.
    const submitter = Array.from(form.elements).find(e => e.type === 'submit' || e instanceof HTMLInputElement && e.type === 'image');
    if (submitter) {
      if (!submitter.disabled) submitter.click();
    } else {
      form.requestSubmit();
    }
  };
  // Key names follow Playwright's keyboard.press.
  const namedKeys = new Set(['Enter', 'Tab', 'Escape', 'Backspace', 'Delete', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown', 'Space']);
  const scrollKeys = new Set(['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown', 'Space']);
  // Caret keys in editable fields: the direction, then the granularity alone, with Alt or Control,
  // and with Meta. Shift extends the selection; Home and End stay within the line.
  const caretMoves = {
    ArrowLeft: ['backward', 'character', 'word', 'lineboundary'],
    ArrowRight: ['forward', 'character', 'word', 'lineboundary'],
    ArrowUp: ['backward', 'line', 'paragraphboundary', 'documentboundary'],
    ArrowDown: ['forward', 'line', 'paragraphboundary', 'documentboundary'],
    Home: ['backward', 'lineboundary', 'documentboundary', 'documentboundary'],
    End: ['forward', 'lineboundary', 'documentboundary', 'documentboundary'],
  };
  // Scrolls the nearest ancestor that scrolls along the key's axis, or the page, by WebKit's
  // steps: 40 CSS pixels for an arrow, 87.5% of the visible size for a page.
  const scrollByKey = (target, key, flags) => {
    const vertical = key !== 'ArrowLeft' && key !== 'ArrowRight';
    const isPage = element => !element || element === document.body || element === document.documentElement;
    let scroller = target;
    for (; !isPage(scroller); scroller = parentOf(scroller)) {
      const style = getComputedStyle(scroller);
      if (/auto|scroll|overlay/.test(vertical ? style.overflowY : style.overflowX) &&
          (vertical ? scroller.scrollHeight > scroller.clientHeight : scroller.scrollWidth > scroller.clientWidth)) break;
    }
    if (isPage(scroller)) scroller = document.scrollingElement ?? document.documentElement;
    const visible = vertical ? Math.min(scroller.clientHeight, innerHeight) : Math.min(scroller.clientWidth, innerWidth);
    const toEdge = key === 'Home' || key === 'End' || flags.metaKey && key.startsWith('Arrow');
    const distance = toEdge ? (vertical ? scroller.scrollHeight : scroller.scrollWidth) :
      key.startsWith('Arrow') && !flags.altKey ? 40 : Math.max(visible * 0.875, 40);
    const backward = ['ArrowUp', 'ArrowLeft', 'Home', 'PageUp'].includes(key) || key === 'Space' && flags.shiftKey;
    scroller.scrollBy({ [vertical ? 'top' : 'left']: backward ? -distance : distance, behavior: 'instant' });
  };
  // keyCode and which for listeners written before key and code, on a US layout.
  const legacyKeyCodes = {
    Backspace: 8, Tab: 9, Enter: 13, Escape: 27, ' ': 32, PageUp: 33, PageDown: 34, End: 35, Home: 36,
    ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Delete: 46,
    ')': 48, '!': 49, '@': 50, '#': 51, '$': 52, '%': 53, '^': 54, '&': 55, '*': 56, '(': 57,
    ';': 186, ':': 186, '=': 187, '+': 187, ',': 188, '<': 188, '-': 189, '_': 189, '.': 190, '>': 190,
    '/': 191, '?': 191, '`': 192, '~': 192, '[': 219, '{': 219, '\\': 220, '|': 220, ']': 221, '}': 221,
    "'": 222, '"': 222,
  };
  const legacyKeyCode = value => /^[a-z0-9]$/i.test(value) ? value.toUpperCase().charCodeAt(0) : legacyKeyCodes[value] ?? 0;
  // Sends a key's events, then performs the default the page did not prevent. A default this
  // client cannot perform is an error, so a successful press means the edit or move happened.
  const pressKey = (target, combination) => {
    const key = combination === '+' || combination.endsWith('++') ? '+' : combination.split('+').pop();
    const flags = modifierFlags(combination.slice(0, combination.length - key.length).split('+').filter(Boolean));
    if (!namedKeys.has(key) && [...key].length !== 1) throw new Error(`Unsupported key ${key}`);
    const character = key === 'Space' ? ' ' : namedKeys.has(key) ? undefined : key;
    const value = character ?? key;
    const code = character === ' ' ? 'Space' : /^[a-z]$/i.test(value) ? 'Key' + value.toUpperCase() : /^[0-9]$/.test(value) ? 'Digit' + value : character === undefined ? key : '';
    const keyCode = legacyKeyCode(value);
    const init = { key: value, code, keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true, view: window, ...flags };
    // keypress carries the character's code instead.
    const charCode = key === 'Enter' ? 13 : character?.codePointAt(0) ?? 0;
    const pressInit = { ...init, keyCode: charCode, which: charCode, charCode };
    const primary = flags.ctrlKey || flags.metaKey;
    // Control and Meta both take the editing shortcuts, so scripts written for any platform work.
    const shortcut = primary && !flags.altKey && /^[a-z]$/i.test(key) ? key.toLowerCase() : undefined;
    const editable = isEditable(target);
    let activate = false;
    let unsupported;
    if (target.dispatchEvent(new KeyboardEvent('keydown', init))) {
      if (shortcut === 'a') {
        document.execCommand('selectAll');
      } else if (shortcut === 'z' || shortcut === 'y') {
        // WebKit keeps edits in the host's undo manager, which can be empty or absent.
        const command = shortcut === 'y' || flags.shiftKey ? 'redo' : 'undo';
        if (!document.execCommand(command)) unsupported = `WebKit had no edit to ${command}`;
      } else if (shortcut && 'cxv'.includes(shortcut)) {
        unsupported = 'this client has no clipboard; read text with innerText or inputValue and enter it with fill or insertText';
      } else if (shortcut && 'biu'.includes(shortcut) && target.isContentEditable) {
        document.execCommand({ b: 'bold', i: 'italic', u: 'underline' }[shortcut]);
      } else if (target instanceof HTMLSelectElement && (scrollKeys.has(key) || character === ' ') ||
          target instanceof HTMLInputElement && target.type === 'radio' && key.startsWith('Arrow')) {
        unsupported = 'keys do not change select elements or radio groups here; use selectOption or check';
      } else if (character !== undefined || key === 'Enter') {
        if (flags.altKey && !primary && editable && character !== undefined) {
          unsupported = 'Alt does not compose characters here; type the character itself';
        } else if (!primary && !flags.altKey && target.dispatchEvent(new KeyboardEvent('keypress', pressInit))) {
          if (key === 'Enter') pressEnter(target, flags.shiftKey);
          else if (editable) insertText(target, character);
          else if (character === ' ' && (target instanceof HTMLButtonElement || target instanceof HTMLInputElement && ['button', 'submit', 'reset', 'checkbox', 'radio'].includes(target.type))) activate = true;
          else if (character === ' ') scrollByKey(target, 'Space', flags);
        }
      } else if (target instanceof HTMLInputElement && (target.type === 'number' ? key === 'ArrowUp' || key === 'ArrowDown' : target.type === 'range' && key.startsWith('Arrow'))) {
        const before = target.value;
        if (key === 'ArrowUp' || key === 'ArrowRight') target.stepUp();
        else target.stepDown();
        if (target.value !== before) {
          target.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
          target.dispatchEvent(new Event('change', { bubbles: true }));
        }
      } else if (editable && caretMoves[key]) {
        const [direction, ...granularities] = caretMoves[key];
        getSelection().modify(flags.shiftKey ? 'extend' : 'move', direction, granularities[flags.metaKey ? 2 : flags.altKey || flags.ctrlKey ? 1 : 0]);
      } else if (scrollKeys.has(key)) {
        scrollByKey(target, key, flags);
      } else if ((key === 'Backspace' || key === 'Delete') && editable) {
        const backward = key === 'Backspace';
        // With nothing selected, Alt or Control deletes a word and Meta the rest of the line.
        const collapsed = 'selectionStart' in target ? target.selectionStart === target.selectionEnd : getSelection().isCollapsed;
        if ((flags.altKey || primary) && collapsed) getSelection().modify('extend', backward ? 'backward' : 'forward', flags.metaKey ? 'lineboundary' : 'word');
        document.execCommand(backward ? 'delete' : 'forwardDelete');
      } else if (key === 'Tab' && !primary && !flags.altKey) {
        moveFocus(target, flags.shiftKey ? -1 : 1);
      }
    }
    target.dispatchEvent(new KeyboardEvent('keyup', init));
    if (activate) target.click();
    if (unsupported) throw new Error(`${combination} reached the page as key events, but ${unsupported}`);
  };
  const keyTarget = fallback => {
    const active = deepActiveElement();
    return active && active !== document.body ? active : fallback ?? document.body;
  };

  const makeTab = (request, tabId) => {
    const checkRun = () => {
      if (request.cancelled) throw new Error('Browser request cancelled');
      if (request.finished) throw new Error('Browser request is no longer active');
      if (Date.now() >= request.deadline) throw new Error('Browser request timed out');
    };
    const pause = () => new Promise(resolve => setTimeout(resolve, 40));
    const snapshotOptions = options => ({ mode: 'ai', depth: options?.depth, boxes: options?.boxes ?? false });
    const state = (element, name) => injected.elementState(element, name, true).matches;
    const info = element => {
      const rect = element.getBoundingClientRect();
      return {
        tag: element.localName, role: injected.utils.getAriaRole(element),
        name: injected.utils.getElementAccessibleNameText(element, false),
        text: clip(element.innerText ?? element.textContent ?? '', 2000),
        value: 'value' in element ? element.value : null,
        visible: state(element, 'visible'), enabled: state(element, 'enabled'),
        attributes: Object.fromEntries(Array.from(element.attributes, a => [a.name, clip(a.value, 500)])),
        box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      };
    };
    // The compact form of info for dom, which lists every visible node.
    const domAttributes = ['id', 'name', 'type', 'href', 'placeholder', 'title', 'alt', 'for', 'data-testid', 'aria-label', 'aria-expanded', 'aria-checked', 'aria-selected', 'aria-pressed', 'aria-disabled', 'aria-haspopup'];
    const summary = element => {
      const rect = element.getBoundingClientRect();
      const node = { tag: element.localName, role: injected.utils.getAriaRole(element), name: clip(injected.utils.getElementAccessibleNameText(element, false), 200) };
      const text = collapse(element.innerText ?? element.textContent ?? '');
      if (text && text !== node.name) node.text = clip(text, 120);
      if (typeof element.value === 'string' && element.value && 'labels' in element) node.value = clip(element.value, 200);
      if (!state(element, 'enabled')) node.enabled = false;
      const attributes = Object.fromEntries(domAttributes.filter(name => element.hasAttribute(name)).map(name => [name, clip(element.getAttribute(name), 200)]));
      if (Object.keys(attributes).length) node.attributes = attributes;
      node.box = { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) };
      return node;
    };
    const budgetHint = 'raise maxChars (--max-chars), lower depth (--depth), or snapshot a region with locator(...).ariaSnapshot()';
    const boundText = (text, maxChars) => {
      if (text.length <= maxChars) return text;
      let end = text.lastIndexOf('\n', maxChars);
      if (end <= 0) end = maxChars;
      request.notes.push(`Snapshot truncated to ${end} of ${text.length} characters; ${budgetHint}.`);
      return text.slice(0, end);
    };
    const boundTree = (nodes, maxChars) => {
      let size = 0, omitted = 0;
      const count = node => typeof node === 'string' ? 1 : 1 + (node.children ?? []).reduce((sum, child) => sum + count(child), 0);
      const visit = list => {
        const kept = [];
        for (const node of list) {
          const { children, ...fields } = typeof node === 'string' ? {} : node;
          const own = typeof node === 'string' ? node : fields;
          const length = JSON.stringify(own).length + 1;
          if (size + length > maxChars) {
            omitted += count(node);
            continue;
          }
          size += length;
          kept.push(children ? { ...own, children: visit(children) } : own);
        }
        return kept;
      };
      const kept = visit(nodes);
      if (omitted) request.notes.push(`Snapshot omitted ${omitted} nodes beyond ${maxChars} characters; ${budgetHint}.`);
      return kept;
    };
    const resolveOptions = options => {
      if (!options) return options;
      return { ...options, has: options.has?.builder(), hasNot: options.hasNot?.builder() };
    };

    class Locator {
      constructor(builder) { this.builder = builder; }
      matches() { checkRun(); return this.builder().elements ?? []; }
      async element(options = {}, states = []) {
        const deadline = Math.min(request.deadline, Date.now() + (options.timeout ?? 5000));
        while (true) {
          const elements = this.matches();
          if (elements.length > 1) throw new Error(`Strict locator matched ${elements.length} elements; refine it or use nth()`);
          const element = elements[0];
          if (element?.isConnected && states.every(name => state(element, name))) return element;
          if (Date.now() >= deadline) throw new Error(`Locator timed out waiting for one attached element${states.length ? ' that is ' + states.join(', ') : ''}`);
          await pause();
        }
      }
      // Scrolls the element into view and finds the element a pointer at its center would hit.
      async pointerTarget(options, states) {
        const element = await this.element(options, options.force ? [] : states);
        element.scrollIntoView({ block: 'center', inline: 'center' });
        const rect = element.getBoundingClientRect();
        const point = options.position ? { x: rect.x + options.position.x, y: rect.y + options.position.y } : { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
        if (!options.force) {
          const hit = injected.expectHitTarget(point, element);
          if (hit !== 'done') throw new Error(`Element is obscured by ${hit.hitTargetDescription}; inspect the page before retrying`);
        }
        checkRun();
        const hit = options.force ? element : elementAt(point) ?? element;
        return { element, point, hit };
      }
      locator(selector, options) { return new Locator(() => this.builder().locator(selector, resolveOptions(options))); }
      filter(options) { return new Locator(() => this.builder().filter(resolveOptions(options))); }
      first() { return this.nth(0); }
      last() { return this.nth(-1); }
      nth(index) { return new Locator(() => this.builder().nth(index)); }
      and(other) { return new Locator(() => this.builder().and(other.builder())); }
      or(other) { return new Locator(() => this.builder().or(other.builder())); }
      async count() { return this.matches().length; }
      async all() { return this.matches().map((_, index) => this.nth(index)); }
      async allTextContents() { return this.matches().map(e => e.textContent ?? ''); }
      async innerText(options) { return (await this.element(options)).innerText; }
      async textContent(options) { return (await this.element(options)).textContent; }
      async getAttribute(name, options) { return (await this.element(options)).getAttribute(name); }
      async inputValue(options) { return (await this.element(options)).value; }
      async isVisible() { const elements = this.matches(); if (elements.length > 1) throw new Error('Strict locator matched multiple elements'); return !!elements[0] && state(elements[0], 'visible'); }
      async isEnabled(options) { return state(await this.element(options), 'enabled'); }
      async elementInfo(options) { return info(await this.element(options)); }
      async boundingBox(options) { const element = await this.element(options); return state(element, 'visible') ? info(element).box : null; }
      async ariaSnapshot(options = {}) { return boundText(injected.ariaSnapshot(await this.element(options), snapshotOptions(options)), options.maxChars ?? defaultMaxChars); }
      async evaluate(fn, arg, options) { return await fn(await this.element(options), arg); }
      async evaluateAll(fn, arg) { return await fn(this.matches(), arg); }
      async waitFor(options = {}) {
        const wanted = options.state ?? 'visible';
        if (!['visible', 'hidden', 'attached', 'detached'].includes(wanted)) throw new Error('Unsupported wait state');
        const deadline = Math.min(request.deadline, Date.now() + (options.timeout ?? 5000));
        while (true) {
          const elements = this.matches();
          if (elements.length > 1) throw new Error('Strict locator matched multiple elements');
          const element = elements[0];
          if (wanted === 'attached' && element?.isConnected || wanted === 'detached' && !element?.isConnected ||
              wanted === 'visible' && element?.isConnected && state(element, 'visible') ||
              wanted === 'hidden' && (!element?.isConnected || !state(element, 'visible'))) return;
          if (Date.now() >= deadline) throw new Error(`Locator timed out waiting for ${wanted}`);
          await pause();
        }
      }
      async scrollIntoViewIfNeeded(options) { (await this.element(options, ['visible'])).scrollIntoView({ block: 'center', inline: 'center' }); }
      async hover(options = {}) {
        const { point, hit } = await this.pointerTarget(options, ['visible']);
        movePointer(hit, point, modifierFlags(options.modifiers));
      }
      async click(options = {}) {
        if (options.button && options.button !== 'left') throw new Error('This DOM adapter supports the left button');
        const { element, point, hit } = await this.pointerTarget(options, ['visible', 'enabled']);
        const flags = modifierFlags(options.modifiers);
        movePointer(hit, point, flags);
        // Cancelling pointerdown suppresses the mouse compatibility events but not the click.
        const pointerDown = hit.dispatchEvent(new PointerEvent('pointerdown', pointerInit(point, flags, { buttons: 1, pressure: 0.5 })));
        if (pointerDown && hit.dispatchEvent(new MouseEvent('mousedown', pointerInit(point, flags, { buttons: 1, detail: 1 })))) focusFrom(hit);
        hit.dispatchEvent(new PointerEvent('pointerup', pointerInit(point, flags)));
        if (pointerDown) hit.dispatchEvent(new MouseEvent('mouseup', pointerInit(point, flags, { detail: 1 })));
        // A dispatched click still runs activation: links navigate, labels and checkboxes toggle.
        const target = hit.isConnected ? hit : element;
        if (target.isConnected) target.dispatchEvent(new MouseEvent('click', pointerInit(point, flags, { detail: 1 })));
      }
      async focus(options) {
        const element = await this.element(options);
        checkRun();
        element.focus();
      }
      async blur(options) {
        const element = await this.element(options);
        checkRun();
        element.blur();
      }
      async press(key, options = {}) {
        const element = await this.element(options);
        checkRun();
        if (deepActiveElement() !== element) element.focus();
        pressKey(keyTarget(element), key);
      }
      async pressSequentially(text, options = {}) {
        const element = await this.element(options, ['visible', 'enabled']);
        if (deepActiveElement() !== element) element.focus();
        for (const character of text) {
          checkRun();
          pressKey(keyTarget(element), character === '\n' ? 'Enter' : character);
          if (options.delay) await new Promise(resolve => setTimeout(resolve, options.delay));
        }
      }
      async fill(value, options = {}) {
        if (typeof value !== 'string') throw new Error('fill expects a string');
        const element = await this.element(options, ['visible', 'enabled', 'editable']);
        checkRun();
        const result = injected.fill(element, value);
        if (result === 'done') return;
        if (result !== 'needsinput') throw new Error(`Playwright fill failed: ${result}`);
        // Playwright selected the current text. Replacing it through the editor sends
        // beforeinput and input the way typing does, so framework listeners see the change.
        const target = injected.retarget(element, 'follow-label');
        const typed = value ? document.execCommand('insertText', false, value) : document.execCommand('delete');
        if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
          if (!typed) {
            target.value = value;
            target.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText', data: value }));
          }
          target.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (!typed) {
          throw new Error('Contenteditable insertion failed');
        }
      }
      async setChecked(checked, options = {}) {
        const element = await this.element(options, ['visible', 'enabled']);
        if (state(element, checked ? 'checked' : 'unchecked')) return;
        await this.click(options);
        if (!state(element, checked ? 'checked' : 'unchecked')) throw new Error('Click did not change the checked state');
      }
      check(options) { return this.setChecked(true, options); }
      uncheck(options) { return this.setChecked(false, options); }
      async selectOption(value, options = {}) {
        const element = await this.element(options, ['visible', 'enabled']);
        checkRun();
        const values = (Array.isArray(value) ? value : [value]).map(v => typeof v === 'string' ? { value: v } : v);
        const result = injected.selectOptions(element, values);
        if (!Array.isArray(result)) throw new Error(`Playwright selectOption failed: ${result}`);
        return result;
      }
    }
    for (const method of ['getByRole', 'getByLabel', 'getByText', 'getByPlaceholder', 'getByTestId', 'getByAltText', 'getByTitle']) {
      Locator.prototype[method] = function(...args) { return new Locator(() => this.builder()[method](...args)); };
    }
    const root = () => document.body || document.documentElement;
    const playwright = {
      locator: (selector, options) => new Locator(() => selectors.locator(selector, resolveOptions(options))),
      domSnapshot: async (options = {}) => { checkRun(); return boundText(injected.ariaSnapshot(root(), snapshotOptions(options)), options.maxChars ?? defaultMaxChars); },
      snapshotJSON: async (options = {}) => { checkRun(); return boundTree(injected.ariaSnapshotJSON(root(), snapshotOptions(options)).json, options.maxChars ?? defaultMaxChars); },
      elementInfo: async selector => await playwright.locator(selector).elementInfo(),
      // Runs here, in the client's isolated world: the DOM is shared, page globals are not.
      evaluate: async (fn, arg) => { checkRun(); return await fn(arg); },
      keyboard: {
        press: async key => { checkRun(); pressKey(keyTarget(), key); },
        type: async (text, options = {}) => {
          for (const character of text) {
            checkRun();
            pressKey(keyTarget(), character === '\n' ? 'Enter' : character);
            if (options.delay) await new Promise(resolve => setTimeout(resolve, options.delay));
          }
        },
        insertText: async text => { checkRun(); insertText(keyTarget(), text); },
      },
    };
    for (const method of ['getByRole', 'getByLabel', 'getByText', 'getByPlaceholder', 'getByTestId', 'getByAltText', 'getByTitle'])
      playwright[method] = (...args) => new Locator(() => selectors[method](...args));
    const nodeLocator = nodeId => {
      if (typeof nodeId !== 'string' || !nodeId.startsWith(documentId + ':')) throw new Error('Stale DOM node: capture the current document again');
      return playwright.locator('aria-ref=' + nodeId.slice(documentId.length + 1));
    };
    // Like Playwright's page.evaluate: the function is serialized and runs in the page's own
    // world, so it sees page globals; arguments and results must be JSON-like values.
    const page = {
      evaluate: async (fn, arg) => {
        checkRun();
        if (!bridge) throw new Error('Page evaluation is unavailable in this host');
        const value = await bridge.postMessage({ source: String(fn), isFunction: typeof fn === 'function', args: arg === undefined ? [] : [arg] });
        checkRun();
        return value;
      },
    };
    const tab = {
      id: tabId,
      playwright,
      page,
      url: async () => location.href,
      title: async () => document.title,
      dom_cua: {
        get_visible_dom: async (options = {}) => {
          checkRun();
          const maxChars = options.maxChars ?? defaultMaxChars;
          const tree = injected.ariaSnapshotJSON(root(), { mode: 'ai', boxes: true }).json;
          const nodes = [];
          let size = 0, omitted = 0;
          const visit = list => { for (const node of list) {
            // Unnamed generic containers repeat their children's text; list them only when clickable.
            const listed = node.ref && (!['generic', 'none', 'presentation'].includes(node.role) || node.name || node.cursor === 'pointer');
            const element = listed && injected.querySelector(injected.parseSelector('aria-ref=' + node.ref), document, true);
            if (element) {
              const entry = { node_id: documentId + ':' + node.ref, ...summary(element) };
              const box = entry.box;
              if (box.width > 0 && box.height > 0 && box.x < innerWidth && box.y < innerHeight && box.x + box.width > 0 && box.y + box.height > 0) {
                const length = JSON.stringify(entry).length + 1;
                if (size + length > maxChars) omitted++;
                else { size += length; nodes.push(entry); }
              }
            }
            if (node.children) visit(node.children.filter(child => typeof child === 'object'));
          } };
          visit(tree);
          if (omitted) request.notes.push(`dom listed ${nodes.length} of ${nodes.length + omitted} visible nodes within ${maxChars} characters; raise maxChars (--max-chars) or use a locator for a region.`);
          return { documentId, viewport: { width: innerWidth, height: innerHeight }, nodes };
        },
        click: async ({ node_id }) => await nodeLocator(node_id).click(),
        scroll: async ({ node_id, x = 0, y = 0 }) => {
          checkRun();
          if (node_id) (await nodeLocator(node_id).element()).scrollBy(x, y);
          else window.scrollBy(x, y);
        },
      },
    };
    return tab;
  };
  return {
    cancel: id => {
      if (activeRun?.id !== id) return;
      activeRun.cancelled = true;
      activeRun.abort(new Error('Browser request cancelled'));
      activeRun = undefined;
    },
    run: async (id, timeout, script, tabId) => {
      if (activeRun) throw new Error('Another browser request is active');
      const request = { id, deadline: Date.now() + timeout, cancelled: false, finished: false, notes: [] };
      // Settles the run on cancellation or timeout even while the script awaits something else.
      const aborted = new Promise((_, reject) => { request.abort = reject; });
      aborted.catch(() => {});
      const timer = setTimeout(() => request.abort(new Error('Browser request timed out')), timeout);
      activeRun = request;
      try {
        const fn = new Function('return (' + script + ')')();
        if (typeof fn !== 'function') throw new Error('run expects a function, for example async (tab) => await tab.playwright.domSnapshot()');
        const result = await Promise.race([fn(makeTab(request, tabId)), aborted]);
        if (request.cancelled) throw new Error('Browser request cancelled');
        if (Date.now() >= request.deadline) throw new Error('Browser request timed out');
        // Form submissions and location changes start their navigation in a later task. Waiting
        // one task lets the host see that navigation before this reply, so it reports the new page.
        await new Promise(resolve => setTimeout(resolve, 0));
        const output = { result: result ?? null, tab: tabId, documentId, url: location.href, title: document.title };
        if (request.notes.length) output.notes = request.notes;
        return JSON.stringify(output);
      } finally {
        clearTimeout(timer);
        request.finished = true;
        if (activeRun === request) activeRun = undefined;
      }
    },
  };
};
