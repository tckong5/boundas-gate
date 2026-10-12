import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { secureWrite, fileIdentity } from './registry.mjs';

// One Side Gate, one Folder; sharing membership and policy remain independent.
export class SideRegistry {
  sideMode = true;
  constructor(main, sourceID, directory) { this.main = main; this.sourceID = sourceID; this.directory = directory; }
  record() {
    const record = this.main.addedFolders().find(folder => folder.id?.toLowerCase() === this.sourceID.toLowerCase());
    if (!record?.sideGateAdded || record.sideGateRemovalState) throw new Error('Side Gate 未啟用。');
    return record;
  }
  ensure() {
    const record = this.record();
    if (record.c2cID === this.main.ensure().id) throw new Error('Main / Side Gate identity collision.');
    this.main.ensureFolderPolicy(record);
    let config; try { config = JSON.parse(fs.readFileSync(path.join(this.directory, 'config.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const endpoint = config?.stableMCPURL ?? config?.configuredMCPURL ?? record.configuredMCPURL ?? record.lastObservedMCPURL;
    const tailscale = record.connectionProvider === 'tailscale' || (() => {
      try { return new URL(endpoint).hostname.endsWith('.ts.net'); } catch { return false; }
    })();
    const cloudflare = record.connectionProvider === 'cloudflare' || endpoint && !tailscale;
    const inferred = cloudflare ? 'cloudflare' : tailscale ? 'external' : undefined;
    if (!config) {
      secureWrite(path.join(this.directory, 'config.json'), { id: record.c2cID, epoch: randomBytes(16).toString('hex'),
        transport: inferred ?? 'shared',
        ...(!cloudflare && endpoint ? { stableMCPURL: endpoint } : {}), localOnly: !endpoint });
    } else if (!endpoint && [undefined, 'embedded'].includes(config.transport)) {
      secureWrite(path.join(this.directory, 'config.json'), { ...config, transport: 'shared' });
    } else if (config.transport === undefined && inferred) {
      // Import legacy provider evidence without changing its identity or epoch.
      if (config.id !== record.c2cID || !/^[a-f0-9]{32}$/.test(config.epoch)) throw new Error('Side Gate 設定無效。');
      secureWrite(path.join(this.directory, 'config.json'), { ...config, transport: inferred,
        ...(!cloudflare && endpoint ? { stableMCPURL: endpoint } : {}) });
    }
    return this.read();
  }
  read() {
    const record = this.record();
    const state = JSON.parse(fs.readFileSync(path.join(this.directory, 'config.json'), 'utf8'));
    if (state.id !== record.c2cID || !/^[a-f0-9]{32}$/.test(state.epoch)) throw new Error('Side Gate 設定無效。');
    const policy = this.main.read()?.roots.find(root => root.id === record.c2cID && root.sourceID === this.sourceID.toLowerCase()
      && (!root.fileIdentity || !record.folderFileIdentity || root.fileIdentity === record.folderFileIdentity)
      && (!root.fileIdentity || fileIdentity(record.path) === root.fileIdentity));
    if (!policy) throw new Error('Folder Passcode policy 未能確認，未有開放存取。');
    return { ...state, roots: [{ id: record.c2cID, sourceID: this.sourceID.toLowerCase(), path: record.path, name: record.name,
      fileIdentity: record.folderFileIdentity ?? policy.fileIdentity, enabled: true, epoch: state.epoch, codeRequired: policy.codeRequired ?? false, codeEpoch: policy.codeEpoch }] };
  }
  active() { try { return this.read().roots; } catch { return []; } }
  connection() {
    const state = this.read();
    return { stableMCPURL: state.transport === 'cloudflare' ? null : state.stableMCPURL ?? null,
      desiredRunning: typeof state.desiredRunning === 'boolean' ? state.desiredRunning : null,
      localOnly: state.localOnly ?? !state.stableMCPURL, reconnectEnabled: state.reconnectEnabled !== false,
      connectionVersion: 1 };
  }
  updateConnection(values) {
    const file = path.join(this.directory, 'config.json');
    const current = JSON.parse(fs.readFileSync(file, 'utf8'));
    // Quick Tunnel remains temporary. Fixed endpoints stay bound to the Gate.
    this.record();
    if (current.transport !== 'cloudflare' && current.stableMCPURL && values.stableMCPURL !== undefined
        && values.stableMCPURL !== current.stableMCPURL) throw new Error('Side Gate 固定地址不符，未有改動授權。');
    const update = { ...values };
    if (current.transport === 'cloudflare') delete update.stableMCPURL;
    secureWrite(file, { ...current, ...update });
  }
  requireConnection(scopes) {
    // Legacy Side tokens carry operation scopes only. Bearer middleware verifies
    // the independent Side AuthStore + Gate ID before this adapter is reached.
    if (!scopes || scopes.some(scope => scope.startsWith('bg.instance.') && scope !== `bg.instance.${this.read().id}`)) throw new Error('Gate 授權身份不符。');
    this.record();
  }
  authorized(id, scopes) {
    this.requireConnection(scopes);
    const root = this.active().find(root => root.id === id);
    if (!root) throw Object.assign(new Error('Folder 未獲呢個 Gate 授權。'), { code: 'WORKSPACE_NOT_AUTHORIZED' });
    return root;
  }
  setCodePolicy(id, required) { if (id !== this.record().c2cID) throw new Error('Folder 身份不符。'); return this.main.setCodePolicy(id, required); }
}
