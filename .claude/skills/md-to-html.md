# Skill: Convert Markdown to Beautiful Static HTML

## Purpose

Convert `.md` documentation files into single-file, self-contained static HTML
pages that follow our dark-themed design system. The output must be visually
polished, easy to navigate, and include diagrams that make complex ideas
accessible to humans.

---

## Output Requirements

1. **Single `.html` file** — all CSS is inlined in a `<style>` block (no
   external dependencies, no JS frameworks, no build step).
2. **Sidebar navigation** — fixed left nav generated from the document's heading
   structure (`h2` = section, `h3` = sub).
3. **Responsive** — sidebar collapses on viewports < 900 px.
4. **Diagrams are mandatory** — every flow, architecture, or relationship
   described in the markdown MUST have a corresponding inline SVG or ASCII
   diagram (see the Diagrams section below).

---

## Mandatory CSS Theme

All generated HTML pages MUST use the following CSS variables and base styles
verbatim. Do NOT alter the color palette or typography — consistency across all
docs pages is critical.

```css
:root {
  --bg: #0f1117;
  --surface: #161b22;
  --surface-hover: #1c2129;
  --border: #30363d;
  --text: #c9d1d9;
  --text-muted: #8b949e;
  --text-bright: #f0f6fc;
  --accent: #58a6ff;
  --accent-dim: #1f6feb;
  --green: #3fb950;
  --green-dim: #238636;
  --yellow: #d29922;
  --yellow-dim: #9e6a03;
  --red: #f85149;
  --purple: #bc8cff;
  --orange: #f0883e;
  --cyan: #79c0ff;
  --code-bg: #0d1117;
  --code-border: #21262d;
  --nav-width: 280px;
  --font-mono: 'JetBrains Mono', 'Fira Code', 'SF Mono', Monaco, 'Cascadia Code', monospace;
  --font-sans: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

html { scroll-behavior: smooth; scroll-padding-top: 2rem; }

body {
  font-family: var(--font-sans);
  background: var(--bg);
  color: var(--text);
  line-height: 1.7;
  font-size: 16px;
}

/* Sidebar Navigation */
.sidebar {
  position: fixed;
  top: 0;
  left: 0;
  width: var(--nav-width);
  height: 100vh;
  background: var(--surface);
  border-right: 1px solid var(--border);
  overflow-y: auto;
  padding: 1.5rem 0;
  padding-bottom: 3.5rem;
  z-index: 100;
}

.sidebar::-webkit-scrollbar { width: 4px; }
.sidebar::-webkit-scrollbar-track { background: transparent; }
.sidebar::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }

.sidebar-title {
  font-size: 0.85rem;
  font-weight: 700;
  color: var(--accent);
  padding: 0 1.25rem 1rem;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  border-bottom: 1px solid var(--border);
  margin-bottom: 0.75rem;
}

.nav-section {
  padding: 0 0.75rem;
}

.nav-link {
  display: block;
  color: var(--text-muted);
  text-decoration: none;
  font-size: 0.82rem;
  padding: 0.35rem 0.75rem;
  border-radius: 6px;
  transition: all 0.15s ease;
  line-height: 1.4;
}

.nav-link:hover {
  color: var(--text);
  background: var(--surface-hover);
}

.nav-link.section {
  font-weight: 600;
  color: var(--text);
  margin-top: 0.5rem;
}

.nav-link.sub {
  padding-left: 1.5rem;
  font-size: 0.78rem;
}

/* Main Content */
.main {
  margin-left: var(--nav-width);
  max-width: 1100px;
  padding: 3rem 4rem;
}

/* Typography */
h1 {
  font-size: 2.5rem;
  font-weight: 800;
  color: var(--text-bright);
  margin-bottom: 0.75rem;
  letter-spacing: -0.5px;
}

.subtitle {
  font-size: 1.1rem;
  color: var(--text-muted);
  margin-bottom: 1.5rem;
  line-height: 1.6;
}

h2 {
  font-size: 1.75rem;
  font-weight: 700;
  color: var(--text-bright);
  margin-top: 3.5rem;
  margin-bottom: 1rem;
  padding-bottom: 0.5rem;
  border-bottom: 1px solid var(--border);
}

h3 {
  font-size: 1.25rem;
  font-weight: 600;
  color: var(--text-bright);
  margin-top: 2.5rem;
  margin-bottom: 0.75rem;
}

h4 {
  font-size: 1.05rem;
  font-weight: 600;
  color: var(--text);
  margin-top: 1.5rem;
  margin-bottom: 0.5rem;
}

p { margin-bottom: 1rem; }

ul, ol {
  margin-bottom: 1rem;
  padding-left: 1.5rem;
}

li { margin-bottom: 0.4rem; }

strong { color: var(--text-bright); }

code {
  font-family: var(--font-mono);
  font-size: 0.85em;
  background: var(--code-bg);
  border: 1px solid var(--code-border);
  border-radius: 4px;
  padding: 0.15em 0.4em;
  color: var(--cyan);
}

a {
  color: var(--accent);
  text-decoration: none;
}

a:hover { text-decoration: underline; }

hr {
  border: none;
  border-top: 1px solid var(--border);
  margin: 3rem 0;
}

/* Badge Pills */
.badge {
  display: inline-block;
  font-size: 0.7rem;
  font-weight: 600;
  padding: 0.2em 0.6em;
  border-radius: 12px;
  text-transform: uppercase;
  letter-spacing: 0.3px;
  vertical-align: middle;
}

.badge-nic { background: #1f3a5f; color: #58a6ff; }
.badge-gpu { background: #2d1f3f; color: #bc8cff; }
.badge-bond { background: #1f3f2a; color: #3fb950; }
.badge-vlan { background: #3f2d1f; color: #f0883e; }
.badge-tuning { background: #3f3f1f; color: #d29922; }
.badge-vfio { background: #3f1f1f; color: #f85149; }
.badge-sriov { background: #1f3a5f; color: #79c0ff; }

/* Constraint / Info Banners */
.constraint-banner {
  background: linear-gradient(135deg, #1a1f35, #161b22);
  border: 1px solid var(--accent-dim);
  border-radius: 8px;
  padding: 1rem 1.25rem;
  margin-bottom: 2rem;
  font-size: 0.9rem;
}

.constraint-banner strong { color: var(--accent); }

/* Code Blocks */
.code-block {
  background: var(--code-bg);
  border: 1px solid var(--code-border);
  border-radius: 8px;
  margin: 1.25rem 0;
  overflow: hidden;
}

.code-header {
  background: var(--surface);
  border-bottom: 1px solid var(--code-border);
  padding: 0.5rem 1rem;
  font-size: 0.75rem;
  color: var(--text-muted);
  font-family: var(--font-mono);
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.code-header .lang-badge {
  background: var(--accent-dim);
  color: var(--accent);
  padding: 0.1em 0.5em;
  border-radius: 4px;
  font-size: 0.7rem;
  font-weight: 600;
}

.code-content {
  padding: 1rem 1.25rem;
  overflow-x: auto;
  font-family: var(--font-mono);
  font-size: 0.82rem;
  line-height: 1.7;
  white-space: pre;
}

/* YAML Syntax highlighting */
.y-key { color: #79c0ff; }
.y-str { color: #a5d6ff; }
.y-num { color: #79c0ff; }
.y-bool { color: #ff7b72; }
.y-comment { color: #8b949e; font-style: italic; }
.y-ref { color: #d2a8ff; }
.y-type { color: #ffa657; }
.y-anchor { color: #7ee787; }

/* Tables */
.table-wrapper {
  overflow-x: auto;
  margin: 1.25rem 0;
  border-radius: 8px;
  border: 1px solid var(--border);
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.85rem;
}

thead {
  background: var(--accent-dim);
}

th {
  color: var(--text-bright);
  font-weight: 600;
  text-align: left;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid var(--border);
}

td {
  padding: 0.65rem 1rem;
  border-bottom: 1px solid var(--border);
  vertical-align: top;
}

tr:last-child td { border-bottom: none; }
tr:nth-child(even) { background: var(--surface); }
tr:nth-child(odd) { background: var(--code-bg); }

/* Callout Boxes */
.callout {
  border-radius: 8px;
  padding: 1rem 1.25rem;
  margin: 1.25rem 0;
  border-left: 4px solid;
  font-size: 0.9rem;
}

.callout-info {
  background: #0d2847;
  border-color: var(--accent);
}

.callout-warning {
  background: #2d1f0d;
  border-color: var(--yellow);
}

.callout-success {
  background: #0d2d1a;
  border-color: var(--green);
}

.callout-idea {
  background: #1f0d2d;
  border-color: var(--purple);
}

.callout-title {
  font-weight: 700;
  margin-bottom: 0.4rem;
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.3px;
}

.callout-info .callout-title { color: var(--accent); }
.callout-warning .callout-title { color: var(--yellow); }
.callout-success .callout-title { color: var(--green); }
.callout-idea .callout-title { color: var(--purple); }

/* Diagram containers */
.diagram-container {
  margin: 2rem 0;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.5rem;
  overflow-x: auto;
  min-width: 750px;
}

.diagram-title {
  font-size: 0.8rem;
  font-weight: 600;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.5px;
  margin-bottom: 1rem;
  text-align: center;
}

.diagram-container svg {
  display: block;
  margin: 0 auto;
}

/* Flow steps */
.flow-steps {
  margin: 1.5rem 0;
}

.flow-step {
  display: flex;
  align-items: flex-start;
  gap: 1rem;
  margin-bottom: 0.75rem;
  padding: 0.75rem 1rem;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 8px;
}

.flow-step-num {
  width: 28px;
  height: 28px;
  border-radius: 50%;
  background: var(--accent-dim);
  color: var(--accent);
  font-size: 0.75rem;
  font-weight: 700;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.flow-step-content {
  font-size: 0.9rem;
  flex: 1;
}

/* ASCII diagram in code block */
.ascii-diagram {
  background: var(--code-bg);
  border: 1px solid var(--code-border);
  border-radius: 8px;
  padding: 1.25rem;
  overflow-x: auto;
  font-family: var(--font-mono);
  font-size: 0.78rem;
  line-height: 1.5;
  white-space: pre;
  color: var(--text-muted);
}

/* Section number indicator */
.section-num {
  color: var(--accent);
  font-weight: 400;
}

/* Sidebar footer with Edit link */
.sidebar-footer {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 1rem 1.25rem;
  border-top: 1px solid var(--border);
  background: var(--surface);
}

.edit-link {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  color: var(--text-muted);
  text-decoration: none;
  font-size: 0.75rem;
  padding: 0.4rem 0.6rem;
  border-radius: 6px;
  transition: all 0.15s ease;
}

.edit-link:hover {
  color: var(--accent);
  background: var(--surface-hover);
}

/* Responsive */
@media (max-width: 900px) {
  .sidebar { display: none; }
  .main { margin-left: 0; padding: 2rem 1.5rem; }
}
```

