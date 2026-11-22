// Multi-computer store helpers for the phone App.
//
// Pure functions only: no DOM, no storage, no network. The file is an ES
// module (`export` plus the globalThis assignment below). index.html loads it
// with <script type="module"> so the classic inline script can read
// globalThis.Computers after the `computers-ready` event. Unit tests import
// the same functions directly.

const DEFAULT_NAME = '电脑';
const MAX_NAME = 40;

function cleanName(value) {
  return String(value ?? '').trim().slice(0, MAX_NAME);
}

// Reads persisted state and upgrades the pre-multi-computer shape
// ({ key, token }) into a one-entry list. A legacy entry keeps `id: null` so it
// resolves through root url.json until /api/me supplies the real id.
export function migrateComputers({ key, token, computersJson, activeId = null, lastId = null } = {}) {
  let computers = [];
  try { computers = JSON.parse(computersJson || '[]'); } catch { computers = []; }
  if (!Array.isArray(computers)) computers = [];
  if (computers.length) {
    return { computers, activeId, lastId, didMigrate: false };
  }
  if (key && token) {
    return {
      computers: [{ id: null, name: DEFAULT_NAME, key, token, nameDirty: false }],
      activeId: null,
      lastId: null,
      didMigrate: true,
    };
  }
  return { computers: [], activeId: null, lastId: null, didMigrate: false };
}

// Adds or replaces one computer, matching on id. A null id always appends:
// legacy rows cannot be de-duplicated until the server reports their id.
export function upsertComputer(list, entry = {}) {
  const next = [...list];
  const i = next.findIndex(c => entry.id != null && c.id === entry.id);
  const existing = i >= 0 ? next[i] : null;
  const name = cleanName(entry.name);
  const row = {
    id: entry.id ?? null,
    // A re-upsert that omits the name (token refresh) must not wipe a name the
    // user chose or the server reported.
    name: name || existing?.name || DEFAULT_NAME,
    key: entry.key,
    token: entry.token,
    nameDirty: entry.nameDirty == null ? Boolean(existing?.nameDirty) : Boolean(entry.nameDirty),
  };
  if (i >= 0) next[i] = { ...next[i], ...row };
  else next.push(row);
  return next;
}

// Pairing another computer must not switch the phone off the one it is using.
// The new row is upserted; activeId and lastId stay. The open session's key
// and token stay too, unless this link is for that same computer — then the
// new token replaces the old one so a later reconnect still works.
// A legacy id:null row with this key is the same computer seen before /api/me.
export function addComputerKeepingSession(state = {}, entry = {}, session = {}) {
  let computers = Array.isArray(state.computers) ? state.computers : [];
  if (entry.key && computers.some(c => c.id == null && c.key === entry.key)) {
    computers = removeComputer(computers, entry.key);
  }
  computers = upsertComputer(computers, entry);
  const same = Boolean(session.key) && session.key === entry.key;
  return {
    computers,
    activeId: state.activeId ?? null,
    lastId: state.lastId ?? null,
    key: same ? entry.key : (session.key ?? null),
    token: same ? entry.token : (session.token ?? null),
  };
}

// Drops by computer id, falling back to the pairing key so a legacy row
// (id still null) can be forgotten from the phone.
export function removeComputer(list, idOrKey) {
  if (idOrKey == null) return [...list];
  if (list.some(c => c.id === idOrKey)) return list.filter(c => c.id !== idOrKey);
  return list.filter(c => c.key !== idOrKey);
}

// Local rename only. Sets nameDirty so the next successful connect can push the
// name to that computer; blank input is rejected and leaves the list untouched.
export function renameComputer(list, id, name) {
  const n = cleanName(name);
  if (!n) return { list, ok: false };
  return {
    ok: true,
    list: list.map(c => c.id === id ? { ...c, name: n, nameDirty: true } : c),
  };
}

// Legacy rows have no id yet, so they still read the shared root file.
export function urlPathFor(computer) {
  return computer?.id ? `urls/${computer.id}.json` : 'url.json';
}

// Turns probe results into a boot decision: nothing reachable, exactly one
// (auto-connect), or several (must pick — lastId only pre-highlights).
export function pickOnline(results, lastId) {
  const online = (Array.isArray(results) ? results : []).filter(r => r && r.online);
  if (online.length === 0) return { action: 'none', online, highlightId: null };
  if (online.length === 1) return { action: 'auto', online, highlightId: online[0].id };
  const highlightId = online.some(o => o.id === lastId) ? lastId : online[0].id;
  return { action: 'pick', online, highlightId };
}

if (typeof globalThis !== 'undefined') {
  globalThis.Computers = {
    migrateComputers, upsertComputer, removeComputer, renameComputer, urlPathFor, pickOnline,
    addComputerKeepingSession,
  };
  // Classic inline script runs before this deferred module. It listens for
  // this event and only then calls boot(). Node has no dispatchEvent.
  if (typeof globalThis.dispatchEvent === 'function') {
    globalThis.dispatchEvent(new Event('computers-ready'));
  }
}
