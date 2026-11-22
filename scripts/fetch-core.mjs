// Prepares the pinned Mihomo sidecar in src-tauri/binaries/. Windows builds from the
// pinned source with the process routing patches. Other targets use the official archive.
//
//   node scripts/fetch-core.mjs [--target <rust-triple>]
// Cached archives are verified against the official release digest on every build.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LOCK_PATH = path.join(ROOT, 'scripts', 'core-lock.json');
const OUT_DIR = path.join(ROOT, 'src-tauri', 'binaries');
const MAX_ARCHIVE_BYTES = 80 * 1024 * 1024;
const MAX_BINARY_BYTES = 200 * 1024 * 1024;
const sha256 = data => createHash('sha256').update(data).digest('hex');

/** Rust target triple -> [Mihomo platform tag, archive extension]. */
const TARGETS = {
  'aarch64-apple-darwin': ['darwin-arm64', 'gz'],
  'x86_64-apple-darwin': ['darwin-amd64-compatible', 'gz'],
  'x86_64-pc-windows-msvc': ['windows-amd64-compatible', 'zip'],
  'aarch64-pc-windows-msvc': ['windows-arm64', 'zip'],
  'x86_64-unknown-linux-gnu': ['linux-amd64-compatible', 'gz'],
  'aarch64-unknown-linux-gnu': ['linux-arm64', 'gz'],
};

export function assetFor(triple, version) {
  const entry = TARGETS[triple];
  if (!entry) {
    throw new Error(`No Mihomo build is mapped for target ${triple}. Supported: ${Object.keys(TARGETS).join(', ')}`);
  }
  const [tag, extension] = entry;
  return `mihomo-${tag}-${version}.${extension}`;
}

export function sidecarName(triple) {
  return `xeylroute-mihomo-${triple}${triple.includes('windows') ? '.exe' : ''}`;
}

/**
 * Extracts the single Mihomo executable from a zip archive held in memory.
 * Reads the central directory, so entries written with a trailing data descriptor work too.
 */
