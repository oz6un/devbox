SCRIPTS = preflight.sh provision.sh setup-user.sh sync-code.sh destroy.sh \
          files/remote-setup.sh files/claude-notify.tmpl files/devbox-health.tmpl

.PHONY: check residue preflight provision setup sync all destroy

# Static gates that run locally (CI runs these plus cloud-init schema validation).
check: residue
	shellcheck $(SCRIPTS)
	bash -n $(SCRIPTS)
	@echo "check: OK"

preflight:
	./preflight.sh

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

# Generalization gate: no personal residue in TRACKED files outside LICENSE
# (git grep, so local gitignored secrets.env is never scanned or printed).
# rc semantics: 0=found(fail) 1=clean(pass) >=2=grep error(fail).
residue:
	@git grep -inE '(^|[^a-z])(m[e]rt|o[z]6un|o[z]gun)([^a-z]|$$)' -- ':(exclude)LICENSE'; \
	rc=$$?; if [ $$rc -eq 0 ]; then echo "personal residue found ^"; exit 1; \
	elif [ $$rc -ge 2 ]; then echo "residue grep errored"; exit 1; fi

# Tear it all down (Hetzner server + local state). Tailscale node removal is manual.
destroy:
	./destroy.sh
