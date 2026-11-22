import { build } from "esbuild";
import { mkdir, copyFile, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const target = "Bundle";
await mkdir(target, { recursive: true });
const { metafile } = await build({
  entryPoints: { preview: "preview.mjs", quicklook: "quicklook.mjs", "mermaid.min": "mermaid.mjs" },
  bundle: true, minify: true, target: "safari17", outdir: target, metafile: true, legalComments: "eof"
});
for (const file of ["preview.html", "paper.css"]) await copyFile(file, join(target, file));

const lock = JSON.parse(await readFile("package-lock.json", "utf8"));
const packageName = path => lock.packages[path].name ?? path.split("node_modules/").at(-1);
const packageLabel = path => packageName(path) + " " + lock.packages[path].version;
const lockedPaths = new Map(Object.keys(lock.packages).filter(Boolean).map(path => [packageLabel(path), path]));
const packages = new Map();
const bundledSources = new Set();
for (const output of Object.values(metafile.outputs)) {
  for (const [source, { bytesInOutput }] of Object.entries(output.inputs)) {
    if (!bytesInOutput) continue;
    const path = source.match(/^(.*\bnode_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1];
    if (!path) continue;
    if (!lock.packages[path]?.version) throw new Error(`Bundled package is missing from package-lock.json: ${path}`);
    packages.set(packageLabel(path), path);
    bundledSources.add(source);
  }
}

const embeddedPackagePath = /node_modules\/\.pnpm\/(?:@[^+/]+\+)?[^@/]+@([^_/]+)[^/]*\/node_modules\/((?:@[^/]+\/)?[^/]+)\//;
for (const source of bundledSources) {
  const text = await readFile(source + ".map", "utf8").catch(error => {
    if (error.code !== "ENOENT") throw error;
  });
  if (!text) continue;
  const map = JSON.parse(text);
  for (const [index, origin] of (map.sources ?? []).entries()) {
    if (origin === "webpack://LIB/node_modules/path-browserify/index.js") {
      const path = "node_modules/mermaid-notice-path-browserify";
      if (!lock.packages[path]?.version || map.sourcesContent?.[index] !== await readFile(join(path, "index.js"), "utf8")) {
        throw new Error(`Embedded path-browserify does not match package-lock.json in ${source}`);
      }
      packages.set(packageLabel(path), path);
      continue;
    }
    const match = origin.match(embeddedPackagePath);
    if (!match) {
      if (origin.includes("node_modules/")) throw new Error(`Unrecognized embedded package in ${source}: ${origin}`);
      continue;
    }
    const [, version, name] = match;
    const label = name + " " + version;
    if (packages.has(label)) continue;
    const path = lockedPaths.get(label);
    if (!path) throw new Error(`Embedded package is missing from package-lock.json: ${label} in ${source}`);
    packages.set(label, path);
  }
}

const notices = [];
for (const label of [...packages.keys()].sort()) {
  const path = packages.get(label);
  const manifest = JSON.parse(await readFile(join(path, "package.json"), "utf8"));
  if (manifest.name + " " + manifest.version !== label) throw new Error(`Installed package does not match ${label}: ${path}`);
  const licenses = (await readdir(path, { withFileTypes: true }))
    .filter(file => file.isFile() && /^(license|licence|copying|notice)([-_][\w-]+)?(\.(md|markdown|txt))?$/i.test(file.name))
    .map(file => file.name).sort();
  const terms = await Promise.all(licenses.map(file => readFile(join(path, file), "utf8")));
  if (!terms.length && manifest.name === "fastdom") {
    const readme = await readFile(join(path, "README.md"), "utf8");
    const license = readme.match(/^## License\r?\n\s*([\s\S]+)$/m)?.[1].trim();
    if (license) terms.push(license);
  }
  if (!terms.length) throw new Error(`Bundled package is missing license or notice files: ${path}`);
  if (manifest.name === "elkjs") {
    terms.push(`The elkjs source code is available under the Eclipse Public License 2.0 at\nhttps://github.com/kieler/elkjs/tree/${manifest.version}\n\nThe upstream Eclipse Layout Kernel source is at\nhttps://github.com/eclipse-elk/elk`);
  }
  notices.push(label + "\n" + terms.join("\n\n"));
}
await writeFile(join(target, "Third-Party Notices.txt"), notices.join("\n\n" + "=".repeat(72) + "\n\n") + "\n");
