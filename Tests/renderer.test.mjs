import assert from "node:assert/strict";
import { test } from "node:test";
import { renderMarkdown } from "../Renderer/markdown.mjs";

test("renders tables, highlighting, task controls and duplicate heading anchors", () => {
  const input = "# Field notes\n\n- [ ] Review\n\n| X | Y |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 2\n```\n\n# Field notes";
  const html = renderMarkdown(input, { interactive: true });
  assert.match(html, /id="field-notes"/);
  assert.match(html, /id="field-notes-1"/);
  assert.match(html, /data-task-line="3"/);
  assert.match(html, /<table>/);
  assert.match(html, /hljs-keyword/);
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
