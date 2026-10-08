// The upstream router retains pairing, PKCE, code consumption and token
// rotation. This layer bounds unauthenticated work and registration storage.
export function boundedAuthStore(Base, { now = Date.now, maximum = 128, abandonedTTL = 10 * 60000 } = {}) {
  return class BoundedAuthStore extends Base {
    cleanupRegistrations() {
      const live = new Set([...this.tokens.values()].filter(token => !token.revoked && token.expiresAt > now()).map(token => token.clientId));
      let changed = false;
      for (const [id, client] of this.clients) {
        const age = now() - Date.parse(client.authorizedAt ?? client.createdAt);
        const ttl = client.authorizedAt ? 30 * 86400000 : abandonedTTL;
        if (!live.has(id) && (!Number.isFinite(age) || age > ttl)) {
          this.clients.delete(id);
          for (const [code, record] of this.authCodes) if (record.clientId === id) this.authCodes.delete(code);
          changed = true;
        }
      }
      for (const [code, record] of this.authCodes) if (record.expiresAt <= now()) this.authCodes.delete(code);
      if (changed) this.save();
    }
    registerClient(input) {
      this.cleanupRegistrations();
      if (this.clients.size >= maximum) throw Object.assign(new Error('Too many AI registrations. Try again later.'), { status: 429 });
      return super.registerClient(input);
    }
    issueTokens(input) {
      const client = this.getClient(input.clientId);
      if (!client) throw Object.assign(new Error('AI registration has expired. Please reconnect.'), { status: 400 });
      client.authorizedAt = new Date(now()).toISOString();
      return super.issueTokens(input);
    }
  };
}

export function boundedPairingManager(Base) {
  return class BoundedPairingManager extends Base {
    verify(code, ip) {
      for (const [key, entry] of this.ipHits) if (entry.resetAt <= Date.now()) this.ipHits.delete(key);
      if (ip && !this.ipHits.has(ip) && this.ipHits.size >= 512) return { ok: false, reason: 'rate_limited' };
      return super.verify(code, ip);
    }
  };
}

export function oauthSecurity({ store, now = Date.now }) {
  const windows = new Map();
  const limits = { register: 20, authorize: 60, token: 60, revoke: 60 };
  const global = new Map();
  const admitted = []; // Bounds upstream pendingRequests, whose TTL is 10 min.
  function permit(key, kind, maximum) {
    const current = windows.get(key) ?? { start: now(), count: 0 };
    if (current.start + 60000 <= now()) { current.start = now(); current.count = 0; }
    if (current.count >= maximum) return false;
    current.count++; windows.set(key, current); return true;
  }
  return (req, res, next) => {
    const kind = req.path.match(/^\/oauth\/(register|authorize|token|revoke)$/)?.[1];
    if (!kind) { next(); return; }
    for (const [key, entry] of windows) if (entry.start + 60000 <= now()) windows.delete(key);
    // Proxy headers are attacker-controlled. A socket-address limit and a Gate
    // global budget cannot be bypassed by rotating X-Forwarded-For / CF headers.
    const ip = req.socket.remoteAddress ?? 'unknown';
    const globalEntry = global.get(kind) ?? { start: now(), count: 0 };
    if (globalEntry.start + 60000 <= now()) { globalEntry.start = now(); globalEntry.count = 0; }
    global.set(kind, globalEntry);
    if (windows.size >= 512 || globalEntry.count >= limits[kind] * 2 || !permit(`${kind}:${ip}`, kind, limits[kind])) {
      res.set('Retry-After', '60').status(429).json({ error: 'rate_limited' }); return;
    }
    globalEntry.count++;
    store.cleanupRegistrations();
    const source = req.method === 'GET' ? req.query : req.body;
    if (kind !== 'register' && Object.values(source ?? {}).some(value => typeof value !== 'string')) {
      res.status(400).json({ error: 'invalid_request' }); return;
    }
    if (kind === 'register') {
      const uris = req.body?.redirect_uris;
      if (!Array.isArray(uris) || uris.length < 1 || uris.length > 8 || uris.some(uri => typeof uri !== 'string' || uri.length > 2048)
          || (req.body.client_name !== undefined && typeof req.body.client_name !== 'string')) {
        res.status(400).json({ error: 'invalid_client_metadata' }); return;
      }
      if (store.clients.size >= 128) { res.status(429).json({ error: 'registration_limit' }); return; }
    }
    if (Object.values(source ?? {}).some(value => typeof value === 'string' && value.length > 4096)) {
      res.status(400).json({ error: 'invalid_request' }); return;
    }
    if (kind === 'authorize' && req.method === 'GET') {
      while (admitted.length && admitted[0].at + 10 * 60000 <= now()) admitted.shift();
      if (admitted.length >= 256) { res.status(429).json({ error: 'authorization_limit' }); return; }
      const reservation = { at: now() };
      admitted.push(reservation);
      res.once('finish', () => {
        if (res.statusCode !== 200) { const index = admitted.indexOf(reservation); if (index >= 0) admitted.splice(index, 1); }
      });
    }
    next();
  };
}
