import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { TailscaleProvider, setupCheck } from './provider.mjs';

const [action, backendRoot, workspaceRoot] = process.argv.slice(2);
const output = value => process.stdout.write(`${JSON.stringify(value)}\n`);
if (action === 'preflight') {
  output(await setupCheck());
} else {
  try {
    const load = relative => import(pathToFileURL(path.join(backendRoot, 'dist', relative)).href);
    const [{ Workspace }, runtimeAPI, daemonAPI] = await Promise.all([load('workspace/manager.js'), load('bridge/runtime.js'), load('process/daemon.js')]);
    const workspace = new Workspace(workspaceRoot);
    if (action === 'daemon') {
      const { startBridge } = await load('bridge/server.js');
      const bridge = await startBridge({ workspaceRoot: workspace.root, port: 0, tunnelProvider: new TailscaleProvider(workspace.id) });
      let closing = false;
      const close = () => { if (!closing) { closing = true; void bridge.close().finally(() => process.exit(0)); } };
      process.on('SIGTERM', close); process.on('SIGINT', close);
    } else if (action === 'start') {
      const setup = await setupCheck();
      if (setup.state !== 'ready') throw new Error(setup.message);
      let observation = await runtimeAPI.findBridgeObservation(workspace.id);
      if (observation.state === 'unknown') throw new Error('未能確認現有連線狀態；未有啟動另一個連線。');
      if (observation.state === 'healthy') {
        const info = await daemonAPI.adminFetch(observation.runtime, 'GET', '/admin/info');
        if (info.tunnel.provider !== 'tailscale-funnel') throw new Error('請先停止現有臨時連線，再啟用固定地址。');
      } else {
        const logDir = path.join(path.dirname(runtimeAPI.runtimeFile(workspace.id)), '../logs');
        fs.mkdirSync(logDir, { recursive: true, mode: 0o700 });
        const logFile = path.join(logDir, `bridge-${workspace.id}.out.log`);
        const descriptor = fs.openSync(logFile, 'a', 0o600); fs.chmodSync(logFile, 0o600);
        const child = spawn(process.execPath, [fileURLToPath(import.meta.url), 'daemon', backendRoot, workspace.root], { detached: true, stdio: ['ignore', descriptor, descriptor], env: process.env });
        child.unref(); fs.closeSync(descriptor);
        const deadline = Date.now() + 20000;
        do {
          await new Promise(resolve => setTimeout(resolve, 300));
          observation = await runtimeAPI.findBridgeObservation(workspace.id);
        } while (observation.state !== 'healthy' && Date.now() < deadline && child.exitCode === null);
        if (observation.state !== 'healthy') throw new Error('本機連線未能啟動；請重新檢查。');
      }
      const { url } = await daemonAPI.adminFetch(observation.runtime, 'POST', '/admin/tunnel/start', 120000);
      output({ ok: true, mcpUrl: `${url}/mcp`, connectorName: `Boundas Gate · ${workspace.name}` });
    } else { throw new Error('Unknown action'); }
  } catch (error) {
    // The admin bridge returns a safe message, but not a structured approval URL.
    const message = error.message || '固定地址未能啟動。';
    output({ ok: false, message, approvalURL: error.approvalURL }); process.exitCode = 1;
  }
}
