LUA_DIRS := lua plugin tests
TEMP_DIR := $(patsubst %/,%,$(or $(TMPDIR),/tmp))
LUALS_STATE_DIR := $(TEMP_DIR)/agentic-flow-luals

.PHONY: lint format test

lint:
	@command -v lua-language-server >/dev/null 2>&1 || { \
		echo "error: lua-language-server is required for linting"; \
		exit 127; \
	}
	@command -v stylua >/dev/null 2>&1 || { \
		echo "error: stylua is required for format checks"; \
		exit 127; \
	}
	@command -v nvim >/dev/null 2>&1 || { \
		echo "error: nvim is required to resolve VIMRUNTIME for typechecking"; \
		exit 127; \
	}
	@vimruntime="$$(nvim --clean --headless --cmd 'lua io.write(vim.env.VIMRUNTIME)' --cmd 'quit')"; \
	test -n "$$vimruntime" || { echo "error: could not resolve VIMRUNTIME from nvim"; exit 1; }; \
	VIMRUNTIME="$$vimruntime" \
	lua-language-server --check=. --checklevel=Warning --check_format=pretty \
		--configpath=.luarc.json \
		--logpath="$(LUALS_STATE_DIR)/log" \
		--metapath="$(LUALS_STATE_DIR)/meta"
	stylua --check $(LUA_DIRS)

format:
	@command -v stylua >/dev/null 2>&1 || { \
		echo "error: stylua is required for formatting"; \
		exit 127; \
	}
	stylua $(LUA_DIRS)

# Run every spec headless; a failing spec aborts that file but the remaining
# files still run and get reported. Run one file with `make test FILE=tests/git_spec.lua`.
SPECS := $(wildcard tests/*_spec.lua)

test:
	@command -v nvim >/dev/null 2>&1 || { \
		echo "error: nvim is required for tests"; \
		exit 127; \
	}
	@status=0; \
	for spec in $(or $(FILE),$(SPECS)); do \
		if nvim --headless -u tests/minimal_init.lua -i NONE -l "$$spec"; then \
			printf 'PASS %s\n' "$$spec"; \
		else \
			printf 'FAIL %s\n' "$$spec"; \
			status=1; \
		fi; \
	done; \
	exit $$status
