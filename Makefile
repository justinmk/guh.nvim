NVIM_PRG ?= nvim
TEST_FILE ?= test
TEST_FILTER ?=
# Cached in .deps/ ("rm -rf .deps" to update).
NVIM_TEST_VERSION ?= master
NVIM_TEST_URL ?= https://raw.githubusercontent.com/neovim/neovim/$(NVIM_TEST_VERSION)/test
TEST_DEPS := .deps/neovim/$(NVIM_TEST_VERSION)

# Downloads to a temp dir, renamed after all downloads succeed.
$(TEST_DEPS):
	rm -rf "$@.tmp"
	curl --parallel --fail --location --silent --show-error --create-dirs \
		--output "$@.tmp/test/#1" "$(NVIM_TEST_URL)/{\
	assert.lua,\
	client/rpc_stream.lua,\
	client/session.lua,\
	client/uv_stream.lua,\
	functional/preload.lua,\
	functional/testnvim.lua,\
	functional/testnvim/exec_lua.lua,\
	functional/ui/screen.lua,\
	harness.lua,\
	reporter.lua,\
	runner.lua,\
	testutil.lua}"
	mv "$@.tmp" "$@"

# LUA_PATH: `exec_lua` requires test modules in the Nvim under test.
.PHONY: test
test: $(TEST_DEPS)
	GH_TOKEN="$${GH_TOKEN:-$$(gh auth token 2>/dev/null)}" NVIM_LOG_FILE="$(abspath .deps/nvim.log)" \
		LUA_PATH="$(abspath $(TEST_DEPS))/?.lua;;" \
		"$(NVIM_PRG)" --clean -l "$(TEST_DEPS)/test/runner.lua" -X"$(abspath .deps/xdg)" -v \
		--helper="$(TEST_DEPS)/test/functional/preload.lua" $(if $(TEST_FILTER),--filter="$(TEST_FILTER)") "$(TEST_FILE)"
