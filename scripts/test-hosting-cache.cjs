// Run with node scripts/test-hosting-cache.cjs. No packages or deployment required.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const config = JSON.parse(readFileSync(require('node:path').join(__dirname, '../firebase.json'), 'utf8')).hosting;
const rule = config.headers.find(h => h.regex);
assert.ok(rule, 'Extensionless SPA routes need their own header before Firebase rewrites');
const pattern = new RegExp(rule.regex);
for (const route of ['/', '/attendance', '/attendance/history', '/attendance/history/', '/employee/123', '/%ED%95%9C%EA%B8%80']) {
  assert.ok(pattern.test(route), route);
}
for (const asset of ['/assets/lib/assets/icon/fonts/NotoSansKR-VariableFont_wght.ttf', '/canvaskit/canvaskit.wasm', '/icons/Icon-192.png', '/favicon.png', '/assets/FontManifest.json']) {
  assert.equal(pattern.test(asset), false, asset);
}
assert.deepEqual(rule.headers, [{ key: 'Cache-Control', value: 'max-age=0, must-revalidate' }]);
assert.ok(config.headers.some(h => h.source === '/' && h.headers.some(v => v.value === 'max-age=0, must-revalidate')));
assert.ok(config.headers.some(h => h.source === '/{index.html,flutter_bootstrap.js,main.dart.js,flutter_service_worker.js,manifest.json}' && h.headers.some(v => v.value === 'max-age=0, must-revalidate')));
assert.deepEqual(config.rewrites, [{ source: '**', destination: '/index.html' }]);
console.log('PASS: 6 route paths, 5 static assets, existing entrypoint headers and SPA rewrite');
