#!/bin/sh
# Writes the output file map swiftc needs for incremental builds: where each
# source file's object and dependency records go. Usage:
#   output-file-map.sh <object-dir> <source files...> > map.json
dir=$1
shift
printf '{\n  "": { "swift-dependencies": "%s/module.swiftdeps" }' "$dir"
for f in "$@"; do
  name=$(printf '%s' "$f" | tr '/' '_' | sed 's/\.swift$//')
  printf ',\n  "%s": { "object": "%s/%s.o", "swift-dependencies": "%s/%s.swiftdeps" }' "$f" "$dir" "$name" "$dir" "$name"
done
printf '\n}\n'
