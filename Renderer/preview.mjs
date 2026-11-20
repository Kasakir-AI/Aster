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

window.render = async (source, options) => {
  const current = ++revision;
  const scrollTop = window.scrollY;
  const openMetadata = article.querySelector("details.metadata")?.open;
  document.documentElement.dataset.appearance = options.appearance;
  document.documentElement.style.fontSize = options.fontSize + "px";
  article.innerHTML = renderMarkdown(source, options);
  if (openMetadata && article.querySelector("details.metadata")) article.querySelector("details.metadata").open = true;
  if (options.preserveScroll) window.scrollTo(0, scrollTop);
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
  const link = event.target.closest("a[href]");
  if (link) {
    const address = link.getAttribute("href");
    if (!address.startsWith("#")) {
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
article.addEventListener("error", event => {
  if (event.target.tagName === "IMG") {
    const placeholder = document.createElement("span");
    placeholder.className = "image-placeholder";
    placeholder.textContent = event.target.alt;
    event.target.replaceWith(placeholder);
  }
}, true);

window.exportContent = () => {
  const clone = article.cloneNode(true);
  for (const checkbox of clone.querySelectorAll("input")) {
    checkbox.disabled = true;
    checkbox.toggleAttribute("checked", checkbox.checked);
  }
  return clone.outerHTML;
};
