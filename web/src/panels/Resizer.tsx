// Thin draggable seam between two flex items. The hosting parent decides
// the axis; this component only renders the visual handle and forwards
// pointer events to the caller's useDragSize handler.

interface Props {
  axis:          "x" | "y";
  onPointerDown: (e: React.PointerEvent) => void;
}

export default function Resizer({ axis, onPointerDown }: Props) {
  return (
    <div
      className={`resizer resizer-${axis}`}
      role="separator"
      aria-orientation={axis === "x" ? "vertical" : "horizontal"}
      onPointerDown={onPointerDown}
    />
  );
}