---

## HTML Structure Template

Every generated page must follow this skeleton:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{{ DOCUMENT TITLE }}</title>
<style>
/* Paste the FULL CSS theme above here — verbatim, no modifications */
</style>
</head>
<body>

<!-- Sidebar Navigation -->
<nav class="sidebar">
  <div class="sidebar-title">{{ SHORT NAV TITLE }}</div>
  <div class="nav-section">
    <!-- h2 headings become .nav-link.section -->
    <a class="nav-link section" href="#id">N. Section Title</a>
    <!-- h3 headings become .nav-link.sub -->
    <a class="nav-link sub" href="#id">N.M Subsection Title</a>
  </div>
  <!-- Edit on GitHub link at bottom of sidebar -->
  <div class="sidebar-footer">
    <a class="edit-link" href="{{ REPO_URL }}/blob/main/md/{{ FILENAME }}.md" target="_blank" rel="noopener">
      <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M11.013 1.427a1.75 1.75 0 012.474 0l1.086 1.086a1.75 1.75 0 010 2.474l-8.61 8.61c-.21.21-.47.364-.756.445l-3.251.93a.75.75 0 01-.927-.928l.929-3.25a1.75 1.75 0 01.445-.758l8.61-8.61zm1.414 1.06a.25.25 0 00-.354 0L3.462 11.1a.25.25 0 00-.064.108l-.631 2.208 2.208-.63a.25.25 0 00.108-.064l8.61-8.61a.25.25 0 000-.354l-1.086-1.086z"/></svg>
      Edit source on GitHub
    </a>
  </div>
