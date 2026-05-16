#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-/private/tmp/QuizLoopDerivedData}"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphonesimulator/QuizLoop.app"
OUTPUT_DIR="${ROOT_DIR}/build/appetize"
OUTPUT_ZIP="${OUTPUT_DIR}/QuizLoop-Appetize.zip"

cd "${ROOT_DIR}"

xcodebuild \
  -workspace QuizLoop.xcworkspace \
  -scheme QuizLoop \
  -sdk iphonesimulator \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Missing simulator app at ${APP_PATH}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_ZIP}"
ditto -c -k --keepParent "${APP_PATH}" "${OUTPUT_ZIP}"

echo "${OUTPUT_ZIP}"
