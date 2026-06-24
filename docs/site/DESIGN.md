# Motif Site Design Spec

## Reference Direction

Zed is the reference for restraint and product confidence: minimal navigation,
large editorial rhythm, product UI as the main visual artifact, and a small set
of memorable capability pillars. Motif should feel adjacent to a high-trust
developer tool, not a decorative SaaS launch page.

## Principles

- Product first: the hero image should look like Motif's actual work surface
  concept: file tree, terminal, diff, sessions, and multi-device attach.
- Real proof beats mockups: product screenshot sections should use current Mac,
  iPhone, or web captures connected to a real motifd review server whenever
  possible. The screenshot gallery should cover the core product surfaces:
  sessions, terminal tabs, files, git diff, mobile input helpers, settings, and
  server connectivity.
- Quiet palette: use near-white surfaces, dark ink, one teal accent, and one warm
  secondary accent. No decorative blobs or one-note gradients.
- Dense but breathable: content should be skimmable like documentation, with
  enough whitespace to feel premium.
- Three-pillar framing: summarize Motif as Persistent, Mirrored, and Reachable.
- Technical clarity: usage, connection paths, and security should read as product
  documentation, not marketing filler.
- Bilingual parity: English and Chinese should preserve the same hierarchy and
  not require separate layouts.

## Visual Tokens

- Background: `#f7f8f6`
- Surface: `#ffffff`
- Secondary surface: `#eef3f0`
- Ink: `#111820`
- Muted text: `#66736e`
- Border: `#dce3df`
- Primary accent: `#1f8073`
- Secondary accent: `#b85c38`
- Radius: 8px for buttons/controls, 10–12px for cards, tables, and panels
- Max content width: 1120px

## Weight & Restraint

- Type weights stay in the 400–650 range. Body is 400, headings are 600, the
  hero name is 650. Avoid 800+ weights — they read as a template, not a tool.
- Section labels (kickers) are muted uppercase gray, not a colored mini-cap on
  every section. The teal accent appears sparingly: hero/security label, the
  feature tick, and the transport node.
- Prefer hairline borders and dividers over drop shadows and hover lifts. Cards
  share a single bordered grid rather than floating with elevation.

## Layout Rules

- Header remains compact and translucent, with no oversized nav treatment.
- Hero H1 remains the product name, with the value proposition in supporting copy.
- First viewport must show the product name, CTA, capability pillars, and a hint
  of the next section on desktop and mobile.
- Feature cards use a 3-column desktop grid, 2-column tablet grid, 1-column mobile
  grid.
- Tables and FAQ sections should feel like docs surfaces: precise borders, clear
  labels, restrained shadows.

## Iteration Checklist

- Desktop: no horizontal overflow at 1280px.
- Mobile: no horizontal overflow at 390px.
- Language toggle: English and Chinese both fit controls and cards.
- Hero image: visible but never competes with the text.
- CTA area: primary action is obvious; secondary action is visually quieter.
