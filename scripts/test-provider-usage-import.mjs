// Exercises the actual embedded helper over its authenticated encrypted protocol.
// Default: isolated SQLite fixtures. --live-v2 <CLI>: selected local Codex account,
// a temporary PTY, and one read-only usage request. Never prints credentials.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const swift = readFileSync(new URL('../OpenCodeIOSClient/ProviderUsage/ProviderUsageCredentialImportProtocol.swift', import.meta.url), 'utf8');
const helper = swift.match(/static let source = #"""\n([\s\S]*?)\n"""#/)[1];
const launchCommand = swift.match(/static let launchCommand = #"([^\n]+)"#/)[1];
const hash = value => crypto.createHash('sha256').update(value).digest('hex');

function protocol(provider, source, account, access) {
  const pair = crypto.generateKeyPairSync('x25519');
  const client = pair.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
  const psk = crypto.randomBytes(32), op = crypto.randomUUID();
  const expected = account ? hash(account) : '-', current = access ? hash(access) : '-';
  let transcript, shared, ready = false;
  const key = direction => crypto.hkdfSync('sha256', shared, psk, Buffer.from(transcript + '|' + direction), 32);
  return {
    env: { OCPI_HELPER_SOURCE: helper, OCPI_PROVIDER: provider, OCPI_SOURCE: source,
      OCPI_OPERATION_ID: op, OCPI_CLIENT_PUBLIC_KEY: client, OCPI_PSK: psk.toString('base64'),
      OCPI_EXPECTED_ACCOUNT_BINDING: expected, OCPI_CURRENT_ACCESS_BINDING: current },
    line(line, send) {
      const f = line.split('|');
      if (f[2] === 'ERROR') throw new Error('Helper error: ' + f[3]);
      assert.equal(f.length, 9);
      assert.equal(f[3], op); assert.equal(f[4], provider); assert.equal(f[5], source);
      if (f[2] === 'READY') {
        assert.equal(ready, false); ready = true;
        transcript = ['OCPI', '1', op, provider, source, expected, current, client, f[7]].join('|');
        const mac = crypto.createHmac('sha256', psk).update(transcript + '|READY|0').digest();
        assert(crypto.timingSafeEqual(mac, Buffer.from(f[8], 'base64')));
        const publicKey = crypto.createPublicKey({ type: 'spki', format: 'der',
          key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(f[7], 'base64')]) });
        shared = crypto.diffieHellman({ privateKey: pair.privateKey, publicKey });
        const nonce = crypto.randomBytes(12), ns = nonce.toString('base64');
        const cipher = crypto.createCipheriv('chacha20-poly1305', key('c2s'), nonce, { authTagLength: 16 });
        cipher.setAAD(Buffer.from(transcript + '|c2s|START|0|' + ns));
        const box = Buffer.concat([cipher.update('{}'), cipher.final(), cipher.getAuthTag()]);
        send(['OCPI', '1', 'START', op, provider, source, '0', ns, box.toString('base64')].join('|') + '\n');
      } else {
        assert.equal(f[2], 'RESULT'); assert.equal(f[6], '1'); assert(ready);
        const box = Buffer.from(f[8], 'base64');
        const cipher = crypto.createDecipheriv('chacha20-poly1305', key('s2c'), Buffer.from(f[7], 'base64'), { authTagLength: 16 });
        cipher.setAAD(Buffer.from(transcript + '|s2c|RESULT|1|' + f[7]));
        cipher.setAuthTag(box.subarray(-16));
        return JSON.parse(Buffer.concat([cipher.update(box.subarray(0, -16)), cipher.final()]));
      }
    }
  };
}

function receive(protocol, attach, send) {
  return new Promise((resolve, reject) => {
    let buffer = '', bytes = 0;
    const timer = setTimeout(() => reject(new Error('Helper timed out')), 15000);
    attach(text => {
      try {
        bytes += Buffer.byteLength(text); assert(bytes <= 65536);
        buffer += text;
        while (buffer.includes('\n')) {
          const at = buffer.indexOf('\n'), line = buffer.slice(0, at).replace(/\r$/, '');
          buffer = buffer.slice(at + 1);
          const start = line.search(/OCPI\|1\|(READY|RESULT|ERROR)\|/);
          if (start < 0) continue;
          const value = protocol.line(line.slice(start), send);
          if (value) { clearTimeout(timer); resolve(value); }
        }
      } catch (error) { clearTimeout(timer); reject(error); }
    }, () => { clearTimeout(timer); reject(new Error('Helper connection failed')); });
  });
}