</nav>

<!-- Main Content -->
<main class="main">
  <h1>{{ Title }}</h1>
  <p class="subtitle">{{ One-paragraph summary }}</p>

  <!-- Optional constraint/info banner -->
  <div class="constraint-banner">
    <strong>Key constraint:</strong> ...
  </div>

  <!-- Sections begin here -->
  <h2 id="some-id"><span class="section-num">1.</span> Section Title</h2>
  ...
</main>

</body>
</html>
```

### Repository URL

The repository URL is defined in the `Makefile` as `REPO_URL` (default:
`https://github.com/SchSeba/docs`). When generating HTML, use this base URL to
construct the "Edit on GitHub" link:

- Link target: `{{ REPO_URL }}/blob/main/md/{{ filename }}.md`
- The link MUST point directly to the markdown source file in the repo

---

## Conversion Rules (MD → HTML)

| Markdown construct | HTML output |
|---|---|
| `# Title` | `<h1>` + `<p class="subtitle">` for the first paragraph |
| `## N. Section` | `<h2 id="..."><span class="section-num">N.</span> ...</h2>` |
| `## N.M Subsection` | `<h3 id="...">` |
| Fenced code blocks | `<div class="code-block"><div class="code-header"><span class="lang-badge">LANG</span> filename</div><div class="code-content">...</div></div>` |
| Tables | Wrap in `<div class="table-wrapper"><table>...</table></div>` |
| Ordered list of steps | Use `.flow-steps` / `.flow-step` markup for key workflow steps |
| `> **Note:**` blockquotes | `<div class="callout callout-info">` (or `-warning`, `-success`, `-idea`) |
| `> **Status/Companion/Depends on:**` blockquote | `<div class="related-docs">` banner with linked pills (see Cross-References section) |
| Inline `code` | `<code>code</code>` |
| Bold text | `<strong>text</strong>` |
| ASCII art diagrams | Replace with inline SVG in a `.diagram-container` (see below) |
| Horizontal rules `---` | `<hr>` |

