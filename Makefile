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

test:
	@command -v nvim >/dev/null 2>&1 || { \
		echo "error: nvim is required for tests"; \
		exit 127; \
	}
	nvim --headless -u tests/minimal_init.lua -i NONE -l tests/smoke.lua
