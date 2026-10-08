import test from 'node:test';
import assert from 'node:assert/strict';
import { summarizeAIConnections } from '../../Resources/Gateway/connection-status.mjs';

const instance = 'abcdef123456';
const now = 100000;
const client = (id, name) => ({ clientId: id, clientName: name, redirectUris: ['https://private.example/callback'] });
const token = (id, fields = {}) => ({ clientId: id, workspaceId: instance, kind: 'access',
  revoked: false, expiresAt: now + 1000, scopes: [`bg.instance.${instance}`], hash: 'SECRET_HASH', ...fields });

test('groups credentials by client and reports mixed authorization without exposing credentials', () => {
  const result = summarizeAIConnections({ clients: [client('a', 'ChatGPT'), client('b', 'Claude')],
    tokens: [token('a'), token('a', { kind: 'refresh' }), token('b', { expiresAt: now - 1 })] }, instance, now);
  assert.equal(result.length, 2);
  assert.equal(result[0].authorizationState, 'authorized');
  assert.equal(result[1].authorizationState, 'invalid');
  assert.equal(result[0].name, 'ChatGPT');
  assert.equal(JSON.stringify(result).includes('SECRET_HASH'), false);
  assert.equal(JSON.stringify(result).includes('redirectUris'), false);
});

test('distinguishes known revocation from missing historical evidence', () => {
  const result = summarizeAIConnections({ clients: [client('a', 'A'), client('b', 'B')],
    tokens: [token('a', { revoked: true })] }, instance, now);
  assert.equal(result[0].authorizationState, 'revoked');
  assert.equal(result[1].authorizationState, 'unknown');
});

test('valid refresh authorization counts, wrong-instance or unscoped grants do not', () => {
  const result = summarizeAIConnections({ clients: [client('a', 'A'), client('b', 'B'), client('c', 'C')],
    tokens: [token('a', { kind: 'refresh' }), token('b', { workspaceId: 'ffffffffffff' }),
      token('c', { scopes: ['workspace.read'] })] }, instance, now);
  assert.equal(result[0].authorizationState, 'authorized');
  assert.notEqual(result[1].authorizationState, 'authorized');
  assert.notEqual(result[2].authorizationState, 'authorized');
  assert.equal(summarizeAIConnections({}, instance, now), null);
});
