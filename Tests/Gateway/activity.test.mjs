import test from 'node:test';
import assert from 'node:assert/strict';
import { GateActivity } from '../../Resources/Gateway/activity.mjs';

test('activity records only admitted identity, Folder ID and category; no arguments/results', () => {
  let time = 1000;
  const activity = new GateActivity('main', { now: () => time });
  const finish = activity.start({ clientID: 'client', workspaceID: 'abcdef012345', tool: 'read_file',
    path: 'SECRET-FILE', query: 'SECRET-QUERY', token: 'SECRET-TOKEN', code: 'SECRET-CODE', content: 'SECRET-CONTENT' });
  time += 250; finish(true); finish(false);
  const page = activity.snapshot(0);
  assert.equal(page.events.length, 2);
  assert.deepEqual(page.events.map(e => e.type), ['requestStarted', 'requestFinished']);
  assert.equal(page.events[0].tool, 'Read');
  assert.equal(page.events[1].success, true); assert.equal(page.events[1].duration, 250);
  assert.equal(page.events[0].requestID, page.events[1].requestID);
  assert.equal(page.activeRequests.length, 0);
  assert.ok(!JSON.stringify(page).includes('SECRET'));
  assert.deepEqual(Object.keys(page.events[0]).sort(),
    ['requestID', 'gateID', 'clientID', 'workspaceID', 'tool', 'startedAt', 'type', 'timestamp', 'sequence'].sort());
});

test('simultaneous requests have independent lifecycles and out-of-order failure', () => {
  const activity = new GateActivity('main');
  const a = activity.start({ clientID: 'ChatGPT', workspaceID: 'aaaaaaaaaaaa', tool: 'read_file' });
  const b = activity.start({ clientID: 'Claude', workspaceID: 'bbbbbbbbbbbb', tool: 'search_workspace' });
  const requests = activity.snapshot().activeRequests;
  assert.equal(requests.length, 2); assert.notEqual(requests[0].requestID, requests[1].requestID);
  b(false);
  assert.equal(activity.snapshot().activeRequests[0].clientID, 'ChatGPT');
  a(true);
  const finishes = activity.snapshot(0).events.filter(e => e.type === 'requestFinished');
  assert.deepEqual(finishes.map(e => [e.clientID, e.success]), [['Claude', false], ['ChatGPT', true]]);
});

test('resume baseline never replays old traffic, bounded journal gaps reset and preserve active work', () => {
  let time = 0;
  const activity = new GateActivity('main', { now: () => time, capacity: 3, retention: 100 });
  const start = () => activity.start({ clientID: 'c', tool: 'list_workspaces' });
  start()(true); start()(true);
  assert.equal(activity.events.length, 3);
  assert.equal(activity.snapshot(0).reset, true); assert.deepEqual(activity.snapshot().events, []);
  const finish = start();
  time = 101;
  assert.equal(activity.snapshot(3).reset, true);
  assert.equal(activity.snapshot().activeRequests.length, 1);
  finish(true);
  assert.equal(activity.snapshot().activeRequests.length, 0);
  assert.equal(activity.snapshot(999).reset, true);
});

test('activity admission is bounded, excludes unknown tools and never uses a path as Folder ID', () => {
  const activity = new GateActivity('main', { activeCapacity: 1 });
  activity.start({ clientID: 'c', tool: 'unknown' })(true);
  activity.start({ tool: 'read_file' })(true);
  assert.equal(activity.cursor, 0);
  const finish = activity.start({ clientID: 'c', workspaceID: '/SECRET/PATH', tool: 'read_file' });
  activity.start({ clientID: 'd', tool: 'read_file' })(true);
  assert.equal(activity.active.size, 1); assert.equal(activity.cursor, 1);
  assert.equal(activity.snapshot().activeRequests[0].workspaceID, null);
  finish(false); assert.equal(activity.active.size, 0);
});
