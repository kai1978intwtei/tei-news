#!/bin/sh
# Vercel build script for TEi-Salesys prototype deployment
# Copies the prototype + assets into _site/, which Vercel serves as the public root.
# The news index.html at repo root is intentionally excluded so / serves the prototype.
set -e

rm -rf _site
mkdir -p _site

# Prototype becomes the index page
cp teisale-prototype.html _site/index.html

# Assets referenced by the prototype
for f in favicon.svg logo.png logo.svg tei-50th.png; do
  [ -f "$f" ] && cp -f "$f" _site/
done

# Other public files
[ -d migrations ] && cp -rf migrations _site/
[ -f TEISALE-CHANGESET.md ] && cp -f TEISALE-CHANGESET.md _site/
[ -f carbon-plate-cae-simulator.html ] && cp -f carbon-plate-cae-simulator.html _site/

echo "Build output:"
ls -la _site/
