REPO_URL ?= https://github.com/SchSeba/docs

.PHONY: validate generate install-hooks

# Stream filter: shows text output and tool calls in real-time
define STREAM_FILTER
jq -rj 'if .type == "assistant" then \
  (.message.content[]? | if .type == "text" then .text \
  elif .type == "tool_use" then "\n[tool: " + .name + "]\n" \
  else empty end) \
elif .type == "result" then \
  (.result // empty) \
else empty end'
endef

validate:
	@echo "==> Running validation..."
	@claude -p "Use the skill at .claude/skills/validate-html-md.md to validate all files. Output ONLY 'PASS' if all checks pass, or 'FAIL: <details>' for each mismatch." \
		--output-format stream-json --verbose \
		| tee .validation-raw.json \
		| $(STREAM_FILTER) \
		| tee .validation-result
	@echo ""
	@echo "==> Checking result..."
	@grep -qx "PASS" .validation-result || (echo "VALIDATION FAILED"; rm -f .validation-result .validation-raw.json; exit 1)
	@rm -f .validation-result .validation-raw.json
	@echo "VALIDATION PASSED"

generate:
	@echo "==> Checking for md changes..."
	@changed_md=$$(git diff --name-only HEAD -- 'md/*.md' 'md/**'); \
	missing_html=""; \
	for f in md/*.md; do \
		base=$$(basename "$$f" .md); \
		[ -f "html/$$base.html" ] || missing_html="$$missing_html $$f"; \
	done; \
	if [ -z "$$changed_md" ] && [ -z "$$missing_html" ]; then \
		echo "==> No md changes and all HTMLs exist. Nothing to do."; \
		exit 0; \
	fi; \
	echo "==> Changed: $$changed_md $$missing_html"; \
	echo "==> Repository URL: $(REPO_URL)"; \
	echo "==> Generating HTML..."; \
	claude -p "The repository URL is: $(REPO_URL). \
	The following md files need HTML generation: $$changed_md $$missing_html \
	For each file, use the skill at .claude/skills/md-to-html.md to convert it into a matching .html file under html/. Each HTML page must include an 'Edit source on GitHub' link in the sidebar pointing to $(REPO_URL)/blob/main/md/<filename>.md \
	After generating, update README.md and index.html to include links and a one-line summary for every document in md/. Keep the listings in both files consistent with each other." \
		--output-format stream-json --verbose \
		| $(STREAM_FILTER)

install-hooks:
	@mkdir -p .git/hooks
	@cp hooks/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed successfully"
