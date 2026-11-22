import { renderMarkdown } from "./markdown.mjs";

const article = document.querySelector("article");
const post = (kind, value) => window.webkit?.messageHandlers.bridge?.postMessage({ kind, value });
let revision = 0;
let diagrams;
let ignoreScrollUntil = 0;

function loadDiagrams() {
  if (diagrams) return diagrams;
  diagrams = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "mermaid.min.js";
    script.onload = () => resolve(window.mermaid);
    script.onerror = reject;
    document.head.append(script);
  });
  return diagrams;
}

function readingAnchor() {
  const blocks = [...article.querySelectorAll("[data-line]")];
  let chosen = null;
  for (const block of blocks) {
    if (block.getBoundingClientRect().top <= 8) chosen = block;
    else break;
  }
  if (!chosen) return null;
  return { line: chosen.dataset.line, top: chosen.getBoundingClientRect().top };
}

function restoreReading(anchor) {
  if (!anchor) return;
  const block = [...article.querySelectorAll("[data-line]")].find(item => item.dataset.line === anchor.line);
  if (!block) return;
  ignoreScrollUntil = performance.now() + 180;
  window.scrollBy(0, block.getBoundingClientRect().top - anchor.top);
}

window.render = async (source, options) => {
  const current = ++revision;
  const anchor = options.preserveScroll ? readingAnchor() : null;
  const openMetadata = article.querySelector("details.metadata")?.open;
  document.documentElement.dataset.appearance = options.appearance;
  document.documentElement.style.fontSize = options.fontSize + "px";
  article.innerHTML = renderMarkdown(source, options);
  if (openMetadata && article.querySelector("details.metadata")) article.querySelector("details.metadata").open = true;
  restoreReading(anchor);
  const blocks = [...article.querySelectorAll(".diagram")];
  if (!blocks.length) return;
  try {
    const mermaid = await loadDiagrams();
    if (current !== revision) return;
    mermaid.initialize({
      startOnLoad: false, securityLevel: "strict", suppressErrorRendering: true,
      maxTextSize: 30000, maxEdges: 300, theme: getComputedStyle(article).colorScheme === "dark" ? "dark" : "default",
      flowchart: { htmlLabels: false }
    });
    for (const [index, block] of blocks.entries()) {
      if (current !== revision) return;
      try {
        const { svg } = await mermaid.render("diagram-" + current + "-" + index, block.textContent);
        if (!block.isConnected) return;
        const figure = document.createElement("figure");
        figure.dataset.line = block.dataset.line;
        figure.innerHTML = svg;
        block.replaceWith(figure);
      } catch {
        block.title = "Mermaid could not render this diagram";
      }
    }
    if (current === revision) restoreReading(anchor);
  } catch {
    // Keep Mermaid source readable if WebKit cannot load the bundled diagram engine.
  }
};

window.jumpToLine = line => {
  const blocks = [...article.querySelectorAll("[data-line]")];
  const block = blocks.find(item => Number(item.dataset.line) === line)
    ?? blocks.filter(item => Number(item.dataset.line) <= line).at(-1);
  if (block) {
    ignoreScrollUntil = performance.now() + 180;
    block.scrollIntoView({ block: "start" });
  }
};

window.scrollFraction = fraction => {
  ignoreScrollUntil = performance.now() + 180;
  const height = document.documentElement.scrollHeight - window.innerHeight;
  window.scrollTo(0, fraction * Math.max(height, 0));
};

let scrollTimer;
window.addEventListener("scroll", () => {
  clearTimeout(scrollTimer);
  if (performance.now() < ignoreScrollUntil) return;
  scrollTimer = setTimeout(() => {
    const height = document.documentElement.scrollHeight - window.innerHeight;
    if (height > 0) post("scroll", window.scrollY / height);
  }, 65);
}, { passive: true });

article.addEventListener("click", event => {
  const copy = event.target.closest(".copy-code");
  if (copy) {
    event.preventDefault();
    const code = copy.parentElement?.querySelector("code");
    if (code) post("copy", code.textContent ?? "");
    copy.textContent = "Copied";
    return;
  }
  const link = event.target.closest("a[href]");
  if (link) {
    const address = link.getAttribute("href");
    if (address.startsWith("#")) {
      let name = address.slice(1);
      try { name = decodeURIComponent(name); } catch { /* Keep the raw fragment when it is not percent-encoded. */ }
      name = name.toLowerCase();
      const target = [...article.querySelectorAll("[id]")].find(node => node.id.toLowerCase() === name);
      if (!target) return;
      event.preventDefault();
      ignoreScrollUntil = performance.now() + 180;
      target.scrollIntoView({ block: "start" });
    } else {
      event.preventDefault();
      post("link", address);
    }
  } else if (event.altKey) {
    const block = event.target.closest("[data-line]");
    if (block) post("line", Number(block.dataset.line));
  }
});
article.addEventListener("change", event => {
  if (event.target.matches("input[data-task-line]")) {
    post("task", Number(event.target.dataset.taskLine));
  }
});
function replaceFailedImage(image) {
  const placeholder = document.createElement("span");
  placeholder.className = "image-placeholder";
  placeholder.textContent = image.alt;
  image.replaceWith(placeholder);
}

article.addEventListener("error", event => {
  if (event.target.tagName === "IMG") replaceFailedImage(event.target);
}, true);

window.waitForImages = async () => {
  await Promise.all(Array.from(article.querySelectorAll("img"), image =>
    image.decode().catch(() => replaceFailedImage(image))
  ));
};

window.exportContent = () => {
  const clone = article.cloneNode(true);
  clone.querySelectorAll(".copy-code").forEach(button => button.remove());
  for (const checkbox of clone.querySelectorAll("input")) {
    checkbox.disabled = true;
    checkbox.toggleAttribute("checked", checkbox.checked);
  }
  return clone.outerHTML;
};
