// Presentational components for a single block in the PTY stack.
//
// Two flavors mirror the finalized variants of `BlockRender`:
//   - `BlockCard`: a finished command. Header + serialized HTML body.
//   - `AltStub`:   a finished alt-screen command (vim/less/htop). Header
//                  only — alt-screen frames don't snapshot well.
//
// The live (running) block isn't a separate component — PtyTab inlines its
// header next to the live xterm, since both share the same `.block-live`
// wrapper for visual continuity with finalized blocks.
//
// All three variants share `.block-*` outer classes; the status class
// (success/failure/neutral) lives on the `<article>` so a single left-gutter
// strip carries the color for the whole block.

import { memo } from "react";
import type { BlockRender } from "../store/store";

interface CommonProps {
  selected:  boolean;
  onSelect?: () => void;
}

/** Click handler that suppresses the select toggle when the user just
 *  finished a drag-selection inside the header. Without this, releasing
 *  the mouse after dragging a few characters would also toggle the
 *  block-selection state. */
function clickIgnoringSelection(onSelect?: () => void) {
  return () => {
    const sel = typeof window !== "undefined" ? window.getSelection() : null;
    if (sel && sel.toString().length > 0) return;
    onSelect?.();
  };
}

function fmtDuration(startedAt: number, finishedAt: number | null): string {
  if (!finishedAt) return "";
  const ms = Math.max(0, finishedAt - startedAt);
  if (ms < 1000)   return `${ms}ms`;
  const s = ms / 1000;
  if (s < 60)      return `${s.toFixed(s < 10 ? 1 : 0)}s`;
  const m = Math.floor(s / 60);
  const rs = Math.floor(s - m * 60);
  return `${m}m${rs}s`;
}

/** Render the sticky `$ cmd` line inside a block header. Prefers the
 *  serialized HTML (full ANSI colors of the original PS1 + typed command);
 *  falls back to plain `$ cmd` only when no HTML was captured (e.g.
 *  backfilled history). */
export function PromptLine({ html, cmd }: { html: string; cmd: string }) {
  if (html) {
    return <div className="prompt-html" dangerouslySetInnerHTML={{ __html: html }} />;
  }
  return (
    <>
      <span className="prompt">$</span>
      <span className="cmd">{cmd || "(no cmd text)"}</span>
    </>
  );
}

/** Small ULID-tail chip shown on every block header. Useful for
 *  cross-referencing client logs with server BlockStore entries when
 *  diagnosing rendering / state-machine issues. ULIDs are
 *  timestamp-prefixed so the trailing chunk is what actually
 *  disambiguates blocks recorded in the same millisecond. Hover shows
 *  the full id. */
export function BlockIdChip({ id }: { id: string }) {
  const tail = id.length > 6 ? id.slice(-6) : id;
  return <span className="block-id-chip" title={id}>{tail}</span>;
}

interface CardProps extends CommonProps {
  block: Extract<BlockRender, { kind: "card" }>;
}
export const BlockCard = memo(function BlockCard({ block, selected, onSelect }: CardProps) {
  // `clear`, `reset`, and any command whose serialize range collapsed emit
  // an empty html_body. Skip the body element entirely so the card lays
  // out as a tight one-line header.
  const hasBody = block.html_body.length > 0;
  return (
    <article
      className={`block-card ${hasBody ? "" : "no-body"} ${selected ? "selected" : ""}`}
      data-block-id={block.id}
    >
      <header
        className="block-card-header"
        onClick={clickIgnoringSelection(onSelect)}
        title={`exit ${block.exit_code ?? "?"} · ${fmtDuration(block.started_at, block.finished_at)}`}
      >
        <PromptLine html={block.prompt_html} cmd={block.cmd} />
        <BlockIdChip id={block.id} />
      </header>
      {hasBody && (
        <div
          className="block-card-body"
          dangerouslySetInnerHTML={{ __html: block.html_body }}
        />
      )}
    </article>
  );
});

interface AltProps extends CommonProps {
  block: Extract<BlockRender, { kind: "alt" }>;
}
export const AltStub = memo(function AltStub({ block, selected, onSelect }: AltProps) {
  return (
    <article
      className={`block-alt ${selected ? "selected" : ""}`}
      data-block-id={block.id}
      onClick={clickIgnoringSelection(onSelect)}
      title={`interactive program · exit ${block.exit_code ?? "?"} · ${fmtDuration(block.started_at, block.finished_at)}`}
    >
      <header className="block-alt-header">
        <PromptLine html={block.prompt_html} cmd={block.cmd} />
        <span className="muted small">(interactive program)</span>
        <BlockIdChip id={block.id} />
      </header>
    </article>
  );
});
