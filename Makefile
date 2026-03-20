SHELL := /usr/bin/env bash

.PHONY: lint

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		find . -maxdepth 2 -type f -name '*.sh' -print0 | xargs -0r shellcheck; \
	else \
		echo "shellcheck is not installed"; \
	fi
