// Scope-aware quick-command editor. Three internal views:
//   - "list":    list editor for one scope (global or a specific set).
//   - "sets":    overview of all named sets + "+ new set" + per-set delete.
//   - "matches": comma/list editor for a set's matched program names.
//
// Replaces the inline QuickCommandsManager that the old MobileInputDock
// rendered. Drag-reorder, kind-aware row rendering, and the "+ new" picker
// live here so the dock only has to ship a single chip row + composer.

import * as React from "react";
import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import {
  addCommand, createSet, decodeEscapes, encodeEscapes, KEY_PRESETS,
  makeAltCommand, makeCdCommand, makeCtrlCommand, makePasteCommand,
  makePresetCommand, makeTextCommand, makePayload,
  moveCommand, payloadBytes, programKey, removeCommand, removeSet,
  renameSet, resetGlobalToDefaults, setMatches,
  updateCommand, useQuickCommandStore,
  type KeyPreset, type QuickCommand, type QuickCommandKind,
  type QuickCommandScope, type QuickCommandSet,
} from "../store/quickCommands";

interface Props {
  initialScope:   QuickCommandScope;
  runningProgram: string | null;
  onClose:        () => void;
}

type View =
  | { kind: "list";    scope: QuickCommandScope }
  | { kind: "sets" }
  | { kind: "matches"; setId: string };

export default function QuickCommandEditor({ initialScope, runningProgram, onClose }: Props) {
  const all = useQuickCommandStore();
  const [view, setView] = useState<View>({ kind: "list", scope: initialScope });

  const setForId = useCallback((id: string): QuickCommandSet | null => {
    return all.sets.find(s => s.id === id) ?? null;
  }, [all.sets]);

  // If the currently-viewed set was just deleted (e.g. user opened a set,
  // then navigated to Sets view and deleted it), fall back to a safe view.
  // Do this in an effect rather than during render to avoid an extra
  // commit cycle.
  useEffect(() => {
    if (view.kind === "list" && view.scope.kind === "set" && !setForId(view.scope.id)) {
      setView({ kind: "list", scope: { kind: "global" } });
    } else if (view.kind === "matches" && !setForId(view.setId)) {
      setView({ kind: "sets" });
    }
  }, [view, setForId]);

  let body: React.ReactNode;
  let title: string;

  if (view.kind === "list") {
    const setObj = view.scope.kind === "set" ? setForId(view.scope.id) : null;
    title = view.scope.kind === "global" ? "Global" : (setObj?.name ?? "Set");
    body = (
      <ListView
        scope={view.scope}
        setObj={setObj}
        runningProgram={runningProgram}
        onOpenSets={() => setView({ kind: "sets" })}
        onEditMatches={(id) => setView({ kind: "matches", setId: id })}
        onSwitchScope={(scope) => setView({ kind: "list", scope })}
      />
    );
  } else if (view.kind === "sets") {
    title = "Sets";
    body = (
      <SetsView
        sets={all.sets}
        runningProgram={runningProgram}
        onOpen={(scope) => setView({ kind: "list", scope })}
        onBack={() => setView({ kind: "list", scope: { kind: "global" } })}
      />
    );
  } else {
    const setObj = setForId(view.setId);
    if (!setObj) {
      // The effect above will redirect us to "sets"; render an empty modal
      // body for the one frame between the deletion and the redirect.
      title = "Matches";
      body = <></>;
    } else {
      title = `Matches — ${setObj.name}`;
      body = (
        <MatchesView
          setObj={setObj}
          onBack={() => setView({ kind: "list", scope: { kind: "set", id: setObj.id } })}
        />
      );
    }
  }

  return (
    <div className="mdock-modal-backdrop" onClick={onClose}>
      <div
        className="mdock-modal qce-modal"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-label="Quick command editor"
      >
        <header className="qce-header">
          <strong>{title}</strong>
          <button className="ghost small" onClick={onClose}>Done</button>
        </header>
        {body}
      </div>
    </div>
  );
}

// ─── List view ──────────────────────────────────────────────────────

interface ListViewProps {
  scope:          QuickCommandScope;
  setObj:         QuickCommandSet | null;
  runningProgram: string | null;
  onOpenSets:     () => void;
  onEditMatches:  (setId: string) => void;
  onSwitchScope:  (scope: QuickCommandScope) => void;
}

