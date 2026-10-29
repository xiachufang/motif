// Run the browser smoke page against the real WASM binary without a browser.
// First build it: apps/flutter/scripts/build_ghostty_wasm.sh
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

async function main() {
  const web = path.resolve(__dirname, '../apps/flutter/web');
  const output = { textContent: '' };
  const context = vm.createContext({
    window: {},
    document: { getElementById: () => output },
    TextEncoder,
    TextDecoder,
    console,
    fetch: async () => ({
      arrayBuffer: async () => fs.readFileSync(path.join(web, 'ghostty-vt.wasm')),
    }),
  });
  vm.runInContext(fs.readFileSync(path.join(web, 'ghostty_vt.js'), 'utf8'), context);
  const page = fs.readFileSync(path.join(web, 'wasmtest.html'), 'utf8');
  for (const [, script] of page.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
    await vm.runInContext(script, context);
  }
  assert.ok(output.textContent.startsWith('RESULT:PASS'), output.textContent);
  console.log(output.textContent);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
