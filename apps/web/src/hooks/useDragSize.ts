// Pointer-driven drag-to-resize hook. Returns a numeric size (px) and an
// onPointerDown handler to attach to a Resizer element. While dragging, the
// document's text-selection is suppressed and the right cursor is forced so
// the experience is the same regardless of what's under the pointer.

import { useCallback, useEffect, useRef, useState } from "react";

interface Options {
  initial:    number;
  min:        number;
  max?:       number | (() => number);
  axis:       "x" | "y";
  storageKey?: string;
}

function loadInit(key: string | undefined, fallback: number): number {
  if (!key) return fallback;
  try {
    const v = localStorage.getItem(key);
    if (v == null) return fallback;
    const n = Number(v);
    return Number.isFinite(n) ? n : fallback;
  } catch { return fallback; }
}

function save(key: string | undefined, v: number) {
  if (!key) return;
  try { localStorage.setItem(key, String(v)); } catch { /* ignore */ }
}

export function useDragSize({ initial, min, max, axis, storageKey }: Options) {
  const [size, setSize] = useState(() => loadInit(storageKey, initial));
  const dragRef = useRef<{ origin: number; start: number } | null>(null);

  const resolveMax = useCallback(() => {
    if (max == null) return Infinity;
    return typeof max === "function" ? max() : max;
  }, [max]);

  const onPointerDown = useCallback((e: React.PointerEvent) => {
    // Left button only; ignore others.
    if (e.button !== 0) return;
    e.preventDefault();
    dragRef.current = {
      origin: axis === "x" ? e.clientX : e.clientY,
      start:  size,
    };
    (e.target as Element).setPointerCapture?.(e.pointerId);

    document.body.style.userSelect = "none";
    document.body.style.cursor = axis === "x" ? "col-resize" : "row-resize";

    function onMove(ev: PointerEvent) {
      const d = dragRef.current; if (!d) return;
      const cur = axis === "x" ? ev.clientX : ev.clientY;
      const next = Math.min(resolveMax(), Math.max(min, d.start + (cur - d.origin)));
      setSize(next);
    }
    function onUp() {
      const d = dragRef.current;
      dragRef.current = null;
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup",   onUp);
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
      if (d) {
        // Persist whatever size React has settled on.
        setSize(prev => { save(storageKey, prev); return prev; });
      }
    }
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup",   onUp);
  }, [axis, min, resolveMax, size, storageKey]);

  // Re-clamp on window resize (the max bound is often window-relative).
  useEffect(() => {
    function clamp() {
      setSize(prev => Math.min(resolveMax(), Math.max(min, prev)));
    }
    window.addEventListener("resize", clamp);
    return () => window.removeEventListener("resize", clamp);
  }, [min, resolveMax]);

  return { size, onPointerDown };
}
