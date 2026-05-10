// Plain xterm.js host for a PTY view. No block UI, no slot re-parenting,
// no serialization. The Terminal is created on mount and disposed on
// unmount; tab switches keep the component mounted (panes use `display:
// none`), so scrollback survives across switches.

import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";

import { useApp } from "../store/store";
import { attachPty } from "../store/ptyBuffers";

interface Props { ptyId: string; active: boolean }

const SCROLLBACK_ROWS = 5000;
const FONT_FAMILY = "ui-monospace, Menlo, Consolas, monospace";
const FONT_SIZE   = 13;

export default function PtyTab({ ptyId, active }: Props) {
  const ptyInfo = useApp(s => s.ptyInfos.get(ptyId));
  const hostRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const term = new Terminal({
      fontFamily:  FONT_FAMILY,
      fontSize:    FONT_SIZE,
      cursorBlink: true,
      scrollback:  SCROLLBACK_ROWS,
      theme: { background: "#0e0e0e", foreground: "#e6e6e6" },
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon());
    term.open(host);
    try { fit.fit(); } catch { /* ignore */ }
    termRef.current = term;

    // Forward user input to the server.
    const onData = term.onData(data => {
      const c = useApp.getState().client;
      if (!c) return;
      const u8 = new TextEncoder().encode(data);
      let bin = "";
      for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
      c.call("pty.write", { pty_id: ptyId, data_b64: btoa(bin) }).catch(() => { /* ignore */ });
    });

    // Stream PTY bytes into the terminal. ptyBuffers replays anything
    // that landed before mount.
    const att = attachPty(ptyId, chunk => {
      try { term.write(chunk); } catch { /* ignore */ }
    });
    for (const c of att.initial) {
      try { term.write(c); } catch { /* ignore */ }
    }

    // Resize: keep cols/rows in sync with the host element. De-dupe so
    // SIGWINCH doesn't flood on rAF resize loops.
    let lastCols = 0, lastRows = 0;
    const applyResize = () => {
      try { fit.fit(); } catch { /* ignore */ }
      const cols = term.cols, rows = term.rows;
      if (cols === lastCols && rows === lastRows) return;
      lastCols = cols; lastRows = rows;
      const c = useApp.getState().client;
      if (c) c.call("pty.resize", { pty_id: ptyId, cols, rows }).catch(() => { /* ignore */ });
    };
    applyResize();

    let rafId: number | null = null;
    const ro = new ResizeObserver(() => {
      if (rafId != null) return;
      rafId = requestAnimationFrame(() => { rafId = null; applyResize(); });
    });
    ro.observe(host);

    return () => {
      onData.dispose();
      att.detach();
      ro.disconnect();
      if (rafId != null) cancelAnimationFrame(rafId);
      termRef.current = null;
      // Defer dispose by a frame so any in-flight write callbacks don't
      // run against a torn-down terminal.
      requestAnimationFrame(() => { try { term.dispose(); } catch { /* ignore */ } });
    };
  }, [ptyId]);

  // Focus management: while the tab is active, the xterm should hold DOM
  // focus. (1) grab on activate, (2) re-grab on focusout unless the new
  // target is a real input.
  useEffect(() => {
    if (!active) return;
    const term = termRef.current;
    const host = hostRef.current;
    if (!term || !host) return;
    const id = requestAnimationFrame(() => { try { term.focus(); } catch { /* ignore */ } });

    const onFocusOut = (e: FocusEvent) => {
      const next = e.relatedTarget as HTMLElement | null;
      if (next && host.contains(next)) return;
      if (next && (next.tagName === "INPUT" || next.tagName === "TEXTAREA"
                   || next.isContentEditable)) return;
      requestAnimationFrame(() => {
        if (!active) return;
        try { termRef.current?.focus(); } catch { /* ignore */ }
      });
    };
    host.addEventListener("focusout", onFocusOut);
    return () => {
      cancelAnimationFrame(id);
      host.removeEventListener("focusout", onFocusOut);
    };
  }, [active, ptyId]);

  return (
    <div className="pty-tab">
      <div className="pty-meta muted small">
        {ptyInfo ? `${ptyInfo.cmd} · ${ptyInfo.cols}×${ptyInfo.rows}` : "(loading…)"}
      </div>
      <div className="pty-host" ref={hostRef} />
    </div>
  );
}
