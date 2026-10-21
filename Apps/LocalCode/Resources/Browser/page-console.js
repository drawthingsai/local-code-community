// Runs in the page's own world from document start. It forwards console output, uncaught errors,
// and failed resource loads to the host, which keeps them for web-browse-cli console.
// The page's world has no message handler, so window.webkit stays undefined as in Safari.
// Messages go as document events, whose name changes per launch, to a relay in the client's world.
(() => {
  // Captured before page scripts run, which may replace any of these.
  const apply = Reflect.apply;
  const dispatchEvent = EventTarget.prototype.dispatchEvent;
  const originalOf = WeakMap.prototype.get;
  const NativeCustomEvent = CustomEvent;
  const stringify = JSON.stringify;
  const target = document;
  const format = value => {
    if (typeof value === 'string') return value;
    if (value instanceof Error) return value.stack ? `${value}\n${value.stack}` : String(value);
    try {
      return stringify(value) ?? String(value);
    } catch {
      return String(value);
    }
  };
  const post = (level, text, location) => {
    try {
      const message = { level, text: String(text).slice(0, 2000) };
      if (location) message.location = location;
      apply(dispatchEvent, target, [new NativeCustomEvent('__CONSOLE_EVENT__', { detail: stringify(message) })]);
    } catch {}
  };
  // Wrappers report the original's source, name, and length, as Safari's console methods do.
  const nativeToString = Function.prototype.toString;
  const originals = new WeakMap();
  const toString = { toString() { return apply(nativeToString, apply(originalOf, originals, [this]) ?? this, []); } }.toString;
  originals.set(toString, nativeToString);
  Object.defineProperty(Function.prototype, 'toString', { value: toString, writable: true, configurable: true });
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    const original = console[level];
    const wrapper = { [level](...args) {
      post(level, args.map(format).join(' '));
      return apply(original, this, args);
    } }[level];
    originals.set(wrapper, original);
    console[level] = wrapper;
  }
  addEventListener('error', event => {
    if (event.target !== window && event.target instanceof Element) {
      const source = event.target.src || event.target.href || event.target.localName;
      post('error', `Failed to load ${source}`);
    } else {
      post('error', event.error ? format(event.error) : event.message, event.filename ? `${event.filename}:${event.lineno}:${event.colno}` : undefined);
    }
  }, true);
  addEventListener('unhandledrejection', event => post('error', 'Unhandled promise rejection: ' + format(event.reason)));
})();
