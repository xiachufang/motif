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
hljs.registerLanguage("markdown",   markdown);
hljs.registerLanguage("html",       xml);   // hljs ships HTML inside xml.js
hljs.registerLanguage("css",        css);

interface Props {
  content: string;
  mime:    string | null;
  binary:  boolean;
}

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

export default function FilePreviewTab({ content, mime, binary }: Props) {
  const ref = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    if (binary || !ref.current) return;
    const lang = mime ? LANG_HINT[mime] : undefined;
    const code = ref.current.querySelector("code");
    if (!code) return;
    code.removeAttribute("data-highlighted");
    code.className = lang ? `language-${lang}` : "";
    try { hljs.highlightElement(code as HTMLElement); } catch { /* ignore */ }
  }, [content, mime, binary]);

  if (binary) {
    return <div className="muted preview-binary">{content}</div>;
  }
  return (
    <pre className="preview" ref={ref}>
      <code>{content}</code>
    </pre>
  );
}
