.PHONY: validate test

TEST_CWD := $(shell pwd)

validate:
ifeq ($(NEOVIM_PATH),)
	$(error NEOVIM_PATH is not set. Export it or pass it like: make NEOVIM_PATH=/path/to/neovim test)
endif

# Run tests with "nvim -l" instead of "-ll", so tests can use the full "vim."
# API from the Nvim test harness process itself.
# patch-runner: validate
# 	@if grep -q -- "-ll " "$(NEOVIM_PATH)/cmake/RunTests.cmake"; then \
# 		echo "Patching RunTests.cmake (-ll → -l)..."; \
# 		sed -i.bak 's/-ll /-l /' "$(NEOVIM_PATH)/cmake/RunTests.cmake" && rm -f "$(NEOVIM_PATH)/cmake/RunTests.cmake.bak"; \
# 	else \
# 		echo "RunTests.cmake already patched; skipping."; \
# 	fi


test: validate
	ln -sf $(shell pwd) $(NEOVIM_PATH)/test/functional/guh.nvim
	@cd $(NEOVIM_PATH) && env GH_TOKEN=$${GH_TOKEN:-$(shell gh auth token 2>/dev/null)} \
		TEST_CWD=$(TEST_CWD) \
		TEST_FILE=test/functional/guh.nvim/test/gh_spec.lua make functionaltest
