// Virtualized finalized-block list.
//
// Wraps `@tanstack/react-virtual` in spacer mode (NOT absolute mode):
// the leading/trailing virtual range is occupied by two height-only divs
// so the rendered virtual items live in the parent's normal block flow.
// That layout preserves `position: sticky` on each block's header — an
// absolute-positioned virtual container would become the sticky element's
// containing block and break the "stick to .pty-stack top" semantics.
//
// The trailing running block is NOT in this list — PtyTab renders it
// after this component, also in `.pty-stack` flow. That keeps the
// xterm host element (re-parented by usePtyTerminal) permanently
// mounted; only finalized BlockCard / AltStub items get virtualized.

import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";

import type { BlockRender } from "../store/store";
import type { BlockId } from "../proto/types";
import { AltStub, BlockCard } from "./blockCards";

/** Public handle exposed to PtyTab via ref. */
export interface BlockListHandle {
  /** Scroll the given block id into view. Returns false if the id isn't
   *  in the current finalized list. */
  scrollToBlock: (id: BlockId, opts?: { align?: "auto" | "start" | "center" | "end" }) => boolean;
  /** Scroll to the bottom-most finalized block. */
  scrollToBottom: () => void;
}

interface Props {
  /** Finalized blocks only — `kind: "card" | "alt"`. The running block
   *  must be rendered separately by the parent. */
  blocks:        Array<Extract<BlockRender, { kind: "card" | "alt" }>>;
  /** Currently-selected block (used to dim/highlight via .selected). */
  selectedId:    BlockId | null;
  /** Whether `selectedId` is for THIS pty (selection state is global). */
  selectedIsHere: boolean;
  onBlockSelect: (id: BlockId) => void;
  /** The scrollable ancestor — `.pty-stack`. */
  parentRef:     React.RefObject<HTMLDivElement | null>;
}

/** Cheap row estimate: 20px header + ~16px per output row inferred from
 *  the body html (one `<div>` per row in SerializeAddon output). 16px
 *  matches the xterm font-size: 13 + line-height: 1.2 ≈ 16. The first
 *  measureElement pass replaces this with the real height.
 *  Always returns a positive value so virtualizer doesn't divide by zero. */
function estimateBlockHeight(block: Props["blocks"][number]): number {
  if (block.kind === "alt") return 24;
  const hasBody = block.html_body.length > 0;
  if (!hasBody) return 24; // header-only card
  // Count `<div` occurrences as a proxy for rendered rows.
  const m = block.html_body.match(/<div/g);
  const rows = m ? m.length : 1;
  return 20 + rows * 16;
}

const BlockList = forwardRef<BlockListHandle, Props>(function BlockList(
  { blocks, selectedId, selectedIsHere, onBlockSelect, parentRef }, ref,
) {
  const virtualizer = useVirtualizer({
    count: blocks.length,
    getScrollElement: () => parentRef.current,
    estimateSize: i => estimateBlockHeight(blocks[i]),
    overscan: 4,
    getItemKey: i => blocks[i].id,
  });

  // Stable id → index lookup for scrollToBlock.
  const idIndex = useMemo(() => {
    const m = new Map<BlockId, number>();
    for (let i = 0; i < blocks.length; i++) m.set(blocks[i].id, i);
    return m;
  }, [blocks]);
  const idIndexRef = useRef(idIndex);
  idIndexRef.current = idIndex;

  useImperativeHandle(ref, () => ({
    scrollToBlock: (id, opts) => {
      const idx = idIndexRef.current.get(id);
      if (idx === undefined) return false;
      virtualizer.scrollToIndex(idx, { align: opts?.align ?? "center" });
      return true;
    },
    scrollToBottom: () => {
      if (blocks.length === 0) return;
      virtualizer.scrollToIndex(blocks.length - 1, { align: "end" });
    },
  }), [virtualizer, blocks.length]);

  const items     = virtualizer.getVirtualItems();
  const totalSize = virtualizer.getTotalSize();
  const lead      = items.length > 0 ? items[0].start : 0;
  const trail     = items.length > 0
    ? Math.max(0, totalSize - items[items.length - 1].end)
    : Math.max(0, totalSize);

  return (
    <div className="block-list-host">
      {lead > 0 && <div aria-hidden style={{ height: lead }} />}
      {items.map(item => {
        const b = blocks[item.index];
        const sel = selectedIsHere && selectedId === b.id;
        return (
          <div
            key={item.key}
            ref={virtualizer.measureElement}
            data-index={item.index}
          >
            {b.kind === "card" ? (
              <BlockCard block={b} selected={sel} onSelect={() => onBlockSelect(b.id)} />
            ) : (
              <AltStub block={b} selected={sel} onSelect={() => onBlockSelect(b.id)} />
            )}
          </div>
        );
      })}
      {trail > 0 && <div aria-hidden style={{ height: trail }} />}
    </div>
  );
});

export default BlockList;