### YAML Syntax Highlighting

When rendering YAML code blocks, apply span classes for syntax coloring:

- Keys: `<span class="y-key">key</span>:`
- String values: `<span class="y-str">"value"</span>`
- Numbers: `<span class="y-num">8080</span>`
- Booleans: `<span class="y-bool">true</span>`
- Comments: `<span class="y-comment"># comment</span>`
- Template refs: `<span class="y-ref">{{ step.field }}</span>`
- Type tags: `<span class="y-type">!type</span>`

---

## Document Cross-References (depends on / related to)

Markdown files may contain metadata blockquotes at the top that reference other
documents or external resources. These commonly use patterns like:

```markdown
> **Status:** Selected Design  
> **Companion documents:**
> [DRA Chainable Networking Proposal](dra-chainable-networking-proposal.md) |
> [Discovery Brainstorm](dra-resourceslice-discovery-brainstorm.md)  
> **Upstream dependencies:**
> [KEP 4815 — SharedCounters](https://github.com/...) (GA, K8s 1.35+) |
> [KEP 5075 — Consumable Capacity](https://github.com/...) (Beta, K8s 1.36)
```

### How to Render Cross-References

When the markdown has a blockquote at the top containing fields like
**Companion documents:**, **Upstream dependencies:**, **Depends on:**,
**Related to:**, **See also:**, or **Status:**, render it as a
`.related-docs` banner immediately after the subtitle:

