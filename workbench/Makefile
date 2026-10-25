RAYFORCE ?= rayforce
.PHONY: build build-gui test fmt fmt-check live-test saved-test gui viewer-test launcher-test
build:
	dune build --root .. workbench/bin/ workbench/test/ workbench/viewer/
build-gui:
	dune build --root .. workbench/gui/workbench_gui.exe
test:
	dune runtest --root .. workbench/test
fmt:
	dune build --root .. @workbench/fmt --auto-promote
fmt-check:
	dune build --root .. @workbench/fmt
live-test: build
	bash test/run_live.sh ../_build/default/workbench/test/live_test.exe ../backtest
saved-test: build
	bash test/run_saved.sh ../backtest
gui: build-gui
	../_build/default/workbench/gui/workbench_gui.exe -service-directory "$(CURDIR)/rayfall" -backtest-directory "$(abspath ../backtest)" -rayforce "$(RAYFORCE)" $(if $(RUN),-run "$(RUN)")
viewer-test: build build-gui
	bash test/run_viewer.sh ../backtest
launcher-test: build build-gui
	$(MAKE) -C .. sample-data
	bash test/run_launcher.sh ../backtest
