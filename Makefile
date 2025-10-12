.PHONY: test patch-runner

# nvim -c "set runtimepath+=." -l test/gh_spec.lua

# Run tests with "nvim -l" instead of "-ll", so tests can use the full "vim."
# API from the Nvim test harness process itself.
patch-runner:
	@if grep -q -- "-ll " "$(NEOVIM_PATH)/cmake/RunTests.cmake"; then \
		echo "Patching RunTests.cmake (-ll → -l)..."; \
		sed -i.bak 's/-ll /-l /' "$(NEOVIM_PATH)/cmake/RunTests.cmake" && rm -f "$(NEOVIM_PATH)/cmake/RunTests.cmake.bak"; \
	else \
		echo "RunTests.cmake already patched; skipping."; \
	fi


test: patch-runner
ifeq ($(NEOVIM_PATH),)
	$(error NEOVIM_PATH is not set)
endif
	ln -sf $(shell pwd) $(NEOVIM_PATH)/test/functional/guh.nvim
	cd $(NEOVIM_PATH) && TEST_FILE=test/functional/guh.nvim/test/gh_spec.lua make functionaltest
