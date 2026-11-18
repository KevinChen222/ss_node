// stdin: one share URI; stdout: the single Clash.Meta proxy as JSON.
// TEST_SUBSTORE points to a Sub-Store release's proxy-utils.esm.mjs.
import { pathToFileURL } from 'node:url';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const bundle = pathToFileURL(process.env.TEST_SUBSTORE);
const link = readFileSync(0, 'utf8').trim();
const runtime = process;
// Select the bundled offline script runtime; avoid initializing the Node backend's disk cache.
globalThis.process = undefined;
console.log = console.info = console.warn = console.error = () => {};
const { parse, produce } = await import(bundle);
globalThis.process = runtime;
const output = produce(parse(link), 'ClashMeta', 'internal');
assert.equal(output.length, 1, 'Sub-Store did not export exactly one node');
process.stdout.write(JSON.stringify(output[0]));
