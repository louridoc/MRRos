#!/usr/bin/env bash
# Scaffold a local SwiftPM package under ios/Packages with a swift-testing test target.
# Usage: tools/new-module.sh <Name> [Dep1,Dep2,...]
set -euo pipefail

NAME="${1:?package name required}"
DEPS="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/ios/Packages/$NAME"

if [[ -e "$PKG" ]]; then
  echo "error: $PKG already exists" >&2
  exit 1
fi

mkdir -p "$PKG/Sources/$NAME" "$PKG/Tests/${NAME}Tests"

dep_decls=""
dep_refs=""
for d in ${DEPS//,/ }; do
  dep_decls+="        .package(path: \"../$d\"),
"
  dep_refs+="                .product(name: \"$d\", package: \"$d\"),
"
done

cat > "$PKG/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "$NAME",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "$NAME", targets: ["$NAME"]),
    ],
    dependencies: [
${dep_decls}    ],
    targets: [
        .target(
            name: "$NAME",
            dependencies: [
${dep_refs}            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "${NAME}Tests",
            dependencies: ["$NAME"]
        ),
    ]
)
EOF

cat > "$PKG/Sources/$NAME/$NAME.swift" <<EOF
import os

/// Package-wide logger. Category = package name (see CONTRIBUTING.md).
let log = Logger(subsystem: "io.github.louridoc.mrros", category: "$NAME")

public enum ${NAME}Info {
    public static let name = "$NAME"
}
EOF

cat > "$PKG/Tests/${NAME}Tests/${NAME}Tests.swift" <<EOF
import Testing
@testable import $NAME

@Suite struct ${NAME}Tests {
    @Test func packageLinks() {
        #expect(${NAME}Info.name == "$NAME")
    }
}
EOF

echo "created ios/Packages/$NAME (deps: ${DEPS:-none})"
echo "next: add it to ios/project.yml 'packages:' and to CONTRIBUTING.md's layout if it is a new layer"
