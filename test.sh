#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
node --test Tests/renderer.test.mjs
mkdir -p .build
swiftc -enable-bare-slash-regex Shared/MarkdownFile.swift Shared/PreviewTransfer.swift \
  App/WorkspaceIndex.swift Tests/CoreChecks.swift -o .build/CoreChecks
.build/CoreChecks
swiftc -enable-bare-slash-regex App/SourceEditor.swift App/Library.swift App/WorkspaceIndex.swift \
  Shared/*.swift Tests/AppearanceChecks.swift -o .build/AppearanceChecks
.build/AppearanceChecks
