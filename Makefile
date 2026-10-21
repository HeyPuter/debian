# gex-debian: Debian root filesystems for gex, and the demos built on them.
#
#   make debian        rootfs/build-debian.sh: a minimal Debian arm64 rootfs,
#                      $(OUT)/rootfs/debian.tar (Debian's own binaries)
#   make graphics      rootfs/build-session-tree.sh then
#                      rootfs/build-graphics-rootfs.sh: $(OUT)/rootfs/graphics.tar
#   make native        rootfs/build-native-debian.sh $(TIERS): Debian's sources
#                      built with gexcc into wasm32 .debs, and
#                      $(OUT)/rootfs/native-debian.tar.zst (GEXCC_PREFIX)
#   make desktop       desktop/build-rootfs.sh: the desktop demo's base rootfs
#                      and launcher packages, into gex's web/public (PUB)
#
# Settings: pins.mk (the gex commit) and local.mk (yours, untracked;
# local.mk.example): OUT, GEX_DIR, GEXCC_PREFIX, GEXCC_DEB, JOBS, PUB.
# Run the big builds inside a resource scope:
#   systemd-run --user --scope -p TasksMax=4096 -p MemoryMax=32G nice -n 19 make native

SHELL := /bin/bash
.DEFAULT_GOAL := help
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
include $(ROOT)/pins.mk
-include $(ROOT)/local.mk

OUT ?= $(ROOT)/out
OUT := $(abspath $(OUT))
SRC := $(OUT)/src
JOBS ?= $(shell nproc)
TIERS ?= tier1

ifeq ($(GEX_DIR),)
GEX_DIR := $(SRC)/gex
GEX_DEP := $(SRC)/gex.$(GEX_COMMIT).fetched
$(GEX_DEP):
	$(ROOT)/mk/fetch-pin.sh $(GEX_REPO) $(GEX_COMMIT) $(SRC)/gex
	rm -f $(SRC)/gex.*.fetched; touch $@
else
GEX_DIR := $(abspath $(GEX_DIR))
GEX_DEP :=
endif
PUB ?= $(GEX_DIR)/web/public

ENV := GEX_SRC=$(GEX_DIR) OUT_DIR=$(OUT) JOBS=$(JOBS) \
  $(if $(GEXCC_PREFIX),GEXCC_PREFIX=$(GEXCC_PREFIX)) $(if $(GEXCC_DEB),GEXCC_DEB=$(GEXCC_DEB))

help:
	@sed -n '2,/^$$/p' $(ROOT)/Makefile | sed 's/^# \{0,1\}//'

debian: $(GEX_DEP)
	$(ENV) $(ROOT)/rootfs/build-debian.sh $(OUT)/rootfs/debian.tar $(OUT)/work/debian
graphics: $(GEX_DEP)
	$(ENV) $(ROOT)/rootfs/build-session-tree.sh $(OUT)/work/session
	$(ENV) $(ROOT)/rootfs/build-graphics-rootfs.sh $(OUT)/rootfs/graphics.tar $(OUT)/work/session/root
native: $(GEX_DEP)
	$(ENV) OUT=$(OUT)/rootfs $(ROOT)/rootfs/build-native-debian.sh $(TIERS)
desktop: $(GEX_DEP)
	$(ENV) PUB=$(PUB) $(ROOT)/desktop/build-rootfs.sh

.PHONY: help debian graphics native desktop
