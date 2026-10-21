import { createInterface } from "node:readline";
let nextId = 0;
const pending = new Map();
const input = createInterface({ input: process.stdin });
input.on("line", (line) => {
  const message = JSON.parse(line);
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  message.error
    ? request.reject(new Error(message.error))
    : request.resolve(message.result);
});
export function rpc(method, parameters = {}) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    process.stdout.write(JSON.stringify({ id, method, ...parameters }) + "\n");
  });
}
export function output(value) {
  process.stdout.write(
    JSON.stringify({
      event: "output",
      text:
        typeof value === "string"
          ? value + "\n"
          : JSON.stringify(value, null, 2) + "\n",
    }) + "\n",
  );
}
export function closeBridge() {
  input.close();
  process.stdout.write(JSON.stringify({ event: "done" }) + "\n");
}
console.log = (...values) => output(values.join(" "));
console.info = (...values) => console.error(...values);
