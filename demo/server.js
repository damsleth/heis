#!/usr/bin/env node
// heis-demo — serves the elevator demo page and relays Install.ps1 / Heis.ps1 (case-insensitive paths)
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 2620;
const HOST = '127.0.0.1';
const PUBLIC = path.join(__dirname, 'public');
const UPSTREAM_BASE = 'https://raw.githubusercontent.com/damsleth/heis/main/';
const SELF_BASE = 'https://heis.d0.si/';

// Route (lower-cased request path) -> upstream script name (always capitalized).
const SCRIPTS = {
  '/install.ps1': 'Install.ps1',
  '/heis.ps1': 'Heis.ps1',
  // legacy aliases
  '/run.ps1': 'Install.ps1',
  '/heis-standalone.ps1': 'Install.ps1',
};

// Cache each upstream script so we don't hit GitHub on every | iex.
const cache = new Map(); // name -> { body, at }
const TTL = 5 * 60 * 1000;

async function fetchScript(name) {
  const now = Date.now();
  const hit = cache.get(name);
  if (hit && now - hit.at < TTL) return hit.body;
  const res = await fetch(UPSTREAM_BASE + name, { headers: { 'User-Agent': 'heis-demo' } });
  if (!res.ok) throw new Error('upstream ' + res.status);
  let text = await res.text();
  // Point any raw.githubusercontent heis URL the script carries (self-refetch,
  // Install.ps1 -> Heis.ps1 source URL, ...) back at this host, keeping the
  // capitalized script name so the relay resolves it to the right upstream file.
  text = text.replace(
    /https:\/\/raw\.githubusercontent\.com\/damsleth\/heis\/main\/([A-Za-z0-9._-]+\.ps1)/g,
    (_, file) => SELF_BASE + file
  );
  cache.set(name, { body: text, at: now });
  return text;
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

function serveStatic(res, file) {
  const full = path.join(PUBLIC, file);
  if (!full.startsWith(PUBLIC)) { res.writeHead(403).end('no'); return; }
  fs.readFile(full, (err, data) => {
    if (err) { res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found'); return; }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(full)] || 'application/octet-stream' });
    res.end(data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = (req.url || '/').split('?')[0];
  const script = SCRIPTS[url.toLowerCase()];
  if (script) {
    try {
      const body = await fetchScript(script);
      res.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-cache',
        'Content-Disposition': 'inline; filename="' + script + '"',
      });
      res.end(body);
    } catch (e) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('# heisen sitter fast mellom etasjene: ' + e.message + '\n');
    }
    return;
  }
  if (url === '/healthz') { res.writeHead(200).end('oppe\n'); return; }
  if (url === '/' || url === '/index.html') { serveStatic(res, 'index.html'); return; }
  serveStatic(res, url.replace(/^\/+/, ''));
});

server.listen(PORT, HOST, () => console.log('heis-demo on http://' + HOST + ':' + PORT));
