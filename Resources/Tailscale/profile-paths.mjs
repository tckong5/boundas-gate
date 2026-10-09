import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const productDirectory = path.join(os.homedir(), 'Library/Application Support/Boundas Gate');

// Migration is completed by the app before it creates any runtime/store.
// A directly invoked child must fail closed, never create a second Gate identity.
export function requirePreparedProfile(directory = productDirectory) {
  let info;
  try { info = fs.lstatSync(directory); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (info) {
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Boundas Gate data location is invalid. No new Gate was started.');
    return directory;
  }
  const legacy = path.join(path.dirname(directory), 'C2C Workspace Manager');
  if (fs.existsSync(legacy)) throw new Error('Open Boundas Gate to migrate existing data before starting its runtime. Your legacy data has been preserved.');
  return directory;
}
export function defaultProductPath(component) {
  return path.join(requirePreparedProfile(), component);
}
