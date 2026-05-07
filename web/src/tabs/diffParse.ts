// Splits a multi-file unified `git diff` patch into per-file blocks with
// path / status / +-/− stats. The chunking is anchored on lines that start
// with "diff --git ", which git always emits even for binary, rename, mode-
// only, or empty-content diffs.

export type FileStatus =
  | "modified" | "added" | "deleted" | "renamed" | "copied" | "binary" | "mode";

export interface FileDiff {
  /** Display path: new path for adds/modifies/renames, old path for deletes. */
  path:       string;
  oldPath:    string | null;
  newPath:    string | null;
  /** Patch text for this single file, including its `diff --git` header. */
  patch:      string;
  additions:  number;
  deletions:  number;
  status:     FileStatus;
  isBinary:   boolean;
}

export function parseUnifiedDiff(raw: string): FileDiff[] {
  if (!raw || !raw.trim()) return [];
  const lines = raw.split("\n");
  const out: FileDiff[] = [];
  let buf: string[] | null = null;
  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      if (buf) out.push(buildFile(buf));
      buf = [line];
    } else if (buf) {
      buf.push(line);
    }
  }
  if (buf) out.push(buildFile(buf));
  return out;
}

function buildFile(lines: string[]): FileDiff {
  const header = lines[0] ?? "";
  let { oldPath, newPath } = parseGitHeaderPaths(header);

  let isBinary  = false;
  let isNew     = false;
  let isDelete  = false;
  let isRename  = false;
  let isCopy    = false;
  let isModeOnly = true; // until we see a hunk
  let additions = 0;
  let deletions = 0;
  let inHunk    = false;

  for (const line of lines) {
    if (line.startsWith("Binary files ") || line.startsWith("GIT binary patch")) {
      isBinary   = true;
      isModeOnly = false;
    } else if (line.startsWith("new file mode ")) {
      isNew = true;
    } else if (line.startsWith("deleted file mode ")) {
      isDelete = true;
    } else if (line.startsWith("rename from ")) {
      isRename = true;
      oldPath  = line.slice("rename from ".length);
    } else if (line.startsWith("rename to ")) {
      newPath  = line.slice("rename to ".length);
    } else if (line.startsWith("copy from ")) {
      isCopy   = true;
      oldPath  = line.slice("copy from ".length);
    } else if (line.startsWith("copy to ")) {
      newPath  = line.slice("copy to ".length);
    } else if (line.startsWith("--- ")) {
      const v = line.slice(4);
      if (v.startsWith("a/")) oldPath = v.slice(2);
      else if (v === "/dev/null") { /* new file */ }
      else                          oldPath = v;
    } else if (line.startsWith("+++ ")) {
      const v = line.slice(4);
      if (v.startsWith("b/")) newPath = v.slice(2);
      else if (v === "/dev/null") { /* deleted file */ }
      else                          newPath = v;
    } else if (line.startsWith("@@")) {
      inHunk     = true;
      isModeOnly = false;
    } else if (inHunk) {
      if (line.startsWith("+") && !line.startsWith("+++")) additions++;
      else if (line.startsWith("-") && !line.startsWith("---")) deletions++;
    }
  }

  const status: FileStatus =
    isBinary  ? "binary"
    : isNew     ? "added"
    : isDelete  ? "deleted"
    : isRename  ? "renamed"
    : isCopy    ? "copied"
    : isModeOnly ? "mode"
    : "modified";

  const path = isDelete
    ? (oldPath || newPath || "(unknown)")
    : (newPath || oldPath || "(unknown)");

  return {
    path,
    oldPath:   isNew ? null : (oldPath || null),
    newPath:   isDelete ? null : (newPath || null),
    patch:     lines.join("\n"),
    additions,
    deletions,
    status,
    isBinary,
  };
}

// `diff --git a/foo b/foo` — paths may contain spaces. Git quotes paths with
// special characters, but for the common case we match the longest split that
// keeps a/X and b/X structurally consistent.
function parseGitHeaderPaths(header: string): { oldPath: string | null; newPath: string | null } {
  const rest = header.slice("diff --git ".length).trim();
  // Try the simple " a/X b/X" form where lengths are equal.
  // Find a split point such that rest[..i] starts with "a/" and rest[i+1..]
  // starts with "b/" and the remainder of each side matches.
  // Most diffs have identical paths; quoted paths fall through to a fallback.
  const half = (rest.length - 1) / 2;
  if (Number.isInteger(half)) {
    const a = rest.slice(0, half);
    const b = rest.slice(half + 1);
    if (a.startsWith("a/") && b.startsWith("b/") && a.slice(2) === b.slice(2)) {
      return { oldPath: a.slice(2), newPath: b.slice(2) };
    }
  }
  // Fallback: split on " b/" preceded by an "a/" prefix. Imperfect but
  // good enough; rename headers will overwrite via rename from/to anyway.
  const m = /^a\/(.+?) b\/(.+)$/.exec(rest);
  if (m) return { oldPath: m[1], newPath: m[2] };
  return { oldPath: null, newPath: null };
}
