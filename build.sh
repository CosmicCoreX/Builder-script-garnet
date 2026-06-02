#!/bin/bash

#
# Script For Building Android Custom ROM
#
# Copyright (C) 2026 pure-soul-kk <krishnakripa34567@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
clear='\033[0m'

set -o pipefail
set -o allexport
source .env
set +o allexport

### ================= CONFIG =================

ROM_NAME="Axion AOSP"
DEVICE="garnet"
BUILD_TYPE="user"
USER="@IamZeus14"

COMMON_IMAGES=("recovery.img")
OUT_DIR="out/target/product/${DEVICE}"
LOG="build.log"
OTA_JSON_FILE="${OUT_DIR}/GMS/${DEVICE}.json"
ROM_ZIP="${OUT_DIR}/axion*.zip"

### ============================================== ###

### ============ MAIN FUNCTIONS ================== ###

function clean() {
  rm -rf .repo/local_manifests
  rm -rf {device,kernel,hardware,vendor}/xiaomi
  rm -rf vendor/lineage-priv/keys
}

function sync_sources() {
  repo init -u https://github.com/AxionAOSP/android.git -b lineage-23.2 --git-lfs --depth=1
  git clone https://github.com/iamzeus14/Builder-script -b main .repo/local_manifests

  if [ -f /opt/crave/resync.sh ]; then
    /opt/crave/resync.sh
  else
    repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
  fi

  git clone https://${GH_TOKEN}@github.com/iamzeus14/priv-keys -b 16 vendor/lineage-priv/keys
}

function setup_env() {
  export BUILD_USERNAME=iamZeus14
  export BUILD_HOSTNAME=crave

  . build/envsetup.sh
  axion "$DEVICE" "$BUILD_TYPE" gms
  mka installclean
}

function build_rom() {
  touch "$LOG"
  ax -b 2>&1 | tee "$LOG" &
  BUILD_PID=$!

  wait "$BUILD_PID"
  return $?
}

### ===========  HELPER FUNCTIONS ================ ###

function format_time() {
  local SECS=$1
  local h=$(( SECS / 3600 ))
  local m=$(( (SECS % 3600) / 60 ))
  local s=$(( SECS % 60 ))

  if [ "$h" -gt 0 ]; then
    echo "${h} hr ${m} min ${s} sec"
  else
    echo "${m} min ${s} sec"
  fi
}

function tg_post_msg() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d disable_web_page_preview="true" \
    -d text="$1" > /dev/null
}

GOFILE_RETRY_MAX=6

function gofile_upload() {
  local FILE="$1"
  local FILENAME
  FILENAME=$(basename "$FILE")

  if [ ! -f "$FILE" ]; then
    echo "⚠️ Skipped (not found): $FILENAME" >&2
    return 1
  fi

  for SERVER in $(printf "%s\n" "${GOFILE_SERVERS[@]}" | shuf); do
    local ATTEMPT=0
    while [ "$ATTEMPT" -lt "$GOFILE_RETRY_MAX" ]; do
      ATTEMPT=$(( ATTEMPT + 1 ))
      echo "Trying server $SERVER (attempt $ATTEMPT)..." >&2

      RESPONSE=$(curl -4 --http1.1 -sf \
        -F "file=@${FILE}" \
        "https://${SERVER}.gofile.io/contents/uploadFile")

      LINK=$(echo "$RESPONSE" | jq -r '.data.downloadPage // empty')

      if [ -n "$LINK" ]; then
        echo "$LINK"
        return 0
      fi

      echo "Server $SERVER attempt $ATTEMPT failed" >&2
      sleep 2
    done
  done

  echo "❌ All GoFile servers/retries exhausted for: $FILENAME" >&2
  return 1
}

### =============== MAIN =====================

clean
sync_sources
setup_env

### =============== BUILD ====================
BUILD_START=$(date +%s)

build_rom
STATUS=$?

BUILD_END=$(date +%s)
TIME=$(( BUILD_END - BUILD_START ))
TIME_FMT=$(format_time "$TIME")

### =============== RESULT ====================

if [ "$STATUS" -eq 0 ]; then

  mapfile -t GOFILE_SERVERS < <(curl -s "https://api.gofile.io/servers" | jq -r '.data.servers[].name')

  if [ "${#GOFILE_SERVERS[@]}" -eq 0 ]; then
    tg_post_msg "⚠️ Could not resolve any GoFile server. Uploads skipped."
    exit 1
  fi

  mapfile -t ROM_ZIPS < <(compgen -G "$ROM_ZIP" 2>/dev/null)
  if [ "${#ROM_ZIPS[@]}" -eq 0 ]; then
    tg_post_msg "⚠️ Build reported success but no ROM zip found at \`${ROM_ZIP}\`. Check the build output."
    exit 1
  fi

  UPLOAD_MSG=""
  IMG_MSG=""
  JSON_MSG=""

  ### ======== UPLOAD ZIP(S) ========
  for ZIP in "${ROM_ZIPS[@]}"; do
    [ -f "$ZIP" ] || continue
    FILENAME=$(basename "$ZIP")
    LINK=$(gofile_upload "$ZIP")
    if [ -n "$LINK" ]; then
      UPLOAD_MSG="${UPLOAD_MSG}📦 [${FILENAME}](${LINK})\n"
    else
      UPLOAD_MSG="${UPLOAD_MSG}⚠️ Upload failed: \`${FILENAME}\`\n"
    fi
  done

  ### ======== UPLOAD RECOVERY IMAGES ========
  for IMG in "${COMMON_IMAGES[@]}"; do
    FILEPATH="${OUT_DIR}/${IMG}"
    LINK=$(gofile_upload "$FILEPATH")
    if [ -n "$LINK" ]; then
      IMG_MSG="${IMG_MSG} [${IMG}](${LINK})\n"
    else
      IMG_MSG="${IMG_MSG}⚠️ Upload failed: \`${IMG}\`\n"
    fi
  done

  ### ======== UPLOAD DEVICE JSON ========
  JSON_LINK=$(gofile_upload "$OTA_JSON_FILE")
  if [ -n "$JSON_LINK" ]; then
    JSON_MSG=" [${DEVICE}.json](${JSON_LINK})\n"
  else
    JSON_MSG="⚠️ Upload failed: \`${DEVICE}.json\`\n"
  fi

  ### ======== FINAL UPLOAD MSG ========
  FINAL_MSG="
🎉 *${ROM_NAME} | ${DEVICE} — Downloads*
━━━━━━━━━━━━━━━━━━

$(echo -e "$UPLOAD_MSG")"

  FINAL_MSG="${FINAL_MSG}

🔧 *Recovery Images*
$(echo -e "$IMG_MSG")

📋 *Device JSON*
$(echo -e "$JSON_MSG")

👤 By: \`${USER}\`
🕛 Build Time: ${TIME_FMT}"

  tg_post_msg "$FINAL_MSG"

fi
