VADAS_BIN_DIR?=~/.local/bin
VADAS_BASH_COMPLETION_DIR?=~/.local/share/bash-completion/completions
VADAS_CONFIG_DIR?=~/.config/vadas
VADAS_TEMPLATE_DIR?=$(VADAS_CONFIG_DIR)/templates

.PHONY: install_templates
install_templates: templates/*.xml
	mkdir -p $(VADAS_TEMPLATE_DIR)
	cp templates/* $(VADAS_TEMPLATE_DIR)

.PHONY: install
install: clean install_templates vadas.sh vadas_completion.sh
	mkdir -p $(VADAS_BIN_DIR)
	mkdir -p $(VADAS_BASH_COMPLETION_DIR)
	cp $(PWD)/vadas.sh $(VADAS_BIN_DIR)/vadas
	cp $(PWD)/vadas_completion.sh $(VADAS_BASH_COMPLETION_DIR)/vadas

.PHONY: install_dev
install_dev: clean install_templates vadas.sh vadas_completion.sh
	mkdir -p $(VADAS_BIN_DIR)
	mkdir -p $(VADAS_BASH_COMPLETION_DIR)
	ln -s $(PWD)/vadas.sh $(VADAS_BIN_DIR)/vadas
	ln -s $(PWD)/vadas_completion.sh $(VADAS_BASH_COMPLETION_DIR)/vadas

.PHONY: clean
clean:
	rm -f $(VADAS_BIN_DIR)/vadas
	rm -f $(VADAS_BASH_COMPLETION_DIR)/vadas
