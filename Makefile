.PHONY: check provision setup sync all

# Static gates that run locally (CI runs these plus cloud-init schema validation).
check:
	shellcheck provision.sh setup-user.sh sync-code.sh files/remote-setup.sh
	bash -n provision.sh setup-user.sh sync-code.sh files/remote-setup.sh
	@echo "check: OK"

provision:
	./provision.sh

setup:
	./setup-user.sh

sync:
	./sync-code.sh

all: provision setup sync