async function fixtures() {
  const root = mkdtempSync(path.join(tmpdir(), 'usage-v2-fixture-'));
  const file = path.join(root, 'credentials.db');
  const db = new DatabaseSync(file);
  db.exec('CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, value TEXT)');
  const put = (id, provider, value) => db.prepare('INSERT OR REPLACE INTO credential VALUES (?, ?, ?)').run(id, provider, JSON.stringify(value));
  const future = Date.now() + 3600000;
  put('cred_codex', 'openai', { type: 'oauth', access: 'access-only', refresh: 'never-export-refresh', expires: future, metadata: { accountID: 'account-one' } });
  put('cred_other', 'openai', { type: 'oauth', access: 'other-access', expires: future, metadata: { accountID: 'account-two' } });
  put('cred_router', 'openrouter', { type: 'key', key: 'router-key' });
  put('cred_wrong', 'openai', { type: 'key', key: 'not-codex' });
  put('cred_large', 'openrouter', { type: 'key', key: 'x'.repeat(1048577) });
  put('cred_expired', 'openai', { type: 'oauth', access: 'expired-access', expires: 1, metadata: { accountID: 'account-one' } });
  db.close();
  const before = hash(readFileSync(file));
  async function run(provider, id, account, access, database = file) {
    const p = protocol(provider, `v2-opencode-credential${account ? '-renew' : ''}-v1:${id}`, account, access);
    const child = spawn(process.execPath, ['-e', helper], { env: { ...process.env, ...p.env, OPENCODE_DB: database }, stdio: ['pipe', 'pipe', 'pipe'] });
    child.stderr.resume();
    try {
      return await receive(p, (data, error) => { child.stdout.on('data', b => data(b.toString())); child.on('error', error); child.on('exit', error); }, text => child.stdin.write(text));
    } finally { child.kill(); }
  }
  try {
    const codex = await run('openai', 'cred_codex');
    assert.deepEqual(codex, { ok: true, credential: 'access-only', accountID: 'account-one', expires: future });
    assert(!JSON.stringify(codex).includes('never-export-refresh'));
    assert.deepEqual(await run('openrouter', 'cred_router'), { ok: true, credential: 'router-key' });
    for (const [provider, id, error] of [
      ['openai', 'cred_missing', 'ENTRY_MISSING'], ['openrouter', 'cred_codex', 'ENTRY_MISSING'],
      ['openai', 'cred_wrong', 'UNSUPPORTED_ENTRY'], ['openrouter', 'cred_large', 'SOURCE_TOO_LARGE']
    ]) assert.deepEqual(await run(provider, id), { ok: false, error });
    assert.equal((await run('openai', 'cred_codex', 'account-one', 'older-access')).credential, 'access-only');
    assert.equal((await run('openai', 'cred_other', 'account-one', 'older-access')).error, 'ACCOUNT_MISMATCH');
    assert.equal((await run('openai', 'cred_codex', 'account-one', 'access-only')).error, 'SOURCE_REFRESH_REJECTED');
    assert.equal((await run('openai', 'cred_expired', 'account-one', 'old')).error, 'SOURCE_REFRESH_REJECTED');
    assert.equal((await run('openai', 'cred_codex', undefined, undefined, path.join(root, 'missing.db'))).error, 'SOURCE_MISSING');
    assert.equal(hash(readFileSync(file)), before, 'Import must not modify the source database');
    console.log('PASS: 11 encrypted V2 import/renewal fixtures; source database unchanged.');
  } finally { rmSync(root, { recursive: true, force: true }); }
}

async function live(cli) {
  function api(method, route, data) {
    const args = ['api', method, route];
    if (route.includes('/connect-token')) args.push('--header', 'x-opencode-ticket:1');
    if (data !== undefined) args.push('--data', JSON.stringify(data));
    try {
      const result = execFileSync(cli, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 4000000 });
      return result.trim() ? JSON.parse(result) : null;
    } catch { throw new Error('Local V2 API request failed: ' + method + ' ' + route.split('?')[0]); }
  }
  const info = api('get', '/api/info');
  const query = '?location%5Bdirectory%5D=' + encodeURIComponent(process.cwd());
  const integrations = api('get', '/api/integration' + query).data;
  const connection = integrations.find(i => i.id === 'openai')?.connections.find(c => c.type === 'credential' && c.method === 'oauth');
  assert(connection, 'No local Codex OAuth account available');
  const p = protocol('openai', 'v2-opencode-credential-v1:' + connection.id);
  const pty = api('post', '/api/pty' + query, { title: 'OpenClient Credential Import', args: ['-lic', launchCommand], cwd: process.cwd(), env: p.env }).data;
  let socket;
  try {
    const ticket = api('post', `/api/pty/${pty.id}/connect-token` + query, {}).data;
    const base = execFileSync(cli, ['service', 'status'], { encoding: 'utf8' }).trim().replace('0.0.0.0', '127.0.0.1');
    const url = new URL(`/api/pty/${pty.id}/connect${query}&cursor=0`, base);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('ticket', ticket.ticket);
    socket = new WebSocket(url);
    const result = await receive(p, (data, error) => {
      socket.onmessage = e => { if (typeof e.data === 'string') data(e.data); };
      socket.onerror = error; socket.onclose = error;
    }, text => socket.send(text));
    assert(result.ok, 'Live helper failed: ' + result.error);
    const response = await fetch('https://chatgpt.com/backend-api/wham/usage', {
      headers: { Authorization: 'Bearer ' + result.credential, 'ChatGPT-Account-Id': result.accountID },
      redirect: 'error', signal: AbortSignal.timeout(15000)
    });
    assert.equal(response.status, 200, 'Codex usage HTTP status');
    const usage = await response.json();
    assert(usage.rate_limit?.primary_window, 'Usage primary window missing');
    console.log(`PASS: OpenCode ${info.version}, V2 discovery → encrypted PTY import → Codex usage HTTP 200 (primary window present).`);
  } finally {
    socket?.close();
    api('delete', `/api/pty/${pty.id}` + query);
    assert(!api('get', '/api/pty' + query).data.some(item => item.id === pty.id));
    console.log('PASS: temporary import PTY removed.');
  }
}

if (process.argv[2] === '--live-v2') await live(process.argv[3]);
else await fixtures();
