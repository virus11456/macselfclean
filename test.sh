#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/macsweep-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
for TEST_NAME in SafetyTests WorkerTests ApplicationTests MetadataTests ElectronTests InstallerTests TreeTests InspectionWorkerTests LocationStoreTests PartialUninstallTests UninstallReportTests; do
    swiftc -module-cache-path "${TMPDIR:-/tmp}/macsweep-test-module-cache" -swift-version 6 Sources/UninstallReport.swift Sources/AppLocationStore.swift Sources/AppInspectionWorker.swift Sources/FileTreeSnapshot.swift Sources/InstallerSearch.swift Sources/ElectronCacheRules.swift Sources/Leftovers.swift Sources/BackupMetadata.swift Sources/Cleaner.swift Sources/ScannerWorker.swift Sources/Applications.swift "Tests/$TEST_NAME.swift" -o "$TEST_DIR/$TEST_NAME"
    "$TEST_DIR/$TEST_NAME"
done
