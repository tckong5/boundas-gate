import { randomUUID } from 'node:crypto';

const categories = new Map([
  ['list_workspaces', 'Info'], ['unlock_workspace', 'Info'], ['workspace_info', 'Info'],
  ['list_directory', 'Read'], ['read_file', 'Read'], ['search_workspace', 'Search'],
  ['git_status', 'Git'], ['git_diff', 'Git'],
]);

// Ephemeral, bounded metadata only. Never accept tool arguments or results.
export class GateActivity {
  constructor(gateID, { now = Date.now, capacity = 512, activeCapacity = 256, retention = 60000 } = {}) {
    this.gateID = gateID; this.now = now; this.capacity = capacity;
    this.activeCapacity = activeCapacity; this.retention = retention;
    this.streamID = randomUUID(); this.cursor = 0; this.events = []; this.active = new Map();
  }
  append(event) {
    this.events.push({ ...event, sequence: ++this.cursor });
    const cutoff = this.now() - this.retention;
    while (this.events.length > this.capacity || this.events[0]?.timestamp < cutoff) this.events.shift();
  }
  start({ clientID, workspaceID, tool }) {
    if (typeof clientID !== 'string' || !clientID || clientID.length > 256 || !categories.has(tool)
        || this.active.size >= this.activeCapacity) return () => {};
    const startedAt = this.now();
    const request = { requestID: randomUUID(), gateID: this.gateID, clientID,
      workspaceID: typeof workspaceID === 'string' && /^[a-f0-9]{12}$/.test(workspaceID) ? workspaceID : null,
      tool: categories.get(tool), startedAt };
    this.active.set(request.requestID, request);
    this.append({ ...request, type: 'requestStarted', timestamp: startedAt });
    let finished = false;
    return success => {
      if (finished) return;
      finished = true; this.active.delete(request.requestID);
      const timestamp = this.now();
      this.append({ ...request, type: 'requestFinished', timestamp, success: success === true,
        duration: Math.max(0, timestamp - startedAt) });
    };
  }
  snapshot(since) {
    const cutoff = this.now() - this.retention;
    while (this.events[0]?.timestamp < cutoff) this.events.shift();
    const reset = since === undefined || since > this.cursor || since < (this.events[0]?.sequence ?? this.cursor + 1) - 1;
    return { version: 1, gateID: this.gateID, streamID: this.streamID, cursor: this.cursor, reset,
      events: reset ? [] : this.events.filter(event => event.sequence > since),
      activeRequests: [...this.active.values()] };
  }
}
