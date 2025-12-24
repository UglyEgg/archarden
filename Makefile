SHELL := /bin/bash

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck harden lib/utils.sh templates/containers/podman-run-npm.sh; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

install:
	sudo ./harden $(EXTRA_FLAGS)

dry-run:
	sudo ./harden --dry-run --non-interactive --skip-firewall-enable $(EXTRA_FLAGS)

.PHONY: lint install dry-run
