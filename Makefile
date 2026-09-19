NVIM ?= nvim

.PHONY: test
test:
	$(NVIM) --headless -u NONE -l tests/run.lua

# Open the panes over dtest's sample solution, for a look at the real thing.
.PHONY: demo
demo:
	cd ../dtest/sample && $(NVIM) -c 'lua vim.opt.runtimepath:prepend("$(CURDIR)")' \
		-c 'lua require("dtest").setup({})' -c Dtest
