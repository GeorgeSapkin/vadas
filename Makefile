VADAS_BIN_DIR?=~/.local/bin
VADAS_BASH_COMPLETION_DIR?=~/.local/share/bash-completion/completions
VADAS_CONFIG_DIR?=~/.config/vadas
VADAS_TEMPLATE_DIR?=$(VADAS_CONFIG_DIR)/templates

.PHONY: check_deps
check_deps:
	@grep -E '^[[:space:]]*_ensure[[:space:]]+' vadas.sh | awk '{print $$2}' | sort -u | { \
		fail=0; \
		echo 'Checking dependencies:'; \
		while read -r cmd; do \
			if command -v "$$cmd" >/dev/null 2>&1; then \
				printf "[\033[0;32mPASS\033[0m] %s\n" "$$cmd"; \
			else \
				printf "[\033[0;31mFAIL\033[0m] %s\n" "$$cmd"; \
				fail=1; \
			fi; \
		done; \
		exit $$fail; \
	}

.PHONY: install_templates
install_templates: templates/*.xml
	mkdir -p $(VADAS_TEMPLATE_DIR)
	cp templates/* $(VADAS_TEMPLATE_DIR)

.PHONY: install_templates_dev
install_templates_dev: templates/*.xml
	mkdir -p $(VADAS_CONFIG_DIR)
	ln -s $(PWD)/templates $(VADAS_CONFIG_DIR)

.PHONY: install
install: check_deps clean install_templates *.exp vadas.sh vadas_completion.sh
	$(info Installing release version:)
	mkdir -p $(VADAS_BIN_DIR)
	mkdir -p $(VADAS_CONFIG_DIR)
	mkdir -p $(VADAS_BASH_COMPLETION_DIR)
	cp $(PWD)/*.exp $(VADAS_CONFIG_DIR)
	cp $(PWD)/vadas.sh $(VADAS_BIN_DIR)/vadas
	cp $(PWD)/vadas_completion.sh $(VADAS_BASH_COMPLETION_DIR)/vadas

.PHONY: install_dev
install_dev: check_deps clean install_templates_dev *.exp vadas.sh vadas_completion.sh
	$(info Installing development version:)
	mkdir -p $(VADAS_BIN_DIR)
	mkdir -p $(VADAS_CONFIG_DIR)
	mkdir -p $(VADAS_BASH_COMPLETION_DIR)
	ln -s $(PWD)/configure.exp $(VADAS_CONFIG_DIR)/configure.exp
	ln -s $(PWD)/connect.exp $(VADAS_CONFIG_DIR)/connect.exp
	ln -s $(PWD)/vadas.sh $(VADAS_BIN_DIR)/vadas
	ln -s $(PWD)/vadas_completion.sh $(VADAS_BASH_COMPLETION_DIR)/vadas

.PHONY: clean
clean:
	$(info Cleaning up)
	rm -rf $(VADAS_TEMPLATE_DIR)
	rm -f $(VADAS_BIN_DIR)/vadas
	rm -f $(VADAS_CONFIG_DIR)/*.exp
	rm -f $(VADAS_BASH_COMPLETION_DIR)/vadas
