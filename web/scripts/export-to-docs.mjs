/**
 * Mirrors the Next.js static export into ../docs/web, which GitHub Pages
 * publishes.
 *
 * It mirrors rather than wipes-and-recopies. This repository lives under
 * ~/Documents, which iCloud Drive syncs: deleting the whole tree and writing
 * it back races the sync daemon, and iCloud resolves the race by resurrecting
 * its own copies beside the new ones as `index 2.html`, `_next 3/` and the
 * like. Twelve of those had already accumulated here. Copying over the top and
 * then removing only what the export no longer contains gives the daemon
 * nothing to conflict on, and the same sweep is what deletes removed routes,
 * stale hashed assets, and any conflict copy that appears anyway.
 */
import { cp, rm, mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = path.join(here, '..', 'out');
const destination = path.join(here, '..', '..', 'docs', 'web');

if (!existsSync(source)) {
  console.error('export-to-docs: no out/ directory. Run `next build` first.');
  process.exit(1);
}

/**
 * iCloud names a conflict copy after the original with a counter before the
 * extension: `index 2.html`, `_next 3/`, `__next._tree 2.txt`. Neither Next.js
 * nor anything under public/ ever emits a filename containing a space, so this
 * shape is unambiguous here, and a conflict copy must never reach the
 * published tree: it would ship a stale page at a URL nobody meant to serve.
 */
const isConflictCopy = (name) => / \d+(\.[^.]+)?$/.test(name);

await mkdir(destination, { recursive: true });
await cp(source, destination, {
  recursive: true,
  force: true,
  filter: (from) => !isConflictCopy(path.basename(from)),
});

/**
 * Every path the export produced, relative to its root, directories included.
 * Conflict copies are left out so the sweep below deletes any that landed here
 * before this filter existed.
 */
const inventory = async (dir, base = dir, into = new Set()) => {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (isConflictCopy(entry.name)) continue;
    const full = path.join(dir, entry.name);
    into.add(path.relative(base, full));
    if (entry.isDirectory()) await inventory(full, base, into);
  }
  return into;
};

/**
 * Remove anything the destination holds that the export does not. Directories
 * are pruned whole and not descended into, so a stale route costs one unlink.
 */
const sweep = async (dir, keep) => {
  let removed = 0;
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (!keep.has(path.relative(destination, full))) {
      await rm(full, { recursive: true, force: true });
      console.log(`export-to-docs: removed stale ${path.relative(destination, full)}`);
      removed += 1;
      continue;
    }
    if (entry.isDirectory()) removed += await sweep(full, keep);
  }
  return removed;
};

const stale = await sweep(destination, await inventory(source));

const walk = async (dir) => {
  let files = 0;
  let bytes = 0;
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      const nested = await walk(full);
      files += nested.files;
      bytes += nested.bytes;
    } else {
      files += 1;
      bytes += (await stat(full)).size;
    }
  }
  return { files, bytes };
};

/**
 * The direction contract, stamped into every published document.
 *
 * It is written here rather than in the React tree because React cannot emit a
 * bare HTML comment as a node, and the contract belongs at the top of <body>
 * in the artifact a visitor actually receives — not inside a wrapper element
 * added only to carry it.
 */
const CONTRACT = `<!--
  ClashMax - direction contract

  THESIS          A proxy client is trusted when its mechanism is legible. The
                  page shows the mechanism instead of claiming the outcome.
  OWN-WORLD       Sectional. The page is a working aeronautical chart of the
                  visitor's own traffic: rules are airspace boundaries, nodes
                  are waypoints, DIRECT / PROXY / REJECT are three clearances.
                  Chart-paper ground, overprinted hairlines, airway blue from
                  the app icon, restricted magenta reserved for verdicts.
  STORY           Trace a request -> read the live edition -> see the console ->
                  learn the source YAML is untouched -> tour the surfaces ->
                  read the boundaries out loud -> install in four steps.
  FIRST VIEWPORT  One plate, not a card grid: the routing chart, operated.
                  Pick a destination and the chart draws the request out of
                  127.0.0.1, across the boundary that matches it, into its
                  clearance.
  FORM            Everything drawn, nothing rendered. No shadow, no glass, no
                  glow anywhere in the stylesheet. Colour is rationed to
                  clearances; state reads in line form first, hue second.
                  Plates and mats are square, controls are pill, and there is
                  no third radius. Foreign material - the screenshot, the app
                  replicas - mats in behind one hairline and a numbered figure
                  caption, and speaks macOS inside the mat because that is what
                  it reproduces.
  FINISH          One authored motion moment: the route draws itself along its
                  own path when a destination changes. Live release figures
                  settle with instrument damping rather than blinking in.
                  Both locales are real prerendered documents with their own
                  lang, metadata, and hreflang pair.
  SEED            2369b4de
-->`;

const stampContract = async (dir) => {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await stampContract(full);
    } else if (entry.name.endsWith('.html')) {
      const html = await readFile(full, 'utf8');
      const at = html.indexOf('<body');
      if (at === -1) continue;
      const open = html.indexOf('>', at);
      if (open === -1) continue;
      await writeFile(
        full,
        `${html.slice(0, open + 1)}${CONTRACT}${html.slice(open + 1)}`,
        'utf8',
      );
    }
  }
};

await stampContract(destination);

const { files, bytes } = await walk(destination);
console.log(
  `export-to-docs: ${files} files, ${(bytes / 1024).toFixed(0)} KB -> docs/web` +
    (stale ? ` (swept ${stale} stale ${stale === 1 ? 'entry' : 'entries'})` : ''),
);
