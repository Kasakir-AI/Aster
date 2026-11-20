import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { renderMarkdown } from "../Renderer/markdown.mjs";
import "../Renderer/quicklook.mjs";

test("renders tables, highlighting, task controls and duplicate heading anchors", () => {
  const input = "# Field notes\n\n- [ ] Review\n\n| X | Y |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 2\n```\n\n# Field notes";
  const html = renderMarkdown(input, { interactive: true });
  assert.match(html, /id="field-notes"/);
  assert.match(html, /id="field-notes-1"/);
  assert.match(html, /data-task-line="3"/);
  assert.match(html, /<table>/);
  assert.match(html, /hljs-keyword/);
});
test("heading ids drop punctuation and number duplicates the way the editor does", () => {
  const html = renderMarkdown("# Hello, World!\n\n# Hello, World!\n\n# !!!\n");
  assert.match(html, /id="hello-world"/);
  assert.match(html, /id="hello-world-1"/);
  assert.match(html, /id="heading"/);
});
test("escapes HTML and blocks remote images by default", () => {
  const html = renderMarkdown('<script>alert(1)</script>\n\n![Tracking](https://example.com/pixel.jpg)\n\n[Bad](javascript:alert%281%29)');
  assert.doesNotMatch(html, /<script|<img|href="javascript:/);
  assert.match(html, /Tracking/);
});
test("front matter preserves line numbers and formulas produce MathML", () => {
  const html = renderMarkdown("---\ntags: [science]\n---\n# Water\n\n$H_2O$");
  assert.match(html, /<details class="metadata">/);
  assert.match(html, /data-line="4"/);
  assert.match(html, /<math/);
});

test("the bundled preview starts dark before it receives view settings", () => {
  const page = readFileSync(new URL("../Renderer/preview.html", import.meta.url), "utf8");
  assert.match(page, /<html\b[^>]*\bdata-appearance="dark"/);
});

test("dark preview text clears 4.5:1 contrast against paper and code backgrounds", () => {
  const css = readFileSync(new URL("../Renderer/paper.css", import.meta.url), "utf8");
  const darkRule = css.match(/:root\[data-appearance="dark"\]\s*\{([^}]+)\}/)?.[1];
  assert.ok(darkRule, "Missing an explicit dark appearance");
  const colors = Object.fromEntries([...darkRule.matchAll(/--([\w-]+):\s*(#[\da-f]{6})\b/gi)]
    .map(([, name, color]) => [name, color]));
  const luminance = color => {
    assert.match(color ?? "", /^#[\da-f]{6}$/i);
    const channels = color.slice(1).match(/../g).map(hex => {
      const component = parseInt(hex, 16) / 255;
      return component <= 0.04045 ? component / 12.92 : ((component + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
  };
  for (const text of ["ink", "muted", "heading", "accent", "emphasis", "warm", "mint", "number"]) {
    for (const surface of ["page", "wash"]) {
      assert.ok(colors[text], `Missing dark ${text}`);
      const levels = [luminance(colors[text]), luminance(colors[surface])];
      const ratio = (Math.max(...levels) + 0.05) / (Math.min(...levels) + 0.05);
      assert.ok(ratio >= 4.5, `Dark ${text} on ${surface} has only ${ratio.toFixed(2)}:1 contrast`);
    }
  }
});

test("Finder previews render common Markdown syntax and noninteractive task controls", () => {
  const source = "Heading\n=======\n\n> *em* **strong** ~~strike~~\n\n- [x] done\n\n```js\nconst value = 'pastel'\n```";
  const html = globalThis.renderQuickLook(source);
  assert.match(html, /<h1\b[^>]*>Heading<\/h1>/);
  assert.match(html, /<blockquote\b/);
  assert.match(html, /<em>em<\/em> <strong>strong<\/strong> <s>strike<\/s>/);
  assert.match(html, /data-task-line="6" checked disabled/);
  assert.match(html, /class="hljs-string"/);
});
