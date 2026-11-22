import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'cursor-remote-lite-republish-'));
process.env.CURSOR_REMOTE_LITE_DIR = DATA_DIR;

const { ensureComputer, saveState, urlKey } = await import('../auth.mjs');
const { republishKnownRelay, addressFiles } = await import('../publish-address.mjs');

const configPath = () => path.join(DATA_DIR, 'config.json');
const statePath = () => path.join(DATA_DIR, 'state.json');

function writeConfig(value) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.writeFileSync(configPath(), JSON.stringify(value));
}

function resetFiles() {
  fs.rmSync(statePath(), { force: true });
  fs.rmSync(configPath(), { force: true });
}

function decryptPublished(buf) {
  const parsed = JSON.parse(buf.toString('utf8'));
  const iv = Buffer.from(parsed.iv, 'base64');
  const raw = Buffer.from(parsed.data, 'base64');
  const tag = raw.subarray(raw.length - 16);
  const data = raw.subarray(0, raw.length - 16);
  const decipher = crypto.createDecipheriv('aes-256-gcm', urlKey(), iv);
  decipher.setAuthTag(tag);
  return JSON.parse(Buffer.concat([decipher.update(data), decipher.final()]).toString('utf8'));
}

test.after(() => {
  fs.rmSync(DATA_DIR, { recursive: true, force: true });
});

test('addressFiles encrypts one body for this computer and the shared root', () => {
  resetFiles();
  writeConfig({ publishRepo: 'owner/repo', computerId: 'abcdefghijklmnopqrstuv', computerName: '公司' });
  const { id, body, paths } = addressFiles('https://b.trycloudflare.com');
  assert.equal(id, 'abcdefghijklmnopqrstuv');
  assert.deepEqual(paths, ['urls/abcdefghijklmnopqrstuv.json', 'url.json']);
  assert.equal(decryptPublished(body).url, 'https://b.trycloudflare.com');
});

test('republishKnownRelay writes the same ciphertext to urls/<id>.json and url.json', async () => {
  resetFiles();
  writeConfig({ publishRepo: 'owner/repo', computerId: 'abcdefghijklmnopqrstuv', computerName: '公司' });
  saveState({ relayUrl: 'https://b.trycloudflare.com' });
  const puts = [];
  const result = await republishKnownRelay({
    putFile: async (name, buf, sha) => { puts.push({ name, text: buf.toString('utf8'), sha }); },
    remoteSha: async name => `sha-${name}`,
  });
  assert.equal(result.published, true);
  assert.equal(result.id, 'abcdefghijklmnopqrstuv');
  assert.deepEqual(puts.map(p => p.name), ['urls/abcdefghijklmnopqrstuv.json', 'url.json']);
  assert.equal(puts[0].text, puts[1].text);
  assert.equal(puts[0].sha, 'sha-urls/abcdefghijklmnopqrstuv.json');
  assert.equal(puts[1].sha, 'sha-url.json');
  assert.equal(decryptPublished(Buffer.from(puts[0].text)).url, 'https://b.trycloudflare.com');
  assert.equal(ensureComputer().id, 'abcdefghijklmnopqrstuv');
});

test('republishKnownRelay does nothing when no relay address is saved', async () => {
  resetFiles();
  writeConfig({ publishRepo: 'owner/repo', computerId: 'abcdefghijklmnopqrstuv', computerName: '公司' });
  let calls = 0;
  const result = await republishKnownRelay({
    putFile: async () => { calls++; },
    remoteSha: async () => 'sha',
  });
  assert.deepEqual(result, { published: false, reason: 'no-relay' });
  assert.equal(calls, 0);
});

test('republishKnownRelay does nothing without a publish repo', async () => {
  resetFiles();
  writeConfig({ computerId: 'abcdefghijklmnopqrstuv', computerName: '公司' });
  saveState({ relayUrl: 'https://b.trycloudflare.com' });
  let calls = 0;
  const result = await republishKnownRelay({
    putFile: async () => { calls++; },
    remoteSha: async () => 'sha',
  });
  assert.equal(result.published, false);
  assert.equal(result.reason, 'no-repo');
  assert.equal(calls, 0);
});

test('republishKnownRelay can skip a private relay url', async () => {
  resetFiles();
  writeConfig({ publishRepo: 'owner/repo', computerId: 'abcdefghijklmnopqrstuv', computerName: '公司' });
  saveState({ relayUrl: 'http://192.168.1.9:3939/' });
  let calls = 0;
  const skipped = await republishKnownRelay({
    onlyPublic: true,
    putFile: async () => { calls++; },
    remoteSha: async () => 'sha',
  });
  assert.equal(skipped.published, false);
  assert.equal(skipped.reason, 'not-public');
  assert.equal(calls, 0);

  const written = await republishKnownRelay({
    putFile: async (name, buf) => { calls++; return { name, buf }; },
    remoteSha: async () => undefined,
  });
  assert.equal(written.published, true);
  assert.equal(calls, 2);
  assert.equal(decryptPublished(written.body).url, 'http://192.168.1.9:3939/');
});