export function unzipExecutable(archive) {
  const EOCD = 0x06054b50;
  const CENTRAL = 0x02014b50;
  const LOCAL = 0x04034b50;
  let end = -1;
  for (let i = archive.length - 22; i >= Math.max(0, archive.length - 22 - 0xffff); i--) {
    if (archive.readUInt32LE(i) === EOCD) {
      end = i;
      break;
    }
  }
  if (end < 0) throw new Error('The archive is not a zip file.');
  const count = archive.readUInt16LE(end + 10);
  let cursor = archive.readUInt32LE(end + 16);
  const matches = [];
  for (let n = 0; n < count; n++) {
    if (cursor + 46 > archive.length || archive.readUInt32LE(cursor) !== CENTRAL) {
      throw new Error('The zip directory is damaged.');
    }
    const method = archive.readUInt16LE(cursor + 10);
    const compressedSize = archive.readUInt32LE(cursor + 20);
    const size = archive.readUInt32LE(cursor + 24);
    const nameLength = archive.readUInt16LE(cursor + 28);
    const extraLength = archive.readUInt16LE(cursor + 30);
    const commentLength = archive.readUInt16LE(cursor + 32);
    const localOffset = archive.readUInt32LE(cursor + 42);
    const name = archive.toString('utf8', cursor + 46, cursor + 46 + nameLength);
    const base = name.split('/').pop() || '';
    if (/^mihomo.*\.exe$/i.test(base)) matches.push({ method, compressedSize, size, localOffset });
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  if (matches.length !== 1) throw new Error(`Expected exactly one Mihomo executable in the archive, found ${matches.length}.`);
  const [{ method, compressedSize, size, localOffset }] = matches;
  if (size > MAX_BINARY_BYTES) throw new Error('The executable in the archive is larger than expected.');
  if (localOffset + 30 > archive.length || archive.readUInt32LE(localOffset) !== LOCAL) {
    throw new Error('The zip entry is damaged.');
  }
  const start = localOffset + 30 + archive.readUInt16LE(localOffset + 26) + archive.readUInt16LE(localOffset + 28);
  const data = archive.subarray(start, start + compressedSize);
  if (data.length !== compressedSize) throw new Error('The zip entry is truncated.');
  const binary = method === 0
    ? Buffer.from(data)
    : method === 8
      ? zlib.inflateRawSync(data, { maxOutputLength: MAX_BINARY_BYTES })
      : null;
  if (!binary) throw new Error(`Unsupported zip compression method ${method}.`);
  if (binary.length !== size) throw new Error('The extracted executable has the wrong size.');
  return binary;
}

export function extractBinary(asset, archive) {
  if (asset.endsWith('.zip')) return unzipExecutable(archive);
  return zlib.gunzipSync(archive, { maxOutputLength: MAX_BINARY_BYTES });
}

function hostTriple() {
  if (process.env.TAURI_ENV_TARGET_TRIPLE) return process.env.TAURI_ENV_TARGET_TRIPLE;
  const info = execFileSync('rustc', ['-vV'], { encoding: 'utf8' });
  const host = info.match(/^host:\s*(\S+)$/m)?.[1];
  if (!host) throw new Error('Could not read the host target from `rustc -vV`.');
  return host;
}

function download(url) {
  return execFileSync('curl', [
    '--fail', '--location', '--silent', '--show-error', '--retry', '2',
    '--max-time', '180', '--max-filesize', String(MAX_ARCHIVE_BYTES), url,
  ], { maxBuffer: MAX_ARCHIVE_BYTES });
}

function verifiedDownload(name, url, expected) {
  const cache = path.join(OUT_DIR, name);
  let archive = fs.existsSync(cache) ? fs.readFileSync(cache) : null;
  if (!archive || sha256(archive) !== expected) {
    console.log(`Downloading ${name} ...`);
    archive = download(url);
    if (sha256(archive) !== expected) throw new Error(`SHA-256 mismatch for ${name}.`);
    const temporary = `${cache}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, archive);
    fs.renameSync(temporary, cache);
  }
  return { cache, archive };
}

function prepareWinDivert(lock) {
  const { version, binary, source } = lock.winDivert;
  const name = `WinDivert-${version.slice(1)}-A`;
  const { cache } = verifiedDownload(`${name}.zip`,
    `https://github.com/basil00/WinDivert/releases/download/${version}/${name}.zip`, binary);
  verifiedDownload('WinDivert-source.tar.gz',
    `https://codeload.github.com/basil00/WinDivert/tar.gz/refs/tags/${version}`, source);
  for (const [file, member] of [
    ['WinDivert.dll', 'x64/WinDivert.dll'], ['WinDivert64.sys', 'x64/WinDivert64.sys'],
    ['WinDivert-LICENSE.txt', 'LICENSE'],
  ]) {
    const destination = path.join(OUT_DIR, file);
    const contents = execFileSync('tar', ['-xOf', cache, `${name}/${member}`]);
    if (!fs.existsSync(destination) || !contents.equals(fs.readFileSync(destination))) {
      fs.writeFileSync(destination, contents);
    }
  }
}

function buildWindowsCore(triple, lock) {
  const { revision, go } = lock.windowsSource;
  const patches = ['mihomo-process-instance.patch', 'mihomo-windows-tun.patch', 'mihomo-failure-fallback.patch']
    .map(filename => path.join(ROOT, 'scripts', filename));
  const patchHashes = patches.map(filename => sha256(fs.readFileSync(filename)));
  const buildKey = sha256([revision, go, triple, ...patchHashes].join(':'));
  const cached = path.join(OUT_DIR, `mihomo-windows-${buildKey}.exe`);
  const digest = `${cached}.sha256`;
  if (fs.existsSync(cached) && fs.existsSync(digest)) {
    const binary = fs.readFileSync(cached);
    if (sha256(binary) === fs.readFileSync(digest, 'utf8').trim()) return binary;
  }
  const goEnv = { ...process.env, GOTOOLCHAIN: 'local' };
  const version = execFileSync('go', ['version'], { env: goEnv, encoding: 'utf8' });
  if (!version.startsWith(`go version ${go} `)) {
    throw new Error(`The Windows Mihomo build needs ${go}. Found: ${version.trim()}`);
  }

  const work = fs.mkdtempSync(path.join(OUT_DIR, '.mihomo-build-'));
  try {
    const source = path.join(work, 'source');
    const output = path.join(work, 'mihomo.exe');
    const repository = 'https://github.com/MetaCubeX/mihomo.git';
    execFileSync('git', ['-c', 'core.autocrlf=false', 'clone', '--quiet', '--depth', '1',
      '--branch', lock.version, repository, source], { stdio: 'inherit' });
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: source, encoding: 'utf8' }).trim();
    if (head !== revision) throw new Error(`Unexpected Mihomo source revision: ${head}`);
    for (const patch of patches) {
      execFileSync('git', ['apply', '--unidiff-zero', patch], { cwd: source, stdio: 'inherit' });
    }
    execFileSync('go', ['build', '-p', '2', '-tags', 'with_gvisor', '-trimpath',
      '-ldflags', `-s -w -buildid= -X github.com/metacubex/mihomo/constant.Version=${lock.version}-xeylroute`,
      '-o', output, '.'], {
      cwd: source, stdio: 'inherit',
      env: { ...goEnv, GOOS: 'windows', GOARCH: triple.startsWith('aarch64') ? 'arm64' : 'amd64',
        CGO_ENABLED: '0', GOAMD64: 'v1' },
    });
    const binary = fs.readFileSync(output);
    fs.renameSync(output, cached);
    fs.writeFileSync(digest, sha256(binary));
    return binary;
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

async function main() {
  const args = process.argv.slice(2);
  const targetIndex = args.indexOf('--target');
  const triple = targetIndex >= 0 ? args[targetIndex + 1] : hostTriple();
  if (!triple) throw new Error('--target needs a Rust target triple.');

  const lock = JSON.parse(fs.readFileSync(LOCK_PATH, 'utf8'));
  const asset = assetFor(triple, lock.version);
  const destination = path.join(OUT_DIR, sidecarName(triple));
  fs.mkdirSync(OUT_DIR, { recursive: true });
  if (triple.includes('windows')) {
    prepareWinDivert(lock);
    const binary = buildWindowsCore(triple, lock);
    if (!fs.existsSync(destination) || sha256(fs.readFileSync(destination)) !== sha256(binary)) {
      const temporary = `${destination}.${process.pid}.tmp`;
      fs.writeFileSync(temporary, binary, { mode: 0o755 });
      fs.renameSync(temporary, destination);
    }
    console.log(`Mihomo ${lock.version} with Windows process routing is ready at ${path.relative(ROOT, destination)}.`);
    return;
  }
  const expected = lock.assets[asset];
  if (!expected) throw new Error(`Missing release digest for ${asset}.`);
  const { archive } = verifiedDownload(asset,
    `https://github.com/MetaCubeX/mihomo/releases/download/${lock.version}/${asset}`, expected);

  const binary = extractBinary(asset, archive);
  const temporary = `${destination}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, binary, { mode: 0o755 });
  fs.renameSync(temporary, destination);
  console.log(`Mihomo ${lock.version} is ready at ${path.relative(ROOT, destination)} (${(binary.length / 1048576).toFixed(1)} MB).`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    console.error(error.message || error);
    process.exit(1);
  });
}
