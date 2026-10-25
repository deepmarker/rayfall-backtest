# Rayfall backtester. See README.md, doc/manual.md, doc/contracts.md and
# doc/plan.md.
#
#   make data                        # download and verify the data snapshots
#   make data-coinlake               # the spot snapshot through Coinlake's API
#   make test                        # with the rayforce on PATH
#   make test RAYFORCE=/path/to/rayforce
#   make test-run                    # two full runs must be byte-identical
#   make fmt                         # indent *.rfl as rayfall-mode does
#   make fmt-check                   # fail if any *.rfl is not formatted

RAYFORCE ?= rayforce
TESTS := $(wildcard test/fixture*.rfl) test/equivalence.rfl
RFL := $(wildcard *.rfl ref/*.rfl strategies/*.rfl test/*.rfl bench/*.rfl)
# Formatting uses the editor's own indentation: rayfall-mode from
# https://github.com/vbmithr/tree-sitter-rayfall, with its grammar installed.
RAYFALL_MODE ?= $(HOME)/code/rayforce/tree-sitter-rayfall
EMACS ?= emacs
FMT = $(EMACS) --batch -L $(RAYFALL_MODE) -l tools/rfl-fmt.el

# Data snapshots are not committed. data/<name>.sha256 pins each one:
# `make data` rebuilds it from the Binance public archive and keeps it only if
# the rebuilt files match the pinned checksums byte for byte.
#   spot     BTC, ETH and SOL (milestone 3: trend)
#   spot12   twelve large-cap USDT pairs (milestone 4: cross-sectional momentum)
SNAP_RANGE := --from 2023-10 --to 2026-09
spot_NAME := binance-spot-1d-2023-10_2026-09
spot_SYMS := BTCUSDT ETHUSDT SOLUSDT
spot12_NAME := binance-spot12-1d-2023-10_2026-09
spot12_SYMS := ADAUSDT AVAXUSDT BCHUSDT BNBUSDT BTCUSDT DOGEUSDT DOTUSDT ETHUSDT \
  LINKUSDT LTCUSDT SOLUSDT XRPUSDT
SNAPSHOTS := spot spot12

.PHONY: data test test-oracle test-run fmt fmt-check $(TESTS)

data: $(foreach s,$(SNAPSHOTS),data/$($(s)_NAME)/SHA256SUMS)

define snapshot_rule
data/$($(1)_NAME)/SHA256SUMS: data/$($(1)_NAME).sha256 tools/fetch_binance_klines.py
	rm -rf data/$($(1)_NAME).tmp
	python3 -I tools/fetch_binance_klines.py --cache data/.cache \
	  --out data/$($(1)_NAME).tmp $(SNAP_RANGE) $($(1)_SYMS)
	cd data/$($(1)_NAME).tmp && sha256sum --quiet --check SHA256SUMS
	cmp data/$($(1)_NAME).tmp/SHA256SUMS data/$($(1)_NAME).sha256 || \
	  { echo "make data: $($(1)_NAME) does not match its pinned checksums" >&2; exit 1; }
	rm -rf data/$($(1)_NAME) && mv data/$($(1)_NAME).tmp data/$($(1)_NAME)
endef
$(foreach s,$(SNAPSHOTS),$(eval $(call snapshot_rule,$(s))))

# The same three instruments and days as `spot`, fetched through Coinlake's
# Databento-compatible API (milestone 6). Not part of `make data`: it needs
# the databento package, DATABENTO_API_KEY and the gateway, and for a
# self-signed one REQUESTS_CA_BUNDLE. The pin covers the DBN files too.
COINLAKE_GATEWAY ?= http://127.0.0.1:18443
coinlake_NAME := coinlake-bin-1d-2023-10_2026-09
.PHONY: data-coinlake
data-coinlake: data/$(coinlake_NAME)/SHA256SUMS
data/$(coinlake_NAME)/SHA256SUMS: data/$(coinlake_NAME).sha256 tools/fetch_coinlake.py
	rm -rf data/$(coinlake_NAME).tmp
	python3 -I tools/fetch_coinlake.py --gateway $(COINLAKE_GATEWAY) --dataset BIN.ARCHIVE \
	  --start 2023-10-01 --end 2026-10-01 --out data/$(coinlake_NAME).tmp $(spot_SYMS)
	cmp data/$(coinlake_NAME).tmp/SHA256SUMS data/$(coinlake_NAME).sha256 || \
	  { echo "make data-coinlake: $(coinlake_NAME) does not match its pinned checksums" >&2; exit 1; }
	rm -rf data/$(coinlake_NAME) && mv data/$(coinlake_NAME).tmp data/$(coinlake_NAME)

test: $(TESTS) test-oracle

test-oracle:
	RAYFORCE=$(RAYFORCE) python3 -I test/oracle.py

test-run: | data
	RAYFORCE=$(RAYFORCE) test/determinism.sh trend data/$(spot_NAME)
	RAYFORCE=$(RAYFORCE) test/determinism.sh xsmom data/$(spot12_NAME)

$(TESTS): | data
	$(RAYFORCE) $@ </dev/null

fmt:
	$(FMT) $(RFL)

fmt-check:
	$(FMT) --check $(RFL)

# Small reproducible local snapshot for the GUI and integration tests.
.PHONY: sample-data
sample-data:
	@if test -f data/sample-1d/SHA256SUMS; then \
	  cd data/sample-1d && sha256sum --quiet --check SHA256SUMS; \
	else \
	  python3 -I tools/synth_bars.py --out data/sample-1d --instruments 3 \
	    --period 1d --from 2023-10-01 --days 1096 --seed 1; \
	fi
