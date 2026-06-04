.PHONY: validate generate install-hooks

validate:
	@echo "==> Running validation..."
	@claude -p "Use the skill at .claude/skills/validate-html-md.md to validate all files. Output ONLY 'PASS' if all checks pass, or 'FAIL: <details>' for each mismatch." \
		--verbose 2>&1 | tee .validation-result
	@echo ""
	@echo "==> Checking result..."
	@tail -1 .validation-result | grep -q "^PASS" || (echo "VALIDATION FAILED"; rm -f .validation-result; exit 1)
	@rm -f .validation-result
	@echo "VALIDATION PASSED"

generate:
	@echo "==> Generating HTML from markdown..."
	@claude -p "Perform the following steps: \
	1. Run 'git diff --name-only' and identify any .md files under md/ that have changed. \
	2. For each changed .md file, use the skill at .claude/skills/md-to-html.md to convert it into a matching .html file under html/. \
	3. If any new md files were added OR if html files were regenerated, update README.md and index.html to include links and a one-line summary for every document in md/. Keep the listings in both files consistent with each other. \
	4. If no md files changed, check if any md files exist without a corresponding html and generate those too." \
		--verbose

install-hooks:
	@mkdir -p .git/hooks
	@cp hooks/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed successfully"