function ListView({ scope, setObj, runningProgram, onOpenSets, onEditMatches, onSwitchScope }: ListViewProps) {
  const all      = useQuickCommandStore();
  const items    = scope.kind === "global" ? all.global : (setObj?.commands ?? []);
  const [adding,  setAdding]  = useState<AddType | null>(null);
  const [editing, setEditing] = useState<QuickCommand | null>(null);

  // Pointer-based drag-reorder (mouse/touch in one path; HTML5 dnd doesn't
  // fire on iOS touch). Lifted unchanged from the previous inline manager.
  const listRef = useRef<HTMLUListElement | null>(null);
  const [drag, setDrag] = useState<{ id: string; toIdx: number } | null>(null);

  const findDropIdx = useCallback((clientY: number): number => {
    const ul = listRef.current;
    if (!ul) return items.length;
    const rows = ul.querySelectorAll<HTMLLIElement>("[data-cmd-id]");
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i].getBoundingClientRect();
      if (clientY < r.top + r.height / 2) return i;
    }
    return rows.length;
  }, [items.length]);

  const onHandleDown = useCallback((e: React.PointerEvent<HTMLElement>, id: string) => {
    e.preventDefault();
    e.stopPropagation();
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch { /* ignore */ }
    setDrag({ id, toIdx: items.findIndex(c => c.id === id) });
  }, [items]);

  const onHandleMove = useCallback((e: React.PointerEvent<HTMLElement>) => {
    setDrag(d => {
      if (!d) return d;
      const idx = findDropIdx(e.clientY);
      return idx === d.toIdx ? d : { ...d, toIdx: idx };
    });
  }, [findDropIdx]);

  const onHandleUp = useCallback((e: React.PointerEvent<HTMLElement>) => {
    try { e.currentTarget.releasePointerCapture(e.pointerId); } catch { /* ignore */ }
    setDrag(d => {
      if (!d) return null;
      const fIdx = items.findIndex(c => c.id === d.id);
      const tIdx = d.toIdx;
      if (fIdx >= 0 && tIdx !== fIdx && tIdx !== fIdx + 1) {
        moveCommand(scope, fIdx, tIdx);
      }
      return null;
    });
  }, [items, scope]);

  const fromIdx = drag ? items.findIndex(c => c.id === drag.id) : -1;
  const showDropLine = drag != null
    && drag.toIdx !== fromIdx
    && drag.toIdx !== fromIdx + 1;

  // Special kinds (paste/ctrl/alt/cd) are unique within a scope: if one
  // already exists, the "+ menu" disables the duplicate.
  const hasKind = (k: QuickCommandKind) => items.some(c => c.kind === k);

  const onPickAdd = useCallback((type: AddType) => { setAdding(type); }, []);

  const onAddPreset = useCallback((p: KeyPreset) => {
    addCommand(scope, makePresetCommand(p));
    setAdding(null);
  }, [scope]);

  const onAddSpecial = useCallback((kind: "paste" | "ctrl" | "alt" | "cd") => {
    const cmd = kind === "paste" ? makePasteCommand()
              : kind === "ctrl"  ? makeCtrlCommand()
              : kind === "alt"   ? makeAltCommand()
              :                    makeCdCommand();
    addCommand(scope, cmd);
    setAdding(null);
  }, [scope]);

  const onAddSnippet = useCallback((label: string, payload: string, sendImmediately: boolean) => {
    if (!label.trim() || !payload) return;
    addCommand(scope, makeTextCommand(label.trim(), payload, { sendImmediately }));
    setAdding(null);
  }, [scope]);

  return (
    <>
      {scope.kind === "global" && runningProgram && !all.sets.some(s => s.matches.includes(runningProgram)) && (
        <div className="qce-hint">
          <span className="muted small">Currently running <code>{runningProgram}</code> — </span>
          <button
            className="ghost small"
            onClick={() => {
              const id = createSet(runningProgram, [runningProgram]);
              onSwitchScope({ kind: "set", id });
            }}
          >Customize for {runningProgram}</button>
        </div>
      )}

      <ul ref={listRef} className="mdock-mgr-list qce-list">
        {items.map((c, i) => (
          <Fragment key={c.id}>
            {showDropLine && drag!.toIdx === i && <li className="mdock-drop-line" aria-hidden />}
            <ListRow
              cmd={c}
              isDragging={drag?.id === c.id}
              onEdit={() => { if (c.kind === "bytes") setEditing(c); }}
              onDelete={() => { if (confirm(`Delete "${c.label}"?`)) removeCommand(scope, c.id); }}
              onHandlePointerDown={(e) => onHandleDown(e, c.id)}
              onHandlePointerMove={onHandleMove}
              onHandlePointerUp={onHandleUp}
            />
          </Fragment>
        ))}
        {showDropLine && drag!.toIdx === items.length && (
          <li className="mdock-drop-line" aria-hidden />
        )}
        {items.length === 0 && <li className="muted small qce-empty">no commands yet</li>}
      </ul>

      <div className="qce-toolbar">
        <details className="qce-add">
          <summary className="small qce-add-summary">+ Add</summary>
          <div className="qce-add-menu">
            <button className="ghost small" onClick={() => onPickAdd("preset")}>Special key…</button>
            <button className="ghost small" onClick={() => onPickAdd("snippet")}>Text snippet…</button>
            <button className="ghost small" disabled={hasKind("paste")} onClick={() => onAddSpecial("paste")}>Paste</button>
            <button className="ghost small" disabled={hasKind("ctrl")}  onClick={() => onAddSpecial("ctrl")}>Ctrl</button>
            <button className="ghost small" disabled={hasKind("alt")}   onClick={() => onAddSpecial("alt")}>Alt</button>
            <button className="ghost small" disabled={hasKind("cd")}    onClick={() => onAddSpecial("cd")}>cd</button>
          </div>
        </details>
        <span style={{ flex: "1 1 auto" }} />
        <button className="ghost small" onClick={onOpenSets}>Sets…</button>
      </div>

      <div className="qce-toolbar">
        {scope.kind === "global" ? (
          <button
            className="ghost small"
            onClick={() => { if (confirm("Reset quick commands to defaults?")) resetGlobalToDefaults(); }}
          >Reset to defaults</button>
        ) : setObj && (
          <>
            <button className="ghost small" onClick={() => {
              const next = prompt("Rename set", setObj.name);
              if (next && next.trim()) renameSet(setObj.id, next.trim());
            }}>Rename</button>
            <button className="ghost small" onClick={() => onEditMatches(setObj.id)}>Edit matches…</button>
            <button
              className="ghost small"
              onClick={() => {
                if (confirm(`Delete set "${setObj.name}"?`)) {
                  removeSet(setObj.id);
                }
              }}
            >Delete set</button>
          </>
        )}
      </div>

      {adding === "preset" && (
        <PresetPicker onPick={onAddPreset} onCancel={() => setAdding(null)} />
      )}
      {adding === "snippet" && (
        <SnippetPicker onAdd={onAddSnippet} onCancel={() => setAdding(null)} />
      )}
      {editing && (
        <EditRowModal
          cmd={editing}
          onSave={(updated) => { updateCommand(scope, updated); setEditing(null); }}
          onCancel={() => setEditing(null)}
        />
      )}
    </>
  );
}

