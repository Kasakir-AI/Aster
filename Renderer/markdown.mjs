import MarkdownIt from "markdown-it";
import hljs from "highlight.js/lib/common";
import katex from "katex";

const escape = MarkdownIt().utils.escapeHtml;
const parser = new MarkdownIt({
  html: false,
  linkify: true,
  highlight(code, language) {
    if (hljs.getLanguage(language)) return hljs.highlight(code, { language }).value;
    return escape(code);
  }
});

parser.inline.ruler.before("escape", "wikilink", (state, silent) => {
  if (state.src[state.pos - 1] === "!" || !state.src.startsWith("[[", state.pos)) return false;
  const end = state.src.indexOf("]]", state.pos + 2);
  if (end === -1 || end >= state.posMax) return false;
  const body = state.src.slice(state.pos + 2, end);
  if (!body.trim() || /[\n\[\]]/.test(body)) return false;
  const bar = body.indexOf("|");
  const target = (bar === -1 ? body : body.slice(0, bar)).trim();
  const label = (bar === -1 ? body : body.slice(bar + 1)).trim();
  if (!target || !label) return false;
  if (!silent) {
    const open = state.push("link_open", "a", 1);
    open.attrSet("href", "aster-wiki:" + encodeURIComponent(target));
    const text = state.push("text", "", 0);
    text.content = label;
    state.push("link_close", "a", -1);
  }
  state.pos = end + 2;
  return true;
});

parser.inline.ruler.before("escape", "formula", (state, silent) => {
  if (state.env.math === false || state.src[state.pos] !== "$") return false;
  const marker = state.src.startsWith("$$", state.pos) ? "$$" : "$";
  const start = state.pos + marker.length;
  let end = state.src.indexOf(marker, start + 1);
  while (end !== -1 && state.src[end - 1] === "\\") end = state.src.indexOf(marker, end + marker.length);
  if (end === -1 || end >= state.posMax) return false;
  const formula = state.src.slice(start, end);
  if (marker === "$" && (/^\s|\s$|\n/.test(formula) || /\d/.test(state.src[end + 1] ?? ""))) return false;
  if (!silent) {
    const token = state.push("formula", "", 0);
    token.content = formula;
    token.meta = marker === "$$";
  }
  state.pos = end + marker.length;
  return true;
});

parser.renderer.rules.formula = (tokens, index) => {
  const token = tokens[index];
  return katex.renderToString(token.content, {
    throwOnError: false, displayMode: token.meta, output: "mathml", trust: false, maxExpand: 250
  });
};

parser.renderer.rules.image = (tokens, index) => {
  const token = tokens[index];
  const source = token.attrGet("src");
  const label = escape(token.content || "Image");
  if (!source || /^(?:[a-z][a-z\d+.-]*:|\/)/i.test(source)) {
    return '<span class="image-placeholder">' + label + "</span>";
  }
  const address = "aster-asset://image/" + encodeURIComponent(source);
  return '<img src="' + escape(address) + '" alt="' + label + '">';
};

const renderFence = parser.renderer.rules.fence;
parser.renderer.rules.fence = (tokens, index, options, env, renderer) => {
  const token = tokens[index];
  if (token.info.trim() === "mermaid" && env.diagrams !== false) {
    return '<pre class="diagram" data-line="' + (token.map[0] + 1) + '">' + escape(token.content) + "</pre>";
  }
  const html = renderFence(tokens, index, options, env, renderer);
  return env.interactive ? html.replace("</pre>", '<button type="button" class="copy-code">Copy</button></pre>') : html;
};

export function renderMarkdown(source, options = {}) {
  const front = source.match(/^\uFEFF?---[^\S\n]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[^\S\n]*(?:\r?\n|$)/);
  const metadata = front && options.metadata !== false
    ? '<details class="metadata"><summary>Front matter</summary><pre>' + escape(front[1]) + "</pre></details>"
    : "";
  const text = front ? front[0].replace(/[^\n]/g, "") + source.slice(front[0].length) : source;
  const tokens = parser.parse(text, options);
  const headings = new Set();
  for (const [index, token] of tokens.entries()) {
    if (token.map && token.nesting === 1 && token.tag !== "table") token.attrSet("data-line", String(token.map[0] + 1));
    if (token.type === "heading_open") {
      const title = tokens[index + 1].children.map(child => child.content).join("");
      const base = title.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-") || "heading";
      let anchor = base;
      for (let suffix = 1; headings.has(anchor); suffix++) anchor = base + "-" + suffix;
      headings.add(anchor);
      token.attrSet("id", anchor);
    }
    if (token.type !== "list_item_open") continue;
    const paragraph = tokens[index + 2];
    if (paragraph?.type !== "inline" || tokens[index + 1]?.type !== "paragraph_open") continue;
    const first = paragraph.children[0];
    const task = first?.type === "text" && first.content.match(/^\[([ xX])\]\s/);
    if (!task) continue;
    first.content = first.content.slice(task[0].length);
    const checkbox = new token.constructor("html_inline", "", 0);
    checkbox.content = '<input type="checkbox" aria-label="Task" data-task-line="' + (token.map[0] + 1) +
      '"' + (task[1] !== " " ? " checked" : "") + (options.interactive ? "" : " disabled") + "> ";
    paragraph.children.unshift(checkbox);
    token.attrJoin("class", "task");
  }
  return metadata + parser.renderer.render(tokens, parser.options, options);
}
