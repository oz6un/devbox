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

# Sequential by construction — `make -j all` must not race setup/sync against
# a server that doesn't exist yet.
all:
	$(MAKE) provision
	$(MAKE) setup
	$(MAKE) sync
