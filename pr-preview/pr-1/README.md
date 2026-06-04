# Kubernetes Network Plumbing - Design Proposals

Design proposals and technical ideas around DRA (Dynamic Resource Allocation),
SR-IOV, and Kubernetes networking.

## Author

**Sebastian Scheinkman** ([@SchSeba](https://github.com/SchSeba))
Software Engineer at Red Hat

## Browse Online

Visit the GitHub Pages site to read the rendered HTML versions:
<!-- TODO: Update with actual GitHub Pages URL once deployed -->
`https://schseba.github.io/<repo-name>/`

## Documents

| Document | Summary |
|----------|---------|
| [DRA Chainable Networking Proposal](md/dra-chainable-networking-proposal.md) | Declarative, composable network configuration using DRA dependOn chaining for bonding, VLANs, tuning, and mixed NIC+GPU topologies in a single ResourceClaim |
| [DRA Network Device Discovery Design](md/dra-network-device-discovery-design.md) | ResourceSlice modeling for SR-IOV PFs/VFs using SharedCounters and consumable capacity KEPs |

## Usage

### Prerequisites

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) installed and configured

### Setup

Install the git pre-commit hook to enforce HTML/MD parity:

```bash
make install-hooks
```

### Generate HTML from Markdown

After editing markdown files in `md/`, regenerate the corresponding HTML:

```bash
make generate
```

This will:
1. Detect changed `.md` files via `git diff`
2. Convert each to a styled static HTML page under `html/`
3. Update `README.md` and `index.html` with links and summaries

### Validate

Check that all HTML files match their markdown sources and that README/index
listings are consistent:

```bash
make validate
```

## Contributing

1. Edit or create markdown files under `md/`
2. Run `make generate` to produce/update HTML
3. Verify with `make validate`
4. Commit — the pre-commit hook will block if HTML and MD are out of sync

## Repository Structure

```
.
├── index.html          # Landing page (GitHub Pages entry point)
├── html/               # Generated static HTML pages
├── md/                 # Source markdown (single source of truth)
├── .claude/skills/     # Claude CLI skill definitions
├── .github/workflows/  # GitHub Actions for Pages deployment
├── hooks/              # Git hook sources (installed via make)
├── Makefile            # Build/validate/hook targets
└── README.md           # This file
```
