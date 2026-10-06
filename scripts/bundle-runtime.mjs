import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const [backendInput, destination, nodeInput = process.execPath] = process.argv.slice(2);
if (!backendInput || !destination) throw new Error('Usage: bundle-runtime.mjs <verified-c2c-build> <Runtime-output> [node]');
const source = fs.realpathSync(backendInput), output = path.resolve(destination), node = fs.realpathSync(nodeInput);
if (!fs.existsSync(path.join(source, 'dist/cli/index.js'))) throw new Error('A compiled C2C backend is required.');
const nodeVersion = execFileSync(node, ['--version'], { encoding: 'utf8' }).trim();
if (Number(nodeVersion.slice(1).split('.')[0]) < 20) throw new Error('Node.js 20+ required.');
fs.mkdirSync(path.join(output, 'bin'), { recursive: true });
fs.mkdirSync(path.join(output, 'Licenses'), { recursive: true });
fs.copyFileSync(node, path.join(output, 'bin/node')); fs.chmodSync(path.join(output, 'bin/node'), 0o755);
const nodeLicense = path.join(path.dirname(path.dirname(node)), 'LICENSE');
if (!fs.existsSync(nodeLicense)) throw new Error('Node distribution LICENSE is required.');
fs.copyFileSync(nodeLicense, path.join(output, 'Licenses/Node.txt'));
const backend = path.join(output, 'C2C');
for (const item of ['bin', 'dist', 'LICENSE']) fs.cpSync(path.join(source, item), path.join(backend, item), { recursive: true, filter: file => !file.endsWith('.map') && !file.endsWith('.ts') });
const manifest = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'));
const packages = new Map();
const digest = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
function resolvePackage(name, owner) {
  for (let directory = owner; ; directory = path.dirname(directory)) {
    const candidate = path.join(directory, 'node_modules', name);
    if (fs.existsSync(path.join(candidate, 'package.json'))) return fs.realpathSync(candidate);
    if (path.dirname(directory) === directory) return null;
  }
}
function link(name, real, modules) {
  const target = copyPackage(real), alias = path.join(modules, name);
  fs.mkdirSync(path.dirname(alias), { recursive: true });
  if (!fs.existsSync(alias)) fs.symlinkSync(path.relative(path.dirname(alias), target), alias, 'dir');
}
function copyPackage(real) {
  if (packages.has(real)) return packages.get(real).target;
  const pkg = JSON.parse(fs.readFileSync(path.join(real, 'package.json'), 'utf8'));
  const key = `${encodeURIComponent(pkg.name)}@${pkg.version}-${createHash('sha256').update(path.relative(source, real)).digest('hex').slice(0, 8)}`;
  const modules = path.join(backend, 'node_modules/.bundled', key, 'node_modules');
  const target = path.join(modules, pkg.name);
  packages.set(real, { target, name: pkg.name, version: pkg.version, license: pkg.license ?? 'See included license', manifestSHA256: digest(path.join(real, 'package.json')) });
  fs.cpSync(real, target, { recursive: true, filter: file => path.relative(real, file).split(path.sep)[0] !== 'node_modules' });
  const optionalPeers = pkg.peerDependenciesMeta ?? {};
  const dependencies = { ...pkg.peerDependencies, ...pkg.dependencies, ...pkg.optionalDependencies };
  for (const name of Object.keys(dependencies)) {
    const dependency = resolvePackage(name, real);
    const optional = name in (pkg.optionalDependencies ?? {}) || optionalPeers[name]?.optional;
    if (!dependency && !optional) throw new Error(`Missing runtime dependency: ${pkg.name} -> ${name}`);
    if (dependency) link(name, dependency, modules);
  }
  return target;
}
const exactDependencies = {};
for (const name of Object.keys(manifest.dependencies)) {
  const real = resolvePackage(name, source); if (!real) throw new Error(`Missing C2C dependency: ${name}`);
  link(name, real, path.join(backend, 'node_modules'));
  exactDependencies[name] = JSON.parse(fs.readFileSync(path.join(real, 'package.json'))).version;
}
fs.writeFileSync(path.join(backend, 'package.json'), JSON.stringify({ name: manifest.name, version: manifest.version, type: 'module', license: manifest.license, dependencies: exactDependencies }, null, 2));
const cloudflared = process.env.BOUNDAS_CLOUDFLARED ?? ['/opt/homebrew/bin/cloudflared', '/usr/local/bin/cloudflared'].find(file => fs.existsSync(file));
if (!cloudflared) throw new Error('A verified cloudflared binary is required for the optional Quick Tunnel mode.');
fs.copyFileSync(fs.realpathSync(cloudflared), path.join(output, 'bin/cloudflared'));fs.chmodSync(path.join(output, 'bin/cloudflared'), 0o755);
const cloudVersion = execFileSync(cloudflared, ['--version'], { encoding: 'utf8' }).trim();
const cloudLicense = process.env.BOUNDAS_CLOUDFLARED_LICENSE ?? path.join(path.dirname(path.dirname(fs.realpathSync(cloudflared))), 'LICENSE');
if (!cloudLicense || !fs.existsSync(cloudLicense)) throw new Error('Cloudflared distribution LICENSE is required.');
fs.copyFileSync(cloudLicense, path.join(output, 'Licenses/Cloudflared.txt'));
fs.copyFileSync(path.join(source, 'LICENSE'), path.join(output, 'Licenses/C2C.txt'));
// Every dependency's original notices remain alongside its package files.
const record = { format: 1, backendVersion: manifest.version, backendEntrySHA256: digest(path.join(source, 'dist/cli/index.js')), nodeVersion, nodeSHA256: digest(node), cloudflaredVersion: cloudVersion, cloudflaredSHA256: digest(fs.realpathSync(cloudflared)), packages: [...packages.values()].map(({ target, ...pkg }) => pkg) };
fs.writeFileSync(path.join(output, 'runtime-manifest.json'), JSON.stringify(record, null, 2));
// A distributable runtime must contain no absolute links to the developer's home.
function validate(directory) { for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
  const file = path.join(directory, item.name);
  if (item.isSymbolicLink()) { const resolved = fs.realpathSync(file); if (!resolved.startsWith(output + path.sep)) throw new Error('Runtime dependency escaped bundle.'); }
  else if (item.isDirectory()) validate(file);
} }
validate(output);
console.log(JSON.stringify({ ok: true, backendVersion: manifest.version, nodeVersion, runtimePackages: packages.size }));
