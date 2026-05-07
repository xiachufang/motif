import { useEffect } from "react";
import type { BlockSummary } from "../proto/types";
import { useApp } from "../store/store";

interface ListBlocksResult { blocks: BlockSummary[] }

/** v2 shell-integration block panel. Shows the active PTY's most-recent
 *  finished commands plus the in-flight one (if any). Clicking a row
 *  asks the PtyTab to scroll the xterm viewport to that block and
 *  highlight it. */
export default function BlockList() {
  const client            = useApp(s => s.client);
  const views             = useApp(s => s.views);
  const activeView        = useApp(s => s.activeView);
  const ptyBlocks         = useApp(s => s.ptyBlocks);
  const selectedBlock     = useApp(s => s.selectedBlock);
  const setPtyBlocks      = useApp(s => s.setPtyBlocks);
  const setSelectedBlock  = useApp(s => s.setSelectedBlock);

  const v = views.find(x => x.id === activeView);
  const activePtyId = v?.spec.kind === "pty" ? v.spec.pty_id : null;
  const ui = activePtyId ? ptyBlocks.get(activePtyId) ?? null : null;

  // Backfill on PTY switch: when we don't have anything cached, ask the
  // server for the last 50 blocks. After that the live stream
  // (`command_started` / `command_finished`) keeps `recent` fresh.
  useEffect(() => {
    if (!client || !activePtyId) return;
    if (ui && ui.recent.length > 0) return;
    let cancelled = false;
    (async () => {
      try {
        const r = await client.call<ListBlocksResult>("pty.list_blocks", {
          pty_id: activePtyId, limit: 50,
        });
        if (!cancelled) setPtyBlocks(activePtyId, r.blocks);
      } catch { /* server may not be on a v2 build — silent fallback */ }
    })();
    return () => { cancelled = true; };
  }, [client, activePtyId, ui, setPtyBlocks]);

  if (!activePtyId) {
    return (
      <section className="block-list">
        <h3 className="row tight">blocks</h3>
        <div className="muted small">(no PTY active)</div>
      </section>
    );
  }

  const recent = ui?.recent ?? [];
  const running = ui?.running ?? null;
  const selectedId = selectedBlock?.ptyId === activePtyId ? selectedBlock.blockId : null;

  function onSelect(blockId: string) {
    if (!activePtyId) return;
    // Clicking the already-selected row clears the highlight.
    if (selectedId === blockId) setSelectedBlock(null, null);
    else setSelectedBlock(activePtyId, blockId);
  }

  return (
    <section className="block-list">
      <h3 className="row tight">
        blocks <span className="muted small">{recent.length}{recent.length === 50 ? "+" : ""}</span>
        {selectedId && (
          <button className="ghost small" onClick={() => setSelectedBlock(null, null)}>clear</button>
        )}
      </h3>
      <ul>
        {running && (
          <li className="block running" title={running.text}>
            <span className="block-glyph">▶</span>
            <span className="block-cmd">{running.text}</span>
          </li>
        )}
        {recent.length === 0 && !running && (
          <li className="muted small">(no blocks yet)</li>
        )}
        {recent.map(b => (
          <BlockRow
            key={b.id}
            block={b}
            selected={selectedId === b.id}
            onClick={() => onSelect(b.id)}
          />
        ))}
      </ul>
    </section>
  );
}

function BlockRow({ block: b, selected, onClick }: {
  block: BlockSummary;
  selected: boolean;
  onClick: () => void;
}) {
  const cls =
      b.exit_code === 0       ? "block success"
    : b.exit_code == null     ? "block neutral"
    :                           "block failure";
  const sym =
      b.exit_code === 0       ? "✓"
    : b.exit_code == null     ? "·"
    :                           "✗";
  return (
    <li
      className={cls + (selected ? " selected" : "")}
      title={`${b.cmd}\nexit ${b.exit_code ?? "?"} · ${b.output_size} bytes${b.output_truncated ? " (truncated)" : ""}`}
      onClick={onClick}
    >
      <span className="block-glyph">{sym}{b.exit_code != null ? b.exit_code : ""}</span>
      <span className="block-cmd">{b.cmd || "(no cmd text)"}</span>
    </li>
  );
}
