// VSCode Cmd+P-style cd picker for the mobile dock. Single autofocused path
// field is the whole interface: the text after the last "/" is a live
// case-insensitive regex filter over the current directory's subdirectories,
// lazily fetched via fs.tree depth=1. Ported from iOS ChangeDirectoryPanel.
//
//   - Type → filter `baseDir`'s children.
//   - Enter → drill into the first candidate.
//   - Click a candidate → drill into it (field becomes "<dir>/").
//   - ".." row → jump to the parent.
//   - Confirm → emit the full path to the caller (which sends `cd '<path>'\n`).

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useApp } from "../store/store";
import type { TreeResult } from "../proto/types";

interface Props {
  initialPath: string;
  onConfirm:   (target: string) => void;
  onCancel:    () => void;
}

function asDirectoryPath(p: string): string {
  if (!p || p === "/") return "/";
  return p.endsWith("/") ? p : p + "/";
}

function withoutTrailingSep(p: string): string {
  return (p.length > 1 && p.endsWith("/")) ? p.slice(0, -1) : p;
}

function deletingLastComponent(p: string): string {
  if (p === "/" || p === "") return "/";
  const s = withoutTrailingSep(p);
  const slash = s.lastIndexOf("/");
  if (slash <= 0) return "/";
  return s.slice(0, slash);
}

function appendingComponent(dir: string, name: string): string {
  if (dir === "/") return "/" + name;
  return withoutTrailingSep(dir) + "/" + name;
}

function buildMatcher(pattern: string): (s: string) => boolean {
  try {
    const re = new RegExp(pattern, "i");
    return (s) => re.test(s);
  } catch {
    const q = pattern.toLowerCase();
    return (s) => s.toLowerCase().includes(q);
  }
}

export default function ChangeDirectoryPanel({ initialPath, onConfirm, onCancel }: Props) {
  const client = useApp(s => s.client);

  const [input,   setInput]   = useState(asDirectoryPath(initialPath));
  const [cache,   setCache]   = useState<Map<string, string[]>>(new Map());
  const [loading, setLoading] = useState<Set<string>>(new Set());

  const inputRef = useRef<HTMLInputElement | null>(null);

  // Derived state — mirrors iOS computed properties.
  const baseDir = useMemo(() => {
    if (input.endsWith("/")) return withoutTrailingSep(input);
    return deletingLastComponent(input);
  }, [input]);

  const query = useMemo(() => {
    if (input.endsWith("/")) return "";
    const slash = input.lastIndexOf("/");
    return slash >= 0 ? input.slice(slash + 1) : input;
  }, [input]);

  const candidates = useMemo(() => {
    const all = cache.get(baseDir) ?? [];
    if (!query) return all.slice().sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
    const match = buildMatcher(query);
    return all.filter(match).sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
  }, [cache, baseDir, query]);

  const resolvedTarget = useMemo<string | null>(() => {
    if (!query) {
      // Field ends in a separator: baseDir must have listed OK.
      return cache.has(baseDir) ? baseDir : null;
    }
    const hit = (cache.get(baseDir) ?? []).find(n => n.toLowerCase() === query.toLowerCase());
    return hit ? appendingComponent(baseDir, hit) : null;
  }, [cache, baseDir, query]);

  const displayPath = resolvedTarget ?? withoutTrailingSep(input);

  // Lazy load: whenever `baseDir` changes (or initial mount), fetch its children.
  const load = useCallback(async (dir: string) => {
    if (!dir || !client) return;
    if (cache.has(dir)) return;
    if (loading.has(dir)) return;
    setLoading(prev => { const n = new Set(prev); n.add(dir); return n; });
    try {
      const r = await client.call<TreeResult>("fs.tree", { path: dir, depth: 1 });
      const dirs = r.entries
        .filter(e => e.type === "dir")
        .map(e => e.name)
        .sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
      setCache(prev => { const n = new Map(prev); n.set(dir, dirs); return n; });
    } catch {
      // Leave cache[dir] unset → confirm stays disabled for this path.
    } finally {
      setLoading(prev => { const n = new Set(prev); n.delete(dir); return n; });
    }
  }, [client, cache, loading]);

  useEffect(() => {
    void load(baseDir);
  }, [baseDir, load]);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const drillInto = useCallback((name: string) => {
    setInput(asDirectoryPath(appendingComponent(baseDir, name)));
    inputRef.current?.focus();
  }, [baseDir]);

  const goUp = useCallback(() => {
    if (baseDir === "/") return;
    setInput(asDirectoryPath(deletingLastComponent(baseDir)));
    inputRef.current?.focus();
  }, [baseDir]);

  const enterFirst = useCallback(() => {
    if (candidates.length > 0) drillInto(candidates[0]);
  }, [candidates, drillInto]);

  const onKeyDown = useCallback((e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Escape") { e.preventDefault(); onCancel(); return; }
    if (e.key === "Enter")  { e.preventDefault(); enterFirst();  return; }
  }, [enterFirst, onCancel]);

  const onConfirmClick = useCallback(() => {
    if (resolvedTarget) onConfirm(resolvedTarget);
  }, [resolvedTarget, onConfirm]);

  return (
    <div className="cdpanel-backdrop" onClick={onCancel}>
      <div
        className="cdpanel-modal"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-label="Change directory"
      >
        <header className="cdpanel-header">
          <strong>Change directory</strong>
          <button className="ghost small" onClick={onCancel}>Cancel</button>
        </header>

        <div className="cdpanel-input">
          <span className="cdpanel-prompt" aria-hidden>›</span>
          <input
            ref={inputRef}
            type="text"
            value={input}
            placeholder="path"
            spellCheck={false}
            autoCapitalize="off"
            autoCorrect="off"
            autoComplete="off"
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={onKeyDown}
          />
          {loading.has(baseDir) && <span className="muted small" aria-hidden>…</span>}
        </div>

        <ul className="cdpanel-list">
          {baseDir !== "/" && (
            <li className="cdpanel-row cdpanel-parent" onClick={goUp}>
              <span className="cdpanel-icon" aria-hidden>↰</span>
              <span className="cdpanel-name">..</span>
              <span className="cdpanel-hint muted small">parent</span>
            </li>
          )}
          {candidates.length === 0 && cache.has(baseDir) && !loading.has(baseDir) && (
            <li className="cdpanel-empty muted small">
              {query ? "No match" : "No subdirectories"}
            </li>
          )}
          {candidates.map((name, idx) => (
            <li key={name} className="cdpanel-row" onClick={() => drillInto(name)}>
              <span className="cdpanel-icon" aria-hidden>▸</span>
              <span className="cdpanel-name">{name}</span>
              <span style={{ flex: "1 1 auto" }} />
              {idx === 0 && <span className="cdpanel-enter" aria-hidden>↵</span>}
            </li>
          ))}
        </ul>

        <footer className="cdpanel-footer">
          <button
            className="cdpanel-confirm"
            onClick={onConfirmClick}
            disabled={!resolvedTarget}
            title={resolvedTarget ? `cd ${resolvedTarget}` : "Path doesn't resolve to a directory"}
          >
            <span className="cdpanel-confirm-glyph" aria-hidden>↦</span>
            <span className="cdpanel-confirm-cd">cd</span>
            <span className="cdpanel-confirm-path">{displayPath}</span>
          </button>
        </footer>
      </div>
    </div>
  );
}
