SHELL := /usr/bin/env bash

.PHONY: lint

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh; \
	else \
		echo "shellcheck is not installed"; \
	fi
