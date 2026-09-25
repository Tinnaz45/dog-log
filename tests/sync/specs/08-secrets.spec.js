// No privileged secret ships to the browser, and there is no sign-up or admin path in the app.
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../../..');
const SHIPPED = ['index.html', 'sw.js', 'manifest.json', 'vendor/supabase-js-2.116.0.min.js'];

test('27 shipped source contains no service-role key, secret key, JWT or database credential', () => {
  const findings = [];
  for (const f of SHIPPED) {
    const s = fs.readFileSync(path.join(ROOT, f), 'utf8');
    if (/sb_secret_[A-Za-z0-9_-]{8,}/.test(s)) findings.push(`${f}: sb_secret_ key`);
    for (const m of s.match(/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g) || []) findings.push(`${f}: embedded JWT ${m.slice(0, 16)}…`);
    if (/postgres(ql)?:\/\/[^\s'"`]+@/.test(s)) findings.push(`${f}: database connection string`);
    if (/SUPABASE_SERVICE_ROLE|service_role_key|SERVICE_ROLE_KEY/i.test(s)) findings.push(`${f}: service-role reference`);
  }
  expect(findings).toEqual([]);
  const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
  const cfg = html.match(/const SYNC_CONFIG=\{url:'([^']+)',key:'([^']+)'/);
  expect(cfg[1]).toBe('https://wgcqzamuspuqpedqasbc.supabase.co');
  expect(cfg[2]).toMatch(/^sb_publishable_/);
  expect(html).not.toMatch(/service_role/);
  expect(html).not.toMatch(/signUp|auth\.admin|createUser|resetPasswordForEmail/);
  expect(html).not.toMatch(/console\.(log|info|debug)\([^)]*password/i);
});

test('the vendored supabase-js is the pinned, integrity-checked 2.116.0 build', () => {
  const buf = fs.readFileSync(path.join(ROOT, 'vendor/supabase-js-2.116.0.min.js'));
  expect(require('crypto').createHash('sha256').update(buf).digest('hex')).toBe('84ee9bf45695c1dd3ba1595b6bcfb0f09672434631351ffc8ebe9140545d5ff6');
  expect(fs.readFileSync(path.join(ROOT, 'sw.js'), 'utf8')).toContain("'/vendor/supabase-js-2.116.0.min.js'");
});
