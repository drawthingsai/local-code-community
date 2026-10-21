// Run with Node's TypeScript stripping support and an upstream Git checkout:
// node generate_rate_reference.mjs /path/to/hyperframes
// Execute the pinned upstream functions; do not duplicate the exporter's math here.
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const file = new URL('./speed-ramp-reference.json', import.meta.url);
const reference = JSON.parse(fs.readFileSync(file, 'utf8'));
if (!process.argv[2]) throw new Error('Supply the upstream HyperFrames Git checkout.');
const read = path => execFileSync('git', ['-C', process.argv[2], 'show', `${reference.upstream}:${path}`], {encoding: 'utf8'});
const automation = read('packages/core/src/audioAutomation.ts');
const ramp = read('packages/core/src/speedRamp.ts');
const between = (text, start, end) => text.slice(text.indexOf(start), text.indexOf(end));
const source = 'const MAX_AUTOMATION_POINTS = 512;\n' +
  between(automation, 'function numberOrNull', 'export function normalizeAutomation') +
  between(automation, 'export function applyCurve', '/** True when the lane is a single value') +
  between(ramp, 'const CELLS_PER_SEGMENT', '/** The `rate` lane inside') +
  '\nmodule.exports = {normalizePoints, sourceTimeAt, timeAtSourceTime};';
const context = {module: {exports: {}}};
vm.runInNewContext(stripTypeScriptTypes(source.replaceAll('export ', '')), context);
const api = context.module.exports;
for (const item of reference.cases) {
  const points = api.normalizePoints(item.points, {min: 0.1, max: 10});
  const rate = points.length ? {target: 'rate', points} : item.constant;
  item.samples = Array.from({length: 301}, (_, index) => {
    const time = (index - 30) / 60;
    const source = api.sourceTimeAt(rate, time);
    return [time, source, api.timeAtSourceTime(rate, source)];
  });
}
const lines = ['{', `  "upstream": ${JSON.stringify(reference.upstream)},`,
  `  "sources": ${JSON.stringify(reference.sources)},`, '  "cases": ['];
reference.cases.forEach((item, index) => {
  lines.push('    {', `      "name": ${JSON.stringify(item.name)},`, `      "constant": ${item.constant},`,
    `      "points": ${JSON.stringify(item.points)},`, '      "samples": [');
  for (let i = 0; i < item.samples.length; i += 4)
    lines.push('        ' + item.samples.slice(i, i + 4).map(x => JSON.stringify(x)).join(', ') +
      (i + 4 < item.samples.length ? ',' : ''));
  lines.push('      ]', '    }' + (index + 1 < reference.cases.length ? ',' : ''));
});
lines.push('  ]', '}');
fs.writeFileSync(file, lines.join('\n') + '\n');