type AddType = "preset" | "snippet";

// ─── Row ────────────────────────────────────────────────────────────

interface ListRowProps {
  cmd: QuickCommand;
  isDragging: boolean;
  onEdit:   () => void;
  onDelete: () => void;
  onHandlePointerDown: (e: React.PointerEvent<HTMLElement>) => void;
  onHandlePointerMove: (e: React.PointerEvent<HTMLElement>) => void;
  onHandlePointerUp:   (e: React.PointerEvent<HTMLElement>) => void;
}

function kindLabel(kind: QuickCommandKind): string {
  switch (kind) {
    case "paste": return "clipboard";
    case "ctrl":  return "sticky modifier";
    case "alt":   return "sticky modifier";
    case "cd":    return "directory picker";
    case "bytes": return "";
  }
}

function ListRow({
  cmd, isDragging, onEdit, onDelete,
  onHandlePointerDown, onHandlePointerMove, onHandlePointerUp,
}: ListRowProps) {
  const subtitle = cmd.kind === "bytes" ? encodeEscapes(payloadBytes(cmd)) : kindLabel(cmd.kind);
  return (
    <li
      className={"mdock-mgr-row" + (isDragging ? " dragging" : "")}
      data-cmd-id={cmd.id}
    >
      <button
        className="mdock-mgr-handle"
        onPointerDown={onHandlePointerDown}
        onPointerMove={onHandlePointerMove}
        onPointerUp={onHandlePointerUp}
        onPointerCancel={onHandlePointerUp}
        title="Drag to reorder"
        aria-label="Drag to reorder"
      >≡</button>
      <span className="mdock-mgr-label">
        {cmd.symbol && <span className="qce-glyph" aria-hidden>{cmd.symbol}</span>}
        {cmd.label}
      </span>
      <code className="mdock-mgr-value">{subtitle}</code>
      {cmd.kind === "bytes" && cmd.sendImmediately && <span className="pill small">↵</span>}
      <span style={{ flex: "1 1 auto" }} />
      {cmd.kind === "bytes" && <button className="ghost small" onClick={onEdit}>edit</button>}
      <button className="ghost small" onClick={onDelete} title="Delete">✕</button>
    </li>
  );
}

