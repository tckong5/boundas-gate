import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomBytes } from 'node:crypto';

export const gatewayDirectory = process.env.BOUNDAS_GATEWAY_DIR ?? path.join(os.homedir(), 'Library/Application Support/C2C Workspace Manager/gateway');
export const workspaceFile = process.env.BOUNDAS_WORKSPACES_FILE ?? path.join(os.homedir(), 'Library/Application Support/C2C Workspace Manager/workspaces.json');
export function secureWrite(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
  fs.renameSync(temporary, file);
}
export class Registry {
  constructor({ directory = gatewayDirectory, allowlistFile = workspaceFile } = {}) { this.directory = directory; this.allowlistFile = allowlistFile; }
  ensure() {
    const existing = this.read();
    if (existing) return existing;
    const config = { id: randomBytes(6).toString('hex'), roots: [] };
    secureWrite(path.join(this.directory, 'config.json'), config);
    return config;
  }
  read() {
    let config;
    try { config = JSON.parse(fs.readFileSync(path.join(this.directory, 'config.json'), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw new Error('共用連線設定無效，已停止提供檔案存取。'); }
    if (!/^[a-f0-9]{12}$/.test(config.id) || !Array.isArray(config.roots) || config.roots.some(root =>
      !/^[a-f0-9]{12}$/.test(root.id) || !/^[a-f0-9]{32}$/.test(root.epoch) || typeof root.sourceID !== 'string' || typeof root.path !== 'string' || !path.isAbsolute(root.path) || typeof root.name !== 'string' || typeof root.enabled !== 'boolean'
      || (root.codeRequired !== undefined && typeof root.codeRequired !== 'boolean')
      || (root.codeEpoch !== undefined && !/^[a-f0-9]{32}$/.test(root.codeEpoch))
      || (root.codeRequired === true && !root.codeEpoch)) || new Set(config.roots.map(root => root.id)).size !== config.roots.length) {
      throw new Error('共用連線設定無效，已停止提供檔案存取。');
    }
    return config;
  }
  addedFolders() {
    try { const items = JSON.parse(fs.readFileSync(this.allowlistFile, 'utf8')); return Array.isArray(items) ? items : []; }
    catch { return []; } // Never use a stale allowlist when its file is missing or invalid.
  }
  available(root, added = this.addedFolders()) {
    return root.enabled && added.some(item => typeof item.id === 'string' && item.id.toLowerCase() === root.sourceID.toLowerCase() && item.c2cID === root.id && item.path === root.path);
  }
  active() { const added = this.addedFolders(); return (this.read()?.roots ?? []).filter(root => this.available(root, added)); }
  connection() {
    const config = this.read();
    const stableMCPURL = config?.stableMCPURL ?? config?.configuredMCPURL ?? null;
    if (stableMCPURL) {
      const url = new URL(stableMCPURL);
      if (url.protocol !== 'https:' || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$/.test(url.hostname)
          || url.port || url.username || url.password || url.search || url.hash || url.pathname !== `/c2c/${config.id}/mcp`) {
        throw new Error('已儲存嘅固定地址無效；未有更改連線或授權。');
      }
    }
    if (config?.desiredRunning !== undefined && typeof config.desiredRunning !== 'boolean'
        || config?.reconnectEnabled !== undefined && typeof config.reconnectEnabled !== 'boolean') throw new Error('自動重連設定無效。');
    return { stableMCPURL, desiredRunning: config?.desiredRunning ?? null, reconnectEnabled: config?.reconnectEnabled ?? true };
  }
  updateConnection(values) {
    const config = this.read();
    if (!config) throw new Error('請先儲存要共用嘅 Folders。');
    const current = this.connection();
    if (values.stableMCPURL && current.stableMCPURL && values.stableMCPURL !== current.stableMCPURL) {
      throw new Error('固定地址同原有 ChatGPT 設定唔一致；未有更改地址或授權。');
    }
    if (values.desiredRunning !== undefined && typeof values.desiredRunning !== 'boolean'
        || values.reconnectEnabled !== undefined && typeof values.reconnectEnabled !== 'boolean') throw new Error('自動重連設定無效。');
    if (values.stableMCPURL) {
      const url = new URL(values.stableMCPURL);
      if (url.protocol !== 'https:' || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$/.test(url.hostname)
          || url.port || url.username || url.password || url.search || url.hash || url.pathname !== `/c2c/${config.id}/mcp`) throw new Error('固定地址無效。');
    }
    secureWrite(path.join(this.directory, 'config.json'), { ...config, ...values });
  }
  configure(selected, Workspace) {
    if (!Array.isArray(selected) || selected.length > 200) throw new Error('Folder 清單無效。');
    const added = this.addedFolders();
    const previous = this.read() ?? { id: randomBytes(6).toString('hex'), roots: [] };
    const enabled = selected.map(sourceID => {
      if (typeof sourceID !== 'string') throw new Error('Folder ID 無效。');
      const item = added.find(folder => typeof folder.id === 'string' && folder.id.toLowerCase() === sourceID.toLowerCase());
      if (!item) throw new Error('只可以共用已經 Add Folder 嘅資料夾。');
      const workspace = new Workspace(item.path);
      if (workspace.root !== item.path || workspace.id !== item.c2cID) throw new Error('Folder 位置變咗，請重新加入。');
      const old = previous.roots.find(root => root.id === workspace.id);
      return { id: workspace.id, sourceID: item.id.toLowerCase(), name: item.name, path: workspace.root, enabled: true,
        codeRequired: old?.codeRequired ?? false, codeEpoch: old?.codeEpoch ?? randomBytes(16).toString('hex'),
        epoch: old?.enabled && old.sourceID.toLowerCase() === item.id.toLowerCase() && old.path === workspace.root ? old.epoch : randomBytes(16).toString('hex') };
    });
    if (new Set(enabled.map(root => root.id)).size !== enabled.length) throw new Error('Folder 清單有重複項目。');
    const disabled = previous.roots.filter(root => !enabled.some(item => item.id === root.id)).map(root => ({ ...root, enabled: false, epoch: root.enabled ? randomBytes(16).toString('hex') : root.epoch }));
    const config = { ...previous, roots: [...enabled, ...disabled] };
    secureWrite(path.join(this.directory, 'config.json'), config);
    return config;
  }
  connectionScope() { return `bg.instance.${this.read().id}`; }
  requireConnection(scopes) {
    if (!scopes?.includes(this.connectionScope())) throw Object.assign(new Error('呢個 client 未獲授權連接 Boundas Gate。'), { code: 'INSTANCE_NOT_AUTHORIZED' });
  }
  setCodePolicy(id, required) {
    if (typeof required !== 'boolean') throw new Error('通行碼設定無效。');
    const config = this.read();
    const added = this.addedFolders();
    const root = config?.roots.find(item => item.id === id && added.some(folder => folder.c2cID === id && folder.path === item.path && folder.id.toLowerCase() === item.sourceID.toLowerCase()));
    if (!root) throw new Error('請先加入呢個 Folder。');
    if ((root.codeRequired ?? false) === required) return root;
    const updated = { ...root, codeRequired: required, codeEpoch: randomBytes(16).toString('hex') };
    secureWrite(path.join(this.directory, 'config.json'), { ...config, roots: config.roots.map(item => item.id === id ? updated : item) });
    return updated;
  }
  ensureFolderPolicy(record) {
    const config = this.ensure();
    const old = config.roots.find(root => root.id === record.c2cID);
    if (!this.addedFolders().some(folder => folder.id === record.id && folder.c2cID === record.c2cID && folder.path === record.path)) throw new Error('Folder 未加入。');
    if (old) {
      if (old.path !== record.path) throw new Error('Folder policy 路徑不符。');
      if (old.sourceID === record.id.toLowerCase()) return old;
      const updated = { ...old, sourceID: record.id.toLowerCase(), name: record.name,
        enabled: false, epoch: randomBytes(16).toString('hex'), codeEpoch: randomBytes(16).toString('hex') };
      secureWrite(path.join(this.directory, 'config.json'), { ...config, roots: config.roots.map(root => root.id === old.id ? updated : root) });
      return updated;
    }
    const root = { id: record.c2cID, sourceID: record.id.toLowerCase(), name: record.name, path: record.path,
      enabled: false, epoch: randomBytes(16).toString('hex'), codeRequired: false, codeEpoch: randomBytes(16).toString('hex') };
    secureWrite(path.join(this.directory, 'config.json'), { ...config, roots: [...config.roots, root] });
    return root;
  }
  revokeSource(sourceID) {
    if (typeof sourceID !== 'string') throw new Error('Folder ID 無效。');
    const config = this.read();
    if (!config) return;
    const roots = config.roots.map(root => root.sourceID.toLowerCase() === sourceID.toLowerCase()
      ? { ...root, enabled: false, epoch: root.enabled ? randomBytes(16).toString('hex') : root.epoch } : root);
    secureWrite(path.join(this.directory, 'config.json'), { ...config, roots });
  }
  authorized(id, scopes) {
    this.requireConnection(scopes);
    const root = this.read()?.roots.find(item => item.id === id);
    if (!root || !this.available(root)) throw Object.assign(new Error('呢個 Folder 未有分享，或者已停止分享。'), { code: 'WORKSPACE_NOT_AUTHORIZED' });
    return root;
  }
}
