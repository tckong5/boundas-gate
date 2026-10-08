// CLI stderr keeps failure locations without publishing credentials to logs.
export function diagnosticError(error) {
  let text = `${error?.stack ?? error?.message ?? 'Gate command failed'}\n${typeof error?.stderr === 'string' ? error.stderr : ''}`.slice(0, 16384);
  for (const pattern of [
    /bearer\s+\S+/gi,
    /(?:access[_-]?token|refresh[_-]?token|client[_-]?secret|admin[_-]?token|pairing[_-]?code|access[_-]?key|api[_-]?key|passcode|password|authorization|TS_AUTHKEY)["']?\s*[=:]\s*["']?[^\s,"'}]+/gi,
    /[?&](?:code|token|key|secret|state|access_token|refresh_token|access_key)=[^&\s]+/gi,
    /\bBG-(?:[a-f0-9]{4}-){5}[a-f0-9]{4}\b/gi,
    /\b[A-Z2-9]{4}-[A-Z2-9]{4}\b/g,
    /\b[A-Z2-9]{8}\b/g,
    /https?:\/\/[^/@\s]+@/g,
    /[A-Za-z0-9_+/-]{24,}={0,2}/g,
  ]) text = text.replace(pattern, '[REDACTED]');
  return text;
}
