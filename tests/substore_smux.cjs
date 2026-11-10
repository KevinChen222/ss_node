const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = process.env.TEST_SUBSTORE_SOURCE;
if (!root) throw new Error('TEST_SUBSTORE_SOURCE is required');
const { Base64 } = require(path.join(root, 'runtime/node_modules/js-base64'));
const lodash = require(path.join(root, 'runtime/node_modules/lodash'));
const read = name => fs.readFileSync(path.join(root, 'backend/src', name), 'utf8');
const plainModule = source => source.replace(/^import[\s\S]*?;\n/gm, '')
    .replace(/export default /g, '').replace(/export /g, '');
const parsers = read('core/proxy-utils/parsers/index.js');
const utils = read('utils/index.js');
const source = [
    utils.slice(utils.indexOf('function isNotBlank('), utils.indexOf('function getPolicyDescriptor(')),
    parsers.slice(parsers.indexOf('function splitURIFragment('), parsers.indexOf('function isNumericEarlyData(')),
    parsers.slice(parsers.indexOf('function URI_SS('), parsers.indexOf('function URI_SSR(')),
    plainModule(read('core/proxy-utils/producers/utils.js')),
    plainModule(read('core/proxy-utils/producers/clashmeta.js')),
    'const ProxyUtils = {parse: line => [URI_SS().parse(line)]};',
    fs.readFileSync(path.join(__dirname, '../substore-smux.js'), 'utf8'),
].join('\n');
const context = vm.createContext({ Base64, _: lodash, Buffer, b64d: Base64.decode,
    $: { error: message => { throw new Error(message); }, warn() {}, info() {} },
    isPlainObject: lodash.isPlainObject });
vm.runInContext(source, context);
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
context.lines = input.map(item => item.link);
vm.runInContext(`
const before = lines.map(line => URI_SS().parse(line));
if (before.some(proxy => proxy.smux !== undefined)) throw new Error('unexpected native smux support');
const restored = operator(before, 'ClashMeta', {raw:[lines.join('\\n')]});
const produced = ClashMeta_Producer().produce(restored, 'internal');
globalThis.output = produced;
const encoded = Base64.encode(lines.join('\\n'));
const fromBase64 = operator(lines.map(line => URI_SS().parse(line)), 'ClashMeta', {raw:[encoded]});
globalThis.base64Output = ClashMeta_Producer().produce(fromBase64, 'internal');
`, context);
for (const output of [context.output, context.base64Output]) {
    assert.equal(output.length, input.length);
    output.forEach((proxy, index) => {
        const actual = JSON.parse(JSON.stringify(proxy));
        const expected = input[index].proxy;
        actual.port = Number(actual.port);
        for (const key of Object.keys(expected)) assert.deepEqual(actual[key], expected[key], key);
    });
}
context.badLine = input[0].link.replace(/smux=[^&#]*/, 'smux=%7Binvalid%7D');
assert.throws(() => vm.runInContext("operator([URI_SS().parse(badLine)], 'ClashMeta', {raw:[badLine]})", context));
assert.throws(() => vm.runInContext("operator([], 'ClashMeta', {})", context));
process.stdout.write('official SS parser -> smux operator -> mihomo producer: parameters preserved\n');
