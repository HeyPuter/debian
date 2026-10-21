# The sources gex-debian builds against, pinned. `make` fetches gex at its
# commit into $(OUT)/src (a shallow fetch of that one commit) unless local.mk
# names a checkout of your own (GEX_DIR).

# gex: gexc, the gexcc toolchain's sources, the item-3 providers' builders,
# the GL marshallers and the page.
GEX_REPO := https://github.com/MercuryWorkshop/gex.git
GEX_COMMIT := 7d802972493c387a6f38e09721882b1320f8fc2a
