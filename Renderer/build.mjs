import { build } from "esbuild";
import { mkdir, copyFile, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const target = "Bundle";
await mkdir(target, { recursive: true });
await build({
  entryPoints: { preview: "preview.mjs", quicklook: "quicklook.mjs" },
  bundle: true, minify: true, target: "safari17", outdir: target
});
for (const file of ["preview.html", "paper.css"]) await copyFile(file, join(target, file));
await copyFile("node_modules/mermaid/dist/mermaid.min.js", join(target, "mermaid.min.js"));

const lock = JSON.parse(await readFile("package-lock.json", "utf8"));
const notices = [];
for (const [path, info] of Object.entries(lock.packages)) {
  if (!path || info.dev || info.optional) continue;
  const licenses = (await readdir(path)).filter(file => /^(license|copying|notice)(\.|$)/i.test(file));
  const terms = await Promise.all(licenses.map(file => readFile(join(path, file), "utf8")));
  notices.push(path.split("node_modules/").at(-1) + " " + info.version + "\n" + (terms.join("\n\n") || info.license || ""));
}
await writeFile(join(target, "Third-Party Notices.txt"), notices.join("\n\n" + "=".repeat(72) + "\n\n") + "\n");
