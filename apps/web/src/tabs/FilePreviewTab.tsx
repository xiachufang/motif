// Basic read-only file preview. Optionally syntax-highlights with highlight.js
// when the MIME hints at code.
//
// We import the highlight.js *core* plus only the languages we actually map in
// LANG_HINT. The full bundle ships 200+ languages (~900 kB) that nothing here
// uses; this trims that down to the ~12 we actually highlight.

import { useEffect, useRef } from "react";
import hljs from "highlight.js/lib/core";
import javascript from "highlight.js/lib/languages/javascript";
import typescript from "highlight.js/lib/languages/typescript";
import json       from "highlight.js/lib/languages/json";
import rust       from "highlight.js/lib/languages/rust";
import python     from "highlight.js/lib/languages/python";
import go         from "highlight.js/lib/languages/go";
import c          from "highlight.js/lib/languages/c";
import cpp        from "highlight.js/lib/languages/cpp";
import bash       from "highlight.js/lib/languages/bash";
import ini        from "highlight.js/lib/languages/ini";
import markdown   from "highlight.js/lib/languages/markdown";
import xml        from "highlight.js/lib/languages/xml";
import css        from "highlight.js/lib/languages/css";
import "highlight.js/styles/atom-one-dark.min.css";

hljs.registerLanguage("javascript", javascript);
hljs.registerLanguage("typescript", typescript);
hljs.registerLanguage("json",       json);
hljs.registerLanguage("rust",       rust);
hljs.registerLanguage("python",     python);
hljs.registerLanguage("go",         go);
hljs.registerLanguage("c",          c);
hljs.registerLanguage("cpp",        cpp);
hljs.registerLanguage("bash",       bash);
hljs.registerLanguage("ini",        ini);
hljs.registerLanguage("markdown",   markdown);
hljs.registerLanguage("html",       xml);   // hljs ships HTML inside xml.js
hljs.registerLanguage("css",        css);

interface Props {
  path:    string;
  content: string;
  mime:    string | null;
  binary:  boolean;
}

const EXT_HINT: Record<string, string> = {
  js: "javascript",
  jsx: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  ts: "typescript",
  tsx: "typescript",
  json: "json",
  jsonc: "json",
  rs: "rust",
  py: "python",
  go: "go",
  c: "c",
  h: "c",
  cc: "cpp",
  cpp: "cpp",
  cxx: "cpp",
  hpp: "cpp",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  fish: "bash",
  toml: "ini",
  lock: "ini",
  ini: "ini",
  md: "markdown",
  markdown: "markdown",
  html: "html",
  htm: "html",
  xml: "html",
  svg: "html",
  css: "css",
};

const LANG_HINT: Record<string, string> = {
  "application/javascript": "javascript",
  "application/typescript": "typescript",
  "application/json":       "json",
  "text/x-rust":            "rust",
  "text/x-python":          "python",
  "text/x-go":              "go",
  "text/x-c":               "c",
  "text/x-c++":             "cpp",
  "text/x-shellscript":     "bash",
  "text/markdown":          "markdown",
  "text/html":              "html",
  "text/css":               "css",
};

function extOf(path: string): string {
  const safePath = path || "";
  const base = safePath.split(/[\\/]/).pop() ?? safePath;
  const i = base.lastIndexOf(".");
  return i < 0 ? "" : base.slice(i + 1).toLowerCase();
}

function languageFor(path: string, mime: string | null): string | undefined {
  const ext = extOf(path);
  if (ext && EXT_HINT[ext]) return EXT_HINT[ext];
  if (mime && LANG_HINT[mime]) return LANG_HINT[mime];
  return undefined;
}

export default function FilePreviewTab({ path = "", content, mime, binary }: Props) {
  const ref = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    if (binary || !ref.current) return;
    const lang = languageFor(path, mime);
    const code = ref.current.querySelector("code");
    if (!code) return;
    code.removeAttribute("data-highlighted");
    code.textContent = content;
    code.className = lang ? `language-${lang}` : "";
    try { hljs.highlightElement(code as HTMLElement); } catch { /* ignore */ }
  }, [path, content, mime, binary]);

  if (binary) {
    return <div className="muted preview-binary">{content}</div>;
  }
  return (
    <pre className="preview" ref={ref}>
      <code>{content}</code>
    </pre>
  );
}
