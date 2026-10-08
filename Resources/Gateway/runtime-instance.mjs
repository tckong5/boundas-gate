import fs from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execute = promisify(execFile);
export function readRuntime(file) {
  let value;
  try { value = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw new Error('Gate 運行記錄無效，未有操作任何程序。'); }
  if (!Number.isInteger(value.pid) || value.pid < 1 || !Number.isInteger(value.port) || value.port < 1 || value.port > 65535
      || typeof value.adminToken !== 'string' || !/^(bg_admin_[a-f0-9]{64}|c2c_admin_[A-Za-z0-9_-]{32})$/.test(value.adminToken)
      || (value.instanceID !== undefined && (!/^[a-f0-9]{64}$/.test(value.instanceID) || !Number.isFinite(Date.parse(value.startedAt))))) {
    throw new Error('Gate 運行記錄無效，未有操作任何程序。');
  }
  return value;
}
export function clearOwnedRuntime(file, expected) {
  const current = readRuntime(file);
  if (current && current.pid === expected.pid && current.adminToken === expected.adminToken
      && current.instanceID === expected.instanceID) fs.rmSync(file, { force: true });
}
export async function processOwnership(runtime, entrypoint) {
  try {
    const { stdout } = await execute('/bin/ps', ['-p', String(runtime.pid), '-o', 'uid=,args='], { timeout: 2000, maxBuffer: 262144 });
    const match = /^\s*(\d+)\s+([\s\S]+)$/.exec(stdout);
    if (!match) return false;
    if (Number(match[1]) !== process.getuid() || !match[2].includes(`${entrypoint} daemon `)) return false;
    // Legacy daemons can be authenticated over admin HTTP, but a missing
    // endpoint cannot prove their identity from a bare PID or script name.
    if (!runtime.instanceID) return null;
    return match[2].includes(`--instance-id=${runtime.instanceID}`);
  } catch (error) {
    return error.code === 1 && !/permitted|permission/i.test(error.stderr ?? '') ? false : null;
  }
}
export async function observeRuntime(file, { gateID, service, entrypoint, getInfo, inspect = processOwnership, probe } = {}) {
  const runtime = readRuntime(file);
  if (!runtime) return { state: 'stopped', runtime: null };
  if (runtime.workspaceId !== gateID || runtime.service !== service) return { state: 'unknown', runtime, reason: 'Gate 運行記錄身份不符。' };
  let health;
  try {
    health = probe ? await probe(runtime) : await (await fetch(`http://127.0.0.1:${runtime.port}/health`, { signal: AbortSignal.timeout(2000) })).json();
  } catch {}
  const matched = health?.workspaceId === gateID && health?.service === service
    && (runtime.instanceID ? health.instanceID === runtime.instanceID : !health.instanceID);
  if (matched) {
    try {
      const info = await getInfo(runtime);
      if (runtime.instanceID && info.instanceID !== runtime.instanceID) throw new Error('instance_mismatch');
      if ((info.workspaceId !== undefined && info.workspaceId !== gateID)
          || (info.gatewayID !== undefined && info.gatewayID !== gateID)
          || (info.pid !== undefined && info.pid !== runtime.pid)) throw new Error('owner_mismatch');
      return { state: 'healthy', runtime, info, legacy: !runtime.instanceID };
    } catch { return { state: 'unknown', runtime, reason: '未能確認 Gate 管理端點，未有操作程序。' }; }
  }
  const ownership = await inspect(runtime, entrypoint);
  if (ownership === false) {
    clearOwnedRuntime(file, runtime);
    return { state: 'stopped', runtime: null, reason: 'stale_runtime_retired' };
  }
  return { state: 'unknown', runtime, reason: health ? 'Gate instance 身份不符，未有操作其他服務。' : 'Gate 暫時未有回應，未有操作程序。' };
}
