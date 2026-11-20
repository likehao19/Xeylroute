export const normalizedProgramPath = path => String(path || '').replaceAll('\\', '/').toLowerCase();

/**
 * Extract the outermost macOS `.app/` bundle root (e.g. `/applications/google chrome.app/`)
 * so nested helper apps inside `Contents/Frameworks/.../Helper.app/` group into the main app.
 * @param {string} normalizedPath
 */
function macosBundleRoot(normalizedPath) {
  const match = normalizedPath.match(/^.*?\/[^/]+\.app\//);
  return match ? match[0] : undefined;
}

/**
 * Score how likely an executable is to be the primary binary inside a package/bundle.
 * Lower score wins.
 * @param {string} path
 * @param {string | undefined} bundleRoot
 */
function primaryRank(path, bundleRoot) {
  if (!bundleRoot) return 0;
  const rel = path.slice(bundleRoot.length);
  if (rel.startsWith('contents/macos/') && !rel.includes('helper')) return 0;
  if (rel.startsWith('contents/macos/')) return 1;
  if (!rel.includes('/frameworks/') && !rel.includes('helper')) return 2;
  return 3;
}

/**
 * @template {{path:string, name:string, exe:string}} T
 * @param {T[]} processes
 */
export function groupRunningApps(processes) {
  /** @type {Map<string, T[]>} */
  const paths = new Map();
  for (const process of processes) {
    const path = normalizedProgramPath(process.path);
    if (paths.has(path)) paths.get(path).push(process);
    else paths.set(path, [process]);
  }
  const executables = [...paths].map(([path, members]) => {
    const winPackage = path.match(/^.*?\/windowsapps\/[^/]+_[^/]+\//)?.[0];
    const macBundle = macosBundleRoot(path);
    return {
      path,
      members,
      directory: path.slice(0, path.lastIndexOf('/')),
      stem: path.slice(path.lastIndexOf('/') + 1).replace(/\.exe$/, ''),
      packageRoot: winPackage || macBundle,
      macBundle,
    };
  });
  /** @type {Map<string, (typeof executables)[number][]>} */
  const applications = new Map();
  for (const entry of executables) {
    const owner = entry.packageRoot ? undefined : executables
      .filter(candidate => !candidate.packageRoot
        && candidate.directory.endsWith('/' + candidate.stem)
        && (entry.directory === candidate.directory || entry.directory.startsWith(candidate.directory + '/'))
        && (entry.stem.startsWith(candidate.stem + '_') || entry.stem.startsWith(candidate.stem + '-')))
      .sort((a, b) => b.directory.length - a.directory.length)[0];
    const key = entry.packageRoot || owner?.path || entry.path;
    const group = applications.get(key) || [];
    group.push(entry);
    applications.set(key, group);
  }
  return [...applications].map(([owner, group]) => {
    group.sort((a, b) =>
      Number(b.path === owner) - Number(a.path === owner)
      || primaryRank(a.path, a.macBundle) - primaryRank(b.path, b.macBundle)
      || a.directory.length - b.directory.length
      || b.members.length - a.members.length
      || a.path.localeCompare(b.path)
    );
    const primary = group[0].members[0];
    const members = group.flatMap(entry => entry.members);
    return { ...primary, members, paths: group.map(entry => entry.members[0].path), instances: members.length };
  }).sort((a, b) => {
    const first = a.name.toLowerCase();
    const second = b.name.toLowerCase();
    return first === second ? 0 : first < second ? -1 : 1;
  });
}
