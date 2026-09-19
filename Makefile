NVIM ?= nvim

.PHONY: test lint

test:
	$(NVIM) --headless -u tests/minimal_init.lua -c "luafile tests/spec.lua"

lint:
	@fail=0; \
	for f in $$(find lua plugin tests -name '*.lua'); do \
		luajit -bl "$$f" >/dev/null 2>&1 || { echo "syntax error: $$f"; fail=1; }; \
	done; \
	exit $$fail
