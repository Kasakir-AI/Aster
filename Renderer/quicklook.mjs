import { renderMarkdown } from "./markdown.mjs";

globalThis.renderQuickLook = source => renderMarkdown(source, { diagrams: false });
