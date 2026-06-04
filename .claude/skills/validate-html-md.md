# Skill: Validate HTML/MD Parity

## Purpose

Validate that all generated HTML files in `html/` are consistent with their
markdown sources in `md/`, and that `README.md` and `index.html` document
listings are in sync.

This skill is designed to be invoked by the Claude CLI and produce
machine-parseable output for use in CI and git hooks.

---

## Output Format

Output EXACTLY one of:

- `PASS` — all checks passed (first line of output must be literally `PASS`)
- `FAIL: <filename> - <reason>` — one line per failure, first line starts with `FAIL:`

Do NOT output explanations, markdown formatting, or anything else. The output
must be parseable by `grep -q "^PASS"`.

---

## Checks to Perform

### Check A — HTML/MD Content Parity

For each `.md` file in `md/`:

1. Confirm a corresponding `.html` file exists in `html/` with the same
   basename (e.g. `md/foo.md` -> `html/foo.html`)
2. Read both files
3. Verify the following content from the MD is faithfully represented in the HTML:
   - All `##` and `###` headings appear in the HTML (as `<h2>` / `<h3>` text)
   - All table rows from the MD are present in the HTML `<table>` elements
   - All fenced code block contents appear inside `.code-content` divs
   - Key paragraphs (first paragraph of each section) have their content in the HTML
4. The HTML does NOT need to be character-for-character identical — it is a
   rendered representation. Focus on **semantic content equivalence**: the same
   information must be present.

### Check B — README.md vs index.html Consistency

1. Read `README.md` and extract the document listing table (the table under
   the `## Documents` heading)
2. Read `index.html` and extract all `.doc-card-title` and `.doc-card-summary`
   text content
3. Verify:
   - Both list exactly the same set of documents
   - Document titles match
   - Document summaries match (or are semantically equivalent)

### Check C — Completeness

1. List all `.md` files in `md/`
2. List all `.html` files in `html/`
3. Verify:
   - Every `.md` file has a corresponding `.html` file
   - Every `.html` file has a corresponding `.md` source
   - Every `.md` file is listed in the README.md documents table
   - Every `.md` file has a card entry in index.html

---

## Procedure

1. Run `ls md/*.md` to get the list of markdown sources
2. Run `ls html/*.html` to get the list of generated HTML files
3. For each markdown file, perform Check A
4. Perform Check B by reading README.md and index.html
5. Perform Check C using the file lists from steps 1-2
6. Collect all failures
7. If no failures: output `PASS`
8. If any failures: output each as `FAIL: <filename> - <reason>`

---

## Example Output (all pass)

```
PASS
```

## Example Output (failures)

```
FAIL: md/new-doc.md - no corresponding html/new-doc.html found
FAIL: README.md - missing entry for md/new-doc.md
FAIL: index.html - missing card for md/new-doc.md
FAIL: md/dra-chainable-networking-proposal.md - heading "## 5. Mixed NICs" not found in HTML
```

---

## Important Notes

- The markdown in `md/` is the **single source of truth**. The HTML is a
  rendered derivative.
- Do NOT modify any files during validation. This is a read-only check.
- Use the shell to list files and read contents. Do not assume which files exist.
- Be tolerant of minor whitespace/formatting differences between MD and HTML.
- Headings in HTML may have `<span class="section-num">` prefixes — strip those
  when comparing.
- Code blocks in HTML use `.code-content` divs with syntax highlighting spans —
  strip HTML tags when comparing code content.
