SHELL := /usr/bin/env bash
LOCAL_BIN := /home/ralexander/.local/bin
PATH := $(LOCAL_BIN):$(PATH)

.PHONY: fmt lint check

fmt:
	@find . -maxdepth 2 -type f -name '*.sh' -print0 | xargs -0r shfmt -w -i 2 -ci

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		find . -maxdepth 2 -type f -name '*.sh' -print0 | xargs -0r shellcheck; \
	else \
		echo "shellcheck is not installed"; \
	fi

check: fmt lint
