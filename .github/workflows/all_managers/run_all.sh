#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

$SCRIPT_DIR/resukisu.sh
$SCRIPT_DIR/sukisu.sh
$SCRIPT_DIR/ksunext.sh
$SCRIPT_DIR/ksu.sh
$SCRIPT_DIR/kowsu.sh
