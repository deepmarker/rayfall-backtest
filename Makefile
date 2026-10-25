.DEFAULT_GOAL := build
.PHONY: deps deps-gui build build-gui test kernel-test test-full gui live-test saved-test gui-test launcher-test fmt fmt-check engine
deps:
	opam install --deps-only --with-test -y rayfall-backtest.opam vendor/rayforce-ipc/*.opam
deps-gui:
	opam install --deps-only --with-test -y rayfall-backtest.opam rayfall-backtest-gui.opam vendor/rayforce-ipc/*.opam vendor/imguiml-ft/imguiml-ft.opam
build:
	$(MAKE) -C workbench build
build-gui:
	$(MAKE) -C workbench build-gui
test:
	$(MAKE) -C workbench test
kernel-test:
	cd backtest && $(foreach f,1 2 4 6,$(RAYFORCE) test/fixture$(f).rfl </dev/null &&) true
	$(MAKE) -C backtest test-oracle
test-full:
	$(MAKE) -C backtest test test-run
gui:
	$(MAKE) -C workbench gui $(if $(RUN),RUN="$(RUN)")
live-test:
	$(MAKE) -C workbench live-test
saved-test:
	$(MAKE) -C workbench saved-test
gui-test:
	$(MAKE) -C workbench viewer-test
launcher-test:
	$(MAKE) -C workbench launcher-test
fmt:
	$(MAKE) -C workbench fmt
fmt-check:
	$(MAKE) -C workbench fmt-check
engine:
	bash ci/build-rayforce.sh .engine
RAYFORCE ?= rayforce
