import test from 'node:test';
import assert from 'node:assert/strict';
import { diagnosticError } from '../../Resources/Gateway/diagnostics.mjs';

test('CLI failure preserves stack and underlying stderr while scrubbing secrets', () => {
  const error = new Error('missing module');
  error.stderr = 'at server.mjs:20 Bearer shortsecret BG-B0EA-B1A3-3D4E-A6F6-37B6-58DF api_key=privatekey ?access_key=privateaccess';
  const text = diagnosticError(error);
  assert.match(text, /missing module/); assert.match(text, /server.mjs:20/);
  for (const value of ['shortsecret', 'BG-B0EA', 'privatekey', 'privateaccess']) assert.ok(!text.includes(value), value);
});


test('login diagnostics distinguish private backend state without logging auth URLs', () => {
  const error = Object.assign(new Error('Sign in failed'), { errorCode: 'login_timeout', backendState: 'Stopped',
    loginURL: 'https://login.tailscale.com/a/private' });
  const output = diagnosticError(error);
  assert.ok(output.includes('loginFailure=login_timeout backendState=Stopped'));
  assert.equal(output.includes('/a/private'), false);
  error.backendState = 'private-value';
  assert.ok(diagnosticError(error).includes('backendState=unknown'));
});
