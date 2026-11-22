import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// auth.mjs keeps its files under DATA_DIR, which honours this env override, so tests never touch ~/.cursor-remote-lite.
const DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'cursor-remote-lite-test-'));
process.env.CURSOR_REMOTE_LITE_DIR = DATA_DIR;

const {
  normalizeComputerName,
  ensureComputer,
  setComputerName,
  computerPublic,
} = await import('../auth.mjs');

const configPath = () => path.join(DATA_DIR, 'config.json');
const readConfigFile = () => JSON.parse(fs.readFileSync(configPath(), 'utf8'));
const resetConfig = () => fs.rmSync(configPath(), { force: true });

test.after(() => {
  fs.rmSync(DATA_DIR, { recursive: true, force: true });
});

test('normalizeComputerName trims and rejects empty', () => {
  assert.equal(normalizeComputerName('  家里  '), '家里');
  assert.equal(normalizeComputerName(''), null);
  assert.equal(normalizeComputerName('   '), null);
  assert.equal(normalizeComputerName(null), null);
  assert.equal(normalizeComputerName(undefined), null);
});

test('normalizeComputerName caps at 40 chars', () => {
  const long = 'x'.repeat(50);
  assert.equal(normalizeComputerName(long).length, 40);
  // Trim happens before the cap, so trailing spaces never eat the budget.
  assert.equal(normalizeComputerName(`  ${long}  `).length, 40);
});

test('ensureComputer creates a stable 22-char base64url id and a default name', () => {
  resetConfig();
  const first = ensureComputer();
  assert.match(first.id, /^[A-Za-z0-9_-]{22}$/);
  assert.ok(first.name.length > 0 && first.name.length <= 40);
  assert.deepEqual(readConfigFile(), { computerId: first.id, computerName: first.name });

  const second = ensureComputer();
  assert.deepEqual(second, first);
});

test('ensureComputer keeps an existing id and name', () => {
  fs.writeFileSync(configPath(), JSON.stringify({ computerId: 'abcdefghijklmnopqrstuv', computerName: '办公室' }));
  const got = ensureComputer();
  assert.deepEqual(got, { id: 'abcdefghijklmnopqrstuv', name: '办公室' });
});

test('setComputerName stores a trimmed name and preserves the id', () => {
  resetConfig();
  const { id } = ensureComputer();
  const got = setComputerName('  书房 PC  ');
  assert.deepEqual(got, { id, name: '书房 PC' });
  assert.deepEqual(readConfigFile(), { computerId: id, computerName: '书房 PC' });
});

test('setComputerName rejects an empty name and leaves config untouched', () => {
  resetConfig();
  const before = ensureComputer();
  assert.equal(setComputerName('   '), null);
  assert.deepEqual(readConfigFile(), { computerId: before.id, computerName: before.name });
});

test('setComputerName preserves unrelated config keys', () => {
  resetConfig();
  fs.writeFileSync(configPath(), JSON.stringify({ publishRepo: 'owner/repo' }));
  const { id } = setComputerName('客厅');
  assert.deepEqual(readConfigFile(), { publishRepo: 'owner/repo', computerId: id, computerName: '客厅' });
});

test('computerPublic matches ensureComputer', () => {
  resetConfig();
  const expected = ensureComputer();
  assert.deepEqual(computerPublic(), expected);
});
