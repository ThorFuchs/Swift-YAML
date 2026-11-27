#!/bin/sh
set -eu
version=${1:?Pass Swift-JSON version 1.9.0 or 1.10.0}
case "$version" in
  1.9.0) revision=f2a0d12da7028edfbcb0cb307f19a921a3a12d03 ;;
  1.10.0) revision=564ca8ce5ea057edc847666c4223da20084fc59c ;;
  *) echo "Unsupported qualification version: $version" >&2; exit 1 ;;
esac
swift package resolve
swift package resolve swift-json --version "$version"
grep -F "\"version\" : \"$version\"" Package.resolved
grep -F "\"revision\" : \"$revision\"" Package.resolved
test "$(git -C .build/checkouts/Swift-JSON rev-parse HEAD)" = "$revision"
swift test --force-resolved-versions
swift test -c release --force-resolved-versions
