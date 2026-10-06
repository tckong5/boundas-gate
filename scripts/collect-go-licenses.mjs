import fs from 'node:fs';
import path from 'node:path';
const [input, output] = process.argv.slice(2);
const modules = JSON.parse(fs.readFileSync(input, 'utf8'));
const record = [];
for (const item of modules) {
  if (!item.Dir) continue;
  const notices = fs.readdirSync(item.Dir).filter(name => /^(LICENSE|LICENCE|COPYING|NOTICE|PATENTS|AUTHORS)([._-]|$)/i.test(name));
  const destination = path.join(output, encodeURIComponent(item.Path) + '@' + (item.Version ?? 'local'));
  fs.mkdirSync(destination, { recursive: true });
  for (const file of notices) fs.cpSync(path.join(item.Dir, file), path.join(destination, file), { recursive: true });
  record.push({ module: item.Path, version: item.Version, notices });
}
fs.writeFileSync(path.join(output, 'modules.json'), JSON.stringify(record, null, 2));