```html
<div class="related-docs">
  <div class="related-docs-status">
    <span class="status-badge">Selected Design</span>
  </div>
  <div class="related-docs-group">
    <span class="related-docs-label">Companion documents:</span>
    <a class="related-docs-link" href="html/dra-chainable-networking-proposal.html">DRA Chainable Networking Proposal</a>
    <a class="related-docs-link" href="html/dra-resourceslice-discovery-brainstorm.html">Discovery Brainstorm</a>
  </div>
  <div class="related-docs-group">
    <span class="related-docs-label">Upstream dependencies:</span>
    <a class="related-docs-link external" href="https://github.com/...">KEP 4815 — SharedCounters <span class="version-tag">GA, K8s 1.35+</span></a>
    <a class="related-docs-link external" href="https://github.com/...">KEP 5075 — Consumable Capacity <span class="version-tag">Beta, K8s 1.36</span></a>
  </div>
</div>
```

### Link Resolution Rules

When converting cross-reference links:

1. **Local `.md` links** (e.g. `dra-chainable-networking-proposal.md`) — rewrite
   the href to point to the corresponding HTML file: `html/<basename>.html`.
   If both docs live on the same site, use a relative path.
2. **External links** (e.g. `https://github.com/...`) — keep the href as-is,
   add `target="_blank" rel="noopener"` and the `.external` class.
3. **Version/status annotations** in parentheses (e.g. `(GA, K8s 1.35+)`) —
   render inside a `<span class="version-tag">` next to the link.

### Required CSS for Cross-References

Add this to the theme CSS block:

```css
/* Related documents banner */
.related-docs {
  background: linear-gradient(135deg, #1a1f35, #161b22);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 1rem 1.25rem;
  margin-bottom: 2.5rem;
  font-size: 0.85rem;
}

.related-docs-status {
  margin-bottom: 0.6rem;
}

.status-badge {
  display: inline-block;
  background: var(--green-dim);
  color: var(--green);
  font-size: 0.7rem;
  font-weight: 600;
  padding: 0.2em 0.6em;
  border-radius: 12px;
  text-transform: uppercase;
  letter-spacing: 0.3px;
}

.related-docs-group {
  margin-top: 0.5rem;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.4rem;
}

.related-docs-label {
  font-weight: 600;
  color: var(--text-muted);
  margin-right: 0.3rem;
}

.related-docs-link {
  display: inline-block;
  color: var(--accent);
  background: var(--code-bg);
  border: 1px solid var(--code-border);
  border-radius: 4px;
  padding: 0.15em 0.5em;
  text-decoration: none;
  font-size: 0.8rem;
  transition: border-color 0.15s ease;
}

.related-docs-link:hover {
  border-color: var(--accent);
  text-decoration: none;
}

.related-docs-link.external::after {
  content: " ↗";
  font-size: 0.7em;
  opacity: 0.6;
}

.version-tag {
  font-size: 0.7rem;
  color: var(--text-muted);
  font-style: italic;
  margin-left: 0.2em;
}
```

### When to Apply This

- Look for blockquotes (`>`) at the **very top** of the markdown (before or
  immediately after the `# Title` heading)
- Any field with bold label followed by links is a cross-reference group
- Common field names: `Status`, `Companion documents`, `Upstream dependencies`,
  `Depends on`, `Related to`, `See also`, `References`, `Supersedes`,
  `Superseded by`, `Part of`
- If a referenced local `.md` does NOT have a corresponding `.html` yet,
  still generate the link (it will work once that doc is also converted)

---

## CRITICAL: Diagrams

