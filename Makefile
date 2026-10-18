IMAGE ?= docker-softether-vpn-client:local
HADOLINT_IMAGE ?= hadolint/hadolint:v2.15.1
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.10.0
SHELL_FILES := assets/entrypoint.sh assets/dhcpcd-vpn tests/entrypoint_test.sh tests/image_smoke.sh

.PHONY: lint test build smoke check

lint:
	docker run --rm --volume "$(CURDIR):/work" --workdir /work $(SHELLCHECK_IMAGE) --shell=sh $(SHELL_FILES)
	docker run --rm --volume "$(CURDIR):/work" --workdir /work --entrypoint /bin/hadolint $(HADOLINT_IMAGE) Dockerfile

test:
	sh tests/entrypoint_test.sh

build:
	docker build --tag $(IMAGE) .

smoke:
	sh tests/image_smoke.sh $(IMAGE)

check: lint test