// ─── Add pickers ────────────────────────────────────────────────────

function PresetPicker({ onPick, onCancel }: { onPick: (p: KeyPreset) => void; onCancel: () => void }) {
  return (
    <div className="mdock-modal-backdrop qce-sub-backdrop" onClick={onCancel}>
      <div className="mdock-modal qce-preset-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Pick a special key">
        <header className="qce-header">
          <strong>Special key</strong>
          <button className="ghost small" onClick={onCancel}>Cancel</button>
        </header>
        <div className="qce-preset-grid">
          {KEY_PRESETS.map(p => (
            <button
              key={p.key}
              className="qce-preset-cell"
              onClick={() => onPick(p)}
              title={p.label}
            >
              <span className="qce-preset-glyph">{p.symbol ?? p.label}</span>
              {p.symbol && p.symbol !== p.label && <span className="muted small">{p.label}</span>}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function SnippetPicker({
  onAdd, onCancel,
}: { onAdd: (label: string, payload: string, sendImmediately: boolean) => void; onCancel: () => void }) {
  const [label, setLabel] = useState("");
  const [value, setValue] = useState("");
  const [sendImmediately, setSI] = useState(true);
  return (
    <div className="mdock-modal-backdrop qce-sub-backdrop" onClick={onCancel}>
      <div className="mdock-modal qce-snippet-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Add text snippet">
        <header className="qce-header">
          <strong>Text snippet</strong>
          <button className="ghost small" onClick={onCancel}>Cancel</button>
        </header>
        <div className="qce-form">
          <label className="qce-form-row">
            <span className="muted small">Label</span>
            <input type="text" value={label} onChange={(e) => setLabel(e.target.value)} placeholder="e.g. ls -al" autoFocus />
          </label>
          <label className="qce-form-row">
            <span className="muted small">Value (\n / \t / \e / \xHH for control chars)</span>
            <textarea
              rows={3}
              value={value}
              onChange={(e) => setValue(e.target.value)}
              placeholder="ls -al\n"
              spellCheck={false}
            />
          </label>
          <label className="row tight small">
            <input type="checkbox" checked={sendImmediately} onChange={(e) => setSI(e.target.checked)} />
            run on tap (send immediately)
          </label>
        </div>
        <footer className="qce-footer">
          <button
            className="small"
            disabled={!label.trim() || !value}
            onClick={() => onAdd(label, decodeEscapes(value), sendImmediately)}
          >Add</button>
        </footer>
      </div>
    </div>
  );
}

function EditRowModal({
  cmd, onSave, onCancel,
}: { cmd: QuickCommand; onSave: (c: QuickCommand) => void; onCancel: () => void }) {
  const [label, setLabel] = useState(cmd.label);
  const [value, setValue] = useState(encodeEscapes(payloadBytes(cmd)));
  const [sendImmediately, setSI] = useState(cmd.sendImmediately);
  const [symbol, setSymbol] = useState(cmd.symbol ?? "");

  return (
    <div className="mdock-modal-backdrop qce-sub-backdrop" onClick={onCancel}>
      <div className="mdock-modal qce-snippet-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Edit command">
        <header className="qce-header">
          <strong>Edit</strong>
          <button className="ghost small" onClick={onCancel}>Cancel</button>
        </header>
        <div className="qce-form">
          <label className="qce-form-row">
            <span className="muted small">Label</span>
            <input type="text" value={label} onChange={(e) => setLabel(e.target.value)} autoFocus />
          </label>
          <label className="qce-form-row">
            <span className="muted small">Symbol (Unicode glyph; blank = use label)</span>
            <input type="text" value={symbol} onChange={(e) => setSymbol(e.target.value)} placeholder="e.g. ↑" />
          </label>
          <label className="qce-form-row">
            <span className="muted small">Value (\n / \t / \e / \xHH)</span>
            <textarea rows={3} value={value} onChange={(e) => setValue(e.target.value)} spellCheck={false} />
          </label>
          <label className="row tight small">
            <input type="checkbox" checked={sendImmediately} onChange={(e) => setSI(e.target.checked)} />
            run on tap (send immediately)
          </label>
        </div>
        <footer className="qce-footer">
          <button
            className="small"
            disabled={!label.trim() || !value}
            onClick={() => {
              const decoded = decodeEscapes(value);
              const payloadU8 = new TextEncoder().encode(decoded);
              onSave({
                ...cmd,
                label: label.trim(),
                symbol: symbol.trim() || undefined,
                sendImmediately,
                payloadB64: makePayload(payloadU8),
              });
            }}
          >Save</button>
        </footer>
      </div>
    </div>
  );
}

// ─── Sets view ──────────────────────────────────────────────────────

interface SetsViewProps {
  sets:           QuickCommandSet[];
  runningProgram: string | null;
  onOpen:         (scope: QuickCommandScope) => void;
  onBack:         () => void;
}

function SetsView({ sets, runningProgram, onOpen, onBack }: SetsViewProps) {
  const onNew = useCallback(() => {
    const name = prompt("New set name");
    if (!name || !name.trim()) return;
    const id = createSet(name.trim(), []);
    onOpen({ kind: "set", id });
  }, [onOpen]);

  return (
    <>
      <div className="qce-toolbar">
        <button className="ghost small" onClick={onBack}>← Back</button>
        <span style={{ flex: "1 1 auto" }} />
        <button className="ghost small" onClick={onNew}>+ New set</button>
      </div>
      <ul className="qce-sets-list">
        <li className="qce-sets-row" onClick={() => onOpen({ kind: "global" })}>
          <span className="qce-sets-name">Global</span>
          <span className="muted small">fallback list</span>
        </li>
        {sets.map(s => (
          <li
            key={s.id}
            className="qce-sets-row"
            onClick={() => onOpen({ kind: "set", id: s.id })}
          >
            <span className="qce-sets-name">{s.name}</span>
            <span className="muted small">
              {s.matches.length === 0 ? "(no matches)" : s.matches.join(", ")}
            </span>
            <span style={{ flex: "1 1 auto" }} />
            <button
              className="ghost small"
              onClick={(e) => {
                e.stopPropagation();
                if (confirm(`Delete set "${s.name}"?`)) removeSet(s.id);
              }}
              title="Delete"
            >✕</button>
          </li>
        ))}
        {sets.length === 0 && <li className="muted small qce-empty">no sets yet</li>}
      </ul>
      {runningProgram && !sets.some(s => s.matches.includes(runningProgram)) && (
        <div className="qce-hint">
          <span className="muted small">Currently running <code>{runningProgram}</code> — </span>
          <button
            className="ghost small"
            onClick={() => {
              const id = createSet(runningProgram, [runningProgram]);
              onOpen({ kind: "set", id });
            }}
          >Customize for {runningProgram}</button>
        </div>
      )}
    </>
  );
}

// ─── Matches view ───────────────────────────────────────────────────

interface MatchesViewProps {
  setObj: QuickCommandSet;
  onBack: () => void;
}

function MatchesView({ setObj, onBack }: MatchesViewProps) {
  const [text, setText] = useState(setObj.matches.join(", "));

  const save = useCallback(() => {
    const parts = text
      .split(",")
      .map(s => programKey(s.trim()))
      .filter((s): s is string => !!s);
    // dedupe, preserve order
    const seen = new Set<string>();
    const out: string[] = [];
    for (const p of parts) { if (!seen.has(p)) { seen.add(p); out.push(p); } }
    setMatches(setObj.id, out);
    onBack();
  }, [setObj.id, text, onBack]);

  return (
    <>
      <div className="qce-toolbar">
        <button className="ghost small" onClick={onBack}>← Back</button>
        <span style={{ flex: "1 1 auto" }} />
        <button className="small" onClick={save}>Save</button>
      </div>
      <div className="qce-form" style={{ padding: "0 12px 12px" }}>
        <label className="qce-form-row">
          <span className="muted small">Program names — comma-separated. Each is reduced to its basename (e.g. "/usr/bin/vim" → "vim").</span>
          <textarea rows={4} value={text} onChange={(e) => setText(e.target.value)} spellCheck={false} placeholder="claude, vim" />
        </label>
      </div>
    </>
  );
}

