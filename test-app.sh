#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
swiftc -swift-version 5 -D TESTING Sources/Model.swift Sources/Timeline.swift Sources/PlatformInput.swift Sources/App.swift Tests/AppTests.swift Tests/LiveTests.swift -o build/app-tests -framework AppKit -framework Carbon -framework CoreGraphics
if test_output=$(build/app-tests "$@"); then
    result_code=0
else
    result_code=$?
fi
printf '%s\n' "$test_output"
(( result_code == 0 )) || exit "$result_code"
[[ "$test_output" == *"PASS:"* ]] || { print -u2 "FAIL: GUI test runner did not complete; run from a logged-in macOS GUI session."; exit 1; }
