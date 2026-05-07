// xterm.js-based PTY tab. Output bytes flow in via the module-level
// `ptyBuffers` registry — Workspace populates it from `pty.output` events,
// and we attach() on mount to atomically grab pre-mount bytes + future ones.

import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";

import { useApp } from "../store/store";
import { attach } from "../store/ptyBuffers";

interface Props { ptyId: string; active: boolean }

export default function PtyTab({ ptyId, active }: Props) {
  const client  = useApp(s => s.client);
  const ptyInfo = useApp(s => s.ptyInfos.get(ptyId));
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef  = useRef<FitAddon | null>(null);

  // Mount the terminal once and wire it to the byte buffer.
  useEffect(() => {
    if (!wrapRef.current) return;
    const wrap = wrapRef.current;
    const term = new Terminal({
      fontFamily: "ui-monospace, Menlo, Consolas, monospace",
      fontSize: 13,
      cursorBlink: true,
      scrollback: 5000,
      theme: { background: "#0a0a0a", foreground: "#e6e6e6" },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon());
    term.open(wrap);
    termRef.current = term;
    fitRef.current  = fit;

    // Defer attach()+initial-write until the wrapper actually has a non-zero
    // size, so the first bytes (shell banner, alt-screen apps like less) land
    // on a correctly-sized grid. Writing under xterm's default 80×24 and then
    // resizing leaves stale cells — xterm doesn't reflow already-written rows.
    let detachBuffer: (() => void) | null = null;
    let started = false;
    const start = () => {
      if (started) return;
      if (wrap.clientWidth === 0 || wrap.clientHeight === 0) return;
      try { fit.fit(); } catch { return; }
      started = true;
      const att = attach(ptyId, chunk => term.write(chunk));
      for (const c of att.initial) term.write(c);
      detachBuffer = att.detach;
    };

    const ro = new ResizeObserver(() => {
      if (!started) start();
      else { try { fit.fit(); } catch {} }
    });
    ro.observe(wrap);
    start();

    // Forward keystrokes upstream.
    const offData = term.onData((data) => {
      // utf-8 → base64. Using TextEncoder for proper UTF-8 handling.
      const u8 = new TextEncoder().encode(data);
      let bin = "";
      for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
      const b64 = btoa(bin);
      client?.call("pty.write", { pty_id: ptyId, data_b64: b64 }).catch(() => {});
    });

    // Resize → server.
    const offResize = term.onResize(({ cols, rows }) => {
      client?.call("pty.resize", { pty_id: ptyId, cols, rows }).catch(() => {});
    });

    return () => {
      ro.disconnect();
      offData.dispose();
      offResize.dispose();
      detachBuffer?.();
      term.dispose();
      termRef.current = null;
      fitRef.current  = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ptyId]);

  // ResizeObserver handles fit on visibility transitions; this only refocuses.
  useEffect(() => {
    if (!active) return;
    const id = requestAnimationFrame(() => {
      termRef.current?.focus();
    });
    return () => cancelAnimationFrame(id);
  }, [active]);

  return (
    <div className="pty-tab">
      <div className="pty-meta muted small">
        {ptyInfo ? `${ptyInfo.cmd} · ${ptyInfo.cols}×${ptyInfo.rows}` : "(loading…)"}
      </div>
      <div className="pty-host" ref={wrapRef} />
    </div>
  );
}
