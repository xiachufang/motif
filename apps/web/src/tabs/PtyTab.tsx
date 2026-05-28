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
import { consumeArmed, getSticky, resetSticky } from "../store/stickyModifiers";
import { applyModifiers, bytesToB64, keyEventToPayload } from "../util/applyModifiers";
import { useEffectiveTheme } from "../hooks/useResolvedTheme";
import { XTERM_THEME } from "../appearance";

interface Props { ptyId: string; active: boolean }

const SCROLLBACK_ROWS = 5000;
const FONT_FAMILY = "ui-monospace, Menlo, Consolas, monospace";

export default function PtyTab({ ptyId, active }: Props) {
  const ptyInfo = useApp(s => s.ptyInfos.get(ptyId));
  const fontSize = useApp(s => s.fontSize);
  const resolvedTheme = useEffectiveTheme();
  const hostRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);

  // Latest appearance, read inside the mount effect (which must not re-run on
  // every font/theme change — those are applied live by the effect below).
  const fontSizeRef = useRef(fontSize);
  const themeRef = useRef(resolvedTheme);
  fontSizeRef.current = fontSize;
  themeRef.current = resolvedTheme;

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const term = new Terminal({
      fontFamily:  FONT_FAMILY,
      fontSize:    fontSizeRef.current,
      cursorBlink: true,
      scrollback:  SCROLLBACK_ROWS,
      theme: XTERM_THEME[themeRef.current],
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    fitRef.current = fit;
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon());
    term.open(host);
    try { fit.fit(); } catch { /* ignore */ }
    termRef.current = term;

    // Sticky-modifier interception. xterm's `onData` only sees the *output*
    // bytes after its own modifier handling, which is too late to fold in
    // our chip-armed Ctrl/Alt state — by the time onData fires xterm has
    // already converted e.g. plain "c" to 0x63. Hook the key event so we
    // can synthesize the modifier-transformed bytes ourselves and swallow
    // xterm's default emit. When no sticky modifier is armed we always
    // return true so xterm's normal path runs unchanged (desktop users
    // without armed modifiers see no behavior change at all).
    term.attachCustomKeyEventHandler((ev: KeyboardEvent): boolean => {
      if (ev.type !== "keydown") return true;
      if (ev.isComposing) return true;
      if (ev.key === "Control" || ev.key === "Alt" || ev.key === "Meta" || ev.key === "Shift") return true;
      const { ctrl, alt } = getSticky(ptyId);
      if (ctrl === "inactive" && alt === "inactive") return true;
      const payload = keyEventToPayload(ev);
      if (!payload) return true;
      const out = applyModifiers(payload, ctrl !== "inactive", alt !== "inactive");
      const c = useApp.getState().client;
      c?.call("pty.write", { pty_id: ptyId, data_b64: bytesToB64(out) }).catch(() => { /* ignore */ });
      consumeArmed(ptyId);
      ev.preventDefault();
      return false;
    });

    // Forward user input to the server.
    const onData = term.onData(data => {
      const c = useApp.getState().client;
      if (!c) return;
      const u8 = new TextEncoder().encode(data);
      let bin = "";
      for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
      c.call("pty.write", { pty_id: ptyId, data_b64: btoa(bin) }).catch(() => { /* ignore */ });
    });

    // Stream PTY bytes into the terminal. History comes from motifd via
    // `/pty/<id>?since=<cursor>` when this tab becomes active.
    const att = attachPty(ptyId, chunk => {
      try { term.write(chunk); } catch { /* ignore */ }
    }, () => {
      try { term.reset(); } catch { /* ignore */ }
    });

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
      fitRef.current = null;
      // Clear any sticky Ctrl/Alt state for this PTY so a re-used id can't
      // inherit an "armed" or "locked" flag from a previous mount.
      resetSticky(ptyId);
      // Defer dispose by a frame so any in-flight write callbacks don't
      // run against a torn-down terminal.
      requestAnimationFrame(() => { try { term.dispose(); } catch { /* ignore */ } });
    };
  }, [ptyId]);

  // Apply font size + theme live to the mounted terminal. Theme is a pure
  // restyle; font size changes the cell geometry, so we refit and push the
  // new cols/rows. Only the active tab can be measured — inactive panes are
  // `display: none` (0 size), and fitting a zero-size element renders the
  // terminal blank; those are re-fit by the active effect when shown. The fit
  // is deferred a frame so layout has settled before we measure.
  useEffect(() => {
    const term = termRef.current;
    if (!term) return;
    term.options.fontSize = fontSize;
    term.options.theme = XTERM_THEME[resolvedTheme];
    if (!active) return;
    const id = requestAnimationFrame(() => {
      const fit = fitRef.current;
      if (!fit) return;
      try { fit.fit(); } catch { /* ignore */ }
      const c = useApp.getState().client;
      if (c) c.call("pty.resize", { pty_id: ptyId, cols: term.cols, rows: term.rows })
              .catch(() => { /* ignore */ });
    });
    return () => cancelAnimationFrame(id);
  }, [fontSize, resolvedTheme, active, ptyId]);

  // Only the active PTY tab owns a live `/pty/<id>` subscription. Inactive
  // tabs keep their xterm surface mounted; when reactivated, RpcClient uses
  // the per-PTY byte cursor to catch up from motifd's server-side ring.
  useEffect(() => {
    const c = useApp.getState().client;
    if (!c) return;
    if (!active) {
      c.deactivatePtyStream(ptyId);
      return;
    }
    c.activatePtyStream(ptyId).catch(() => { /* ignore */ });
    const id = requestAnimationFrame(() => {
      try { fitRef.current?.fit(); } catch { /* ignore */ }
    });
    return () => {
      cancelAnimationFrame(id);
      c.deactivatePtyStream(ptyId);
    };
  }, [active, ptyId]);

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
