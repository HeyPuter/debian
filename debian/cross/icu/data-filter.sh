#!/bin/sh
# ICU's data for the image: the list of items its build packs into
# libicudata (data/Makefile.in's icudata.lst, from Debian's prebuilt
# icudt*.dat), less every locale's own resources but the root's and
# English's. The session runs in C.UTF-8, which ICU takes as en_US_POSIX,
# and Qt formats dates, numbers and names from its own CLDR data, so the
# other locales' names, currencies, units, time zone names, spell-outs and
# collation tailorings are not read. Collation's root order (ucadata), the
# break iterators and their dictionaries, the converters, normalization,
# properties and time zone rules all stay, so text in any script sorts,
# breaks and converts as before.
#
#   data-filter.sh LIST    (rewrites LIST)
L=$1
awk '{ n = $0; sub(/^(lang|curr|unit|region|zone|rbnf|coll)\//, "", n) }
     n ~ /^[a-z][a-z][a-z]?(_[A-Za-z0-9]*)*\.res$/ && n !~ /^(root|en|en_.*|pool|res_index)\.res$/ { next }
     { print }' "$L" > "$L.kept" && mv "$L.kept" "$L"
