.PHONY: test

# nvim -c "set runtimepath+=." -l test/gh_spec.lua

test:
ifeq ($(NEOVIM_PATH),)
	$(error NEOVIM_PATH is not set)
endif
	ln -sf $(shell pwd) $(NEOVIM_PATH)/test/functional/guh.nvim
	cd $(NEOVIM_PATH) && TEST_FILE=test/functional/guh.nvim/test/gh_spec.lua make functionaltest
