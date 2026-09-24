#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
swiftc -swift-version 5 Sources/Model.swift Tests/main.swift -o build/model-tests
build/model-tests