**Every conceptual flow, architecture, topology, or relationship described in
the document MUST have a visual diagram.** Diagrams are not optional — they are
the primary way humans understand complex systems. A page without diagrams is
incomplete.

### When to Create a Diagram

Create a diagram whenever the text describes:

- A DAG, pipeline, or chain of operations
- Component relationships / architecture
- Data flow between systems
- State machines or lifecycle transitions
- Network topologies (bonds, VLANs, interfaces)
- Scheduling or orchestration sequences
- Any relationship that would take more than 2 sentences to explain in prose

### How to Create Diagrams

#### Option 1: Inline SVG (preferred for most diagrams)

Hand-craft SVG inside a `.diagram-container`. This gives full control over the
dark-theme aesthetic.

```html
<div class="diagram-container">
  <div class="diagram-title">Diagram N — Descriptive Title</div>
  <svg width="700" height="300" viewBox="0 0 700 300" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <!-- Arrowhead marker (reuse across diagrams) -->
      <marker id="arrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
        <polygon points="0 0, 8 3, 0 6" fill="#58a6ff"/>
      </marker>
      <!-- Optional glow filter for emphasis -->
      <filter id="glow">
        <feGaussianBlur stdDeviation="2" result="blur"/>
        <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
      </filter>
    </defs>

    <!-- Nodes: rounded rects with colored borders -->
    <rect x="20" y="60" width="100" height="50" rx="8"
          fill="#1f3a5f" stroke="#58a6ff" stroke-width="1.5"/>
    <text x="70" y="82" text-anchor="middle"
          fill="#c9d1d9" font-size="12" font-weight="600">Node Label</text>
    <text x="70" y="100" text-anchor="middle"
          fill="#79c0ff" font-size="9">type annotation</text>

    <!-- Edges: lines with arrow markers -->
    <line x1="120" y1="85" x2="195" y2="130"
          stroke="#58a6ff" stroke-width="1.5" marker-end="url(#arrow)"/>

    <!-- Legend text -->
    <text x="350" y="280" text-anchor="middle"
          fill="#8b949e" font-size="10">Description of what arrows mean</text>
  </svg>
</div>
```

**SVG Style Rules:**

- Background: transparent (inherits from `.diagram-container` which is `var(--surface)`)
- Node fills: use the dim color variants (`#1f3a5f`, `#1f3f2a`, `#3f2d1f`, etc.)
- Node strokes: use the bright color variants (`#58a6ff`, `#3fb950`, `#f0883e`, etc.)
- Text: `#c9d1d9` for labels, `#8b949e` for legends/annotations
- Arrows/edges: `#58a6ff` (accent blue)
- Font: system sans for labels, keep sizes 9–13px
- Use `rx="8"` on rects for rounded corners
- Use `<marker>` defs for arrowheads — do NOT use hand-drawn arrow characters
- Number every diagram: "Diagram 1 — Title", "Diagram 2 — Title", ...

#### Option 2: ASCII Diagram (for simple relationships)

For trivially simple relationships (< 5 nodes, no branching), an ASCII diagram
inside the `.ascii-diagram` class is acceptable:

```html
<div class="ascii-diagram">
     vf0 ──┐
            ├── bond0 ──┬── vlan100 ── tune-vlan100
     vf1 ──┘            └── vlan200 ── tune-vlan200
</div>
```

**Prefer inline SVG for anything beyond the simplest linear chains.**

#### Diagram Color Coding by Domain

Use consistent colors to identify element types across all diagrams:

| Domain | Fill (dim) | Stroke (bright) | Text accent |
|---|---|---|---|
| NIC / SR-IOV | `#1f3a5f` | `#58a6ff` | `#79c0ff` |
| GPU | `#2d1f3f` | `#bc8cff` | `#bc8cff` |
| Bond | `#1f3f2a` | `#3fb950` | `#3fb950` |
| VLAN | `#3f2d1f` | `#f0883e` | `#f0883e` |
| Tuning | `#3f3f1f` | `#d29922` | `#d29922` |
| VFIO | `#3f1f1f` | `#f85149` | `#f85149` |
| Generic/Flow | `#161b22` | `#30363d` | `#8b949e` |

