// Regenerates BitToolSigner/Resources/THIRD_PARTY_LICENSES.txt from the packages the
// engine bundle actually includes (engine/bundle-manifest.json inputs), so the
// notices page in Settings always matches the shipped bundle.
// Run: node scripts/build-third-party-licenses.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'engine/bundle-manifest.json'), 'utf8'));
const LICENSE_FILES = ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENCE', 'LICENCE.md', 'LICENSE-MIT', 'COPYING', 'COPYING.md'];

/** The package directory an input path belongs to (nested node_modules included). */
function packageRoot(input) {
  const parts = input.split('/');
  const last = parts.lastIndexOf('node_modules');
  if (last < 0) return null;
  const scoped = parts[last + 1]?.startsWith('@');
  return parts.slice(0, last + (scoped ? 3 : 2)).join('/');
}

function licenseName(pkg) {
  if (typeof pkg.license === 'string') return pkg.license;
  if (pkg.license?.type) return pkg.license.type;
  if (Array.isArray(pkg.licenses)) return pkg.licenses.map(item => item?.type ?? item).filter(Boolean).join(', ');
  return 'See license text below';
}

function repository(pkg) {
  const repo = typeof pkg.repository === 'string' ? pkg.repository : pkg.repository?.url;
  return (repo ?? '').replace(/^git\+/, '').replace(/\.git$/, '');
}

const directories = [...new Set(manifest.inputs.map(packageRoot).filter(Boolean))].sort();
const entries = [];
for (const directory of directories) {
  const full = path.join(root, 'engine', directory);
  let pkg;
  try { pkg = JSON.parse(fs.readFileSync(path.join(full, 'package.json'), 'utf8')); }
  catch { continue; } // a bundled file that is not inside a package of its own
  const file = LICENSE_FILES.map(name => path.join(full, name)).find(fs.existsSync);
  const text = file ? fs.readFileSync(file, 'utf8').trim()
    : 'License file not present in the package; see the package repository above.';
  const name = pkg.name ?? path.basename(full), version = pkg.version ?? 'unknown';
  entries.push({ key: `${name}@${version}`, name, version, license: licenseName(pkg), repository: repository(pkg), text });
}
entries.sort((a, b) => a.key.localeCompare(b.key));

const divider = '='.repeat(72);
const header = ['BitTool Signer JavaScript engine — third-party notices', '',
  `Generated from the packages included in the engine bundle (${entries.length} packages).`,
  'Full license text is reproduced where the package ships one.', ''].join('\n');
const body = entries.map(entry => [divider, `${entry.name} ${entry.version} — ${entry.license}`,
  entry.repository, '', entry.text, ''].filter(line => line !== undefined).join('\n')).join('\n');
fs.writeFileSync(path.join(root, 'BitToolSigner/Resources/THIRD_PARTY_LICENSES.txt'), `${header}\n${body}\n`);
console.log(`Wrote ${entries.length} entries.`);
