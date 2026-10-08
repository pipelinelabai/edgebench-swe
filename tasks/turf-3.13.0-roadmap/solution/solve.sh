#!/bin/bash
# Apply the v_old -> v_new patch to /app (which is a git repo at v_old checkout).
set -e
cd /app
git apply /solution/changes.patch

# After the patch is applied, the new @turf/great-circle and @turf/line-chunk
# packages exist under /app/packages/. Wire them into /deps/node_modules/@turf/*
# so they resolve from any test file's `require('@turf/great-circle')`.
mkdir -p /deps/node_modules/@turf
for pkg in /app/packages/turf-*; do
    name=$(node -e "console.log(require('$pkg/package.json').name)" 2>/dev/null || true)
    if [ -n "$name" ]; then
        link="/deps/node_modules/$name"
        rm -f "$link"
        ln -sfn "$pkg" "$link"
    fi
done