#### Diagram Sizing Guidelines

- Width: 600–800px for most diagrams (fits in `.main` max-width of 1100px)
- Height: scale to content, typically 200–400px
- Leave 20px padding on all sides inside the SVG viewBox
- Keep node spacing consistent (80–120px between connected nodes)

---

## Callout Usage

Use callouts to highlight key information:

```html
<!-- Info: general notes, clarifications -->
<div class="callout callout-info">
  <div class="callout-title">Note</div>
  <p>Additional context that helps understanding.</p>
</div>

<!-- Warning: gotchas, limitations, things that can go wrong -->
<div class="callout callout-warning">
  <div class="callout-title">Warning</div>
  <p>This approach has a known limitation...</p>
</div>

<!-- Success: positive outcomes, confirmed behaviors -->
<div class="callout callout-success">
  <div class="callout-title">Result</div>
  <p>After this step, the system is in a consistent state.</p>
</div>

<!-- Idea: future work, alternatives, design decisions -->
<div class="callout callout-idea">
  <div class="callout-title">Design Decision</div>
  <p>We chose X over Y because...</p>
</div>
```

---

## Badge Pills

Use badges inline for quick visual categorization:

```html
<span class="badge badge-nic">NIC</span>
<span class="badge badge-gpu">GPU</span>
<span class="badge badge-bond">BOND</span>
<span class="badge badge-vlan">VLAN</span>
<span class="badge badge-tuning">TUNING</span>
<span class="badge badge-vfio">VFIO</span>
<span class="badge badge-sriov">SR-IOV</span>
```

You can create additional badge classes following the pattern:
```css
.badge-custom { background: <dim-color>; color: <bright-color>; }
```

---

## Quality Checklist

Before delivering the HTML file, verify:

- [ ] All CSS variables match the theme above exactly
- [ ] Sidebar nav has entries for every `h2` (section) and `h3` (sub)
- [ ] Every `h2` and `h3` has a unique `id` attribute matching the nav `href`
- [ ] All code blocks use `.code-block` with `.code-header` and `.code-content`
- [ ] Tables are wrapped in `.table-wrapper`
- [ ] **At least one diagram exists for every major concept or flow**
- [ ] Diagrams use the correct color coding for their domain
- [ ] All diagrams are numbered sequentially
- [ ] **Cross-references** (depends on, related to, companion docs) are rendered as `.related-docs` with working links
- [ ] Local `.md` links rewritten to `html/<basename>.html`
- [ ] **"Edit source on GitHub" link** exists in the sidebar footer, pointing to the correct `md/` file in the repo
- [ ] Page renders correctly with no JS (pure HTML + CSS)
- [ ] File opens locally in any browser (`file://` protocol works)
- [ ] Responsive layout works (sidebar hidden < 900px)

---

## Common Mistakes to Avoid

1. **Skipping diagrams** — this is the #1 failure mode. If the markdown has an
   ASCII art block or describes a flow, it MUST become an SVG diagram.
2. **Using Mermaid or external JS** — output must be zero-dependency static
   HTML. Render all diagrams as inline SVG.
3. **Changing theme colors** — every page must look like it belongs to the same
   site. Copy the CSS verbatim.
4. **Forgetting the nav sidebar** — the sidebar is what makes these docs
   navigable. Generate it from headings.
5. **Flat code blocks** — always use the `.code-block` / `.code-header` /
   `.code-content` pattern, never bare `<pre>` tags.
6. **Missing `id` attributes** — every heading that appears in the nav needs an
   `id` for anchor links.
7. **Ignoring cross-references** — if the markdown has a top blockquote with
   "Companion documents", "Depends on", "Related to", etc., these MUST become
   clickable links in a `.related-docs` banner. Local `.md` references must be
   rewritten to their `.html` counterparts.
