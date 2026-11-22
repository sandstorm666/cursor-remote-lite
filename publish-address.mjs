// Republish this computer's relay address so a new pair link can decrypt root url.json.
// Another computer sharing the same Pages repo may have written that file last.
import { spawn } from 'node:child_process';
import { encryptUrl, ensureComputer, readConfig, readState } from './auth.mjs';

export function knownRelayUrl() {
  const url = readState().relayUrl;
  if (typeof url !== 'string') return null;
  const trimmed = url.trim();
  return trimmed || null;
}

// One ciphertext, two paths: this computer's file and the shared root the pair link reads.
export function addressFiles(url) {
  const { id } = ensureComputer();
  const body = Buffer.from(JSON.stringify(encryptUrl(url)) + '\n');
  return { id, body, paths: [`urls/${id}.json`, 'url.json'] };
}

function gh(args, input) {
  return new Promise((resolve, reject) => {
    const p = spawn('gh', args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    p.stdout.on('data', d => { out += d; });
    p.stderr.on('data', d => { err += d; });
    p.on('error', reject);
    p.on('close', code => (code === 0 ? resolve(out.trim()) : reject(new Error(err.trim() || `gh exited ${code}`))));
    if (input != null) p.stdin.end(input);
    else p.stdin.end();
  });
}

async function ghPut(repo, name, buf, sha) {
  const body = { message: `update ${name}`, content: buf.toString('base64'), ...(sha ? { sha } : {}) };
  await gh(['api', '-X', 'PUT', `repos/${repo}/contents/${name}`, '--input', '-'], JSON.stringify(body));
}

async function ghSha(repo, name) {
  try {
    const out = await gh(['api', `repos/${repo}/contents/${name}`, '--jq', '.sha']);
    return out.trim() || undefined;
  } catch {
    return undefined;
  }
}

// Writes urls/<id>.json and root url.json with THIS computer's key.
// onlyPublic skips http:// addresses so a LAN start does not replace the public file.
export async function republishKnownRelay(opts = {}) {
  const url = knownRelayUrl();
  if (!url) return { published: false, reason: 'no-relay' };
  const repo = readConfig().publishRepo;
  if (!repo) return { published: false, reason: 'no-repo' };
  if (opts.onlyPublic && !/^https:\/\//i.test(url)) return { published: false, reason: 'not-public' };
  const { id, body, paths } = addressFiles(url);
  const putFile = opts.putFile || ((name, buf, sha) => ghPut(repo, name, buf, sha));
  const remoteSha = opts.remoteSha || (name => ghSha(repo, name));
  for (const name of paths) {
    const sha = await remoteSha(name);
    await putFile(name, body, sha);
  }
  return { published: true, id, url, body, paths };
}
