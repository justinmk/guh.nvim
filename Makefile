.PHONY: test

test:
	nvim -c "set runtimepath+=." -l test/gh_spec.lua
