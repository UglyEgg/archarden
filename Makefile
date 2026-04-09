## SPDX-License-Identifier: GPL-3.0-or-later
## Copyright 2026 Richard Majewski

SHELL := /bin/bash

lint:
	shellcheck archarden lib/*.sh scripts/*.sh
	./scripts/check-naming.sh

fmt:
	shfmt -w archarden lib/*.sh scripts/*.sh

fmt-check:
	shfmt -d archarden lib/*.sh scripts/*.sh

test:
	bats test/

check-naming:
	./scripts/check-naming.sh

install:
	sudo ./archarden $(EXTRA_FLAGS)

dry-run:
	sudo ./archarden --dry-run --skip-firewall-enable $(EXTRA_FLAGS)

.PHONY: lint fmt fmt-check test install dry-run check-naming

docs-functions:
	./scripts/gen_function_docs.py

docs-nav-check:
	./scripts/check-mkdocs-nav.py

docs: docs-functions docs-nav-check
	@echo "Docs generated. Run 'mkdocs serve' if installed."
