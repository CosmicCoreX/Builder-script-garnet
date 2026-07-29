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

# IST override for all date calls in this script
export TZ="Asia/Kolkata"

### ================= CONFIG =================

ROM_NAME="Lunaris"
DEVICE="garnet"
BUILD_TYPE="user"
USER="@IamZeus14"

COMMON_IMAGES=("recovery.img")
OUT_DIR="out/target/product/${DEVICE}"
LOG="build.log"
OTA_JSON_FILE="${OUT_DIR}/GMS/${DEVICE}.json"
ROM_ZIP="${OUT_DIR}/Lunaris*.zip"

### ============================================== ###

### ============ MAIN FUNCTIONS ================== ###

function clean() {
  rm -rf .repo/local_manifests
  rm -rf {device,kernel,hardware,vendor}/xiaomi
  rm -rf hardware/dolby
  rm -rf vendor/lineage-priv/keys
}

function sync_sources() {
  repo init -u https://github.com/Lunaris-AOSP/android -b 16.2 --git-lfs --depth=1
  git clone https://github.com/iamzeus14/Builder-script -b lunaris .repo/local_manifests

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
  lunch lineage_"$DEVICE"-bp4a-"$BUILD_TYPE"
  mka installclean
}

function build_rom() {
  touch "$LOG"
  m bacon 2>&1 | tee "$LOG" &
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

function tg_edit_msg() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/editMessageText" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$1" \
    -d parse_mode="Markdown" \
    -d disable_web_page_preview="true" \
    -d text="$2" > /dev/null
}

function tg_send_file() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
    -F chat_id="$CHAT_ID" \
    -F document=@"$1" \
    -F caption="$2" > /dev/null
}

function tg_get_msg_id() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d disable_web_page_preview="true" \
    -d text="$1" | jq -r '.result.message_id'
}

STICKER_ID="CAACAgIAAxkBAAFHPGBp3vv2alKfVBQ4v7AaHPF97GMSKAACGTEAArx_wUuGnBCRzvYJbTsE"

function tg_sticker() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendSticker" \
    -d sticker="$STICKER_ID" \
    -d chat_id="$CHAT_ID" > /dev/null
}

function get_stats() {
  read -r _ u1 n1 s1 i1 w1 irq1 sirq1 st1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 irq2 sirq2 st2 _ < /proc/stat

  idle1=$((i1 + w1))
  idle2=$((i2 + w2))

  total1=$((u1 + n1 + s1 + i1 + w1 + irq1 + sirq1 + st1))
  total2=$((u2 + n2 + s2 + i2 + w2 + irq2 + sirq2 + st2))

  diff_idle=$((idle2 - idle1))
  diff_total=$((total2 - total1))

  local CPU=0
  if [ "$diff_total" -gt 0 ]; then
    CPU=$(( 100 * (diff_total - diff_idle) / diff_total ))
  fi

  MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
  MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
  LOAD=$(cut -d' ' -f1 /proc/loadavg)
  echo "$CPU|$MEM_USED|$MEM_TOTAL|$LOAD"
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

function tg_send_with_button() {
  local TEXT="$1"

  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d disable_web_page_preview="true" \
    -d text="$TEXT" \
    -d reply_markup='{
      "inline_keyboard": [[
        {"text": "🔄 Refresh Info", "callback_data": "refresh"}
      ]]
    }' | jq -r '.result.message_id'
}

function tg_edit_with_button() {
  local MSG_ID="$1"
  local TEXT="$2"

  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/editMessageText" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$MSG_ID" \
    -d parse_mode="Markdown" \
    -d disable_web_page_preview="true" \
    -d text="$TEXT" \
    -d reply_markup='{
      "inline_keyboard": [[
        {"text": "🔄 Refresh Info", "callback_data": "refresh"}
      ]]
    }' > /dev/null
}

function listen_refresh() {
  local OFFSET=0

  while true; do
    UPDATES=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${OFFSET}")
    COUNT=$(echo "$UPDATES" | jq '.result | length')

    if [ "$COUNT" -gt 0 ]; then
      for ((i=0; i<COUNT; i++)); do
        UPDATE=$(echo "$UPDATES" | jq -c ".result[$i]")

        UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
        OFFSET=$((UPDATE_ID + 1))

        CALLBACK=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
        MSG_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')

        if [ "$CALLBACK" = "refresh" ]; then
          CALLBACK_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')

          curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/answerCallbackQuery" \
               -d callback_query_id="$CALLBACK_ID" > /dev/null

          STATS=$(get_stats)
          CPU=$(echo "$STATS" | cut -d'|' -f1)
          MEM_USED=$(echo "$STATS" | cut -d'|' -f2)
          MEM_TOTAL=$(echo "$STATS" | cut -d'|' -f3)
          LOAD=$(echo "$STATS" | cut -d'|' -f4)

          ELAPSED=$(( $(date +%s) - BUILD_START ))
          CONSOLE=$(grep -v '^\s*$' "$LOG" 2>/dev/null | tail -n1 | cut -c1-110)
          NOW_LOCAL=$(date +"%H:%M:%S")

          tg_edit_with_button "$MSG_ID" "
⚙️ *Building ${ROM_NAME}*

📱 Device: \`${DEVICE}\`
🏙️ *Build Type*: \`${BUILD_TYPE}\`

*Server Stats*
💻 CPU: \`${CPU}%\`
💾 RAM: \`${MEM_USED}MB / ${MEM_TOTAL}MB\`
⚡ Load: \`${LOAD}\`

🕛 Elapsed: $(format_time "$ELAPSED")
🔥 Status: Compiling...
📟 Console: \`${CONSOLE}\`

🔄 Last Refreshed: \`${NOW_LOCAL}\`"
        fi
      done
    fi

    sleep 2
  done
}

### =============== MAIN =====================

clean
sync_sources
setup_env

### =============== START MSG ================
BUILD_START=$(date +%s)
NOW=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
tg_sticker

tg_post_msg "
🤖 *${ROM_NAME} ${POS_VERSION}* Build Triggered for

📱 *Device*: \`${DEVICE}\`
🏙️ *Build Type*: \`${BUILD_TYPE}\`
⌛ *Time*: \`${NOW}\`"

PROGRESS_MSG_ID=$(tg_send_with_button "🚀 Initializing build...
Tap 🔄 Refresh Info to refresh the stats!")

listen_refresh &
LISTENER_PID=$!

### =============== BUILD ====================
build_rom
STATUS=$?


kill "$LISTENER_PID" 2>/dev/null
wait "$LISTENER_PID" 2>/dev/null

BUILD_END=$(date +%s)
TIME=$(( BUILD_END - BUILD_START ))
TIME_FMT=$(format_time "$TIME")

### =============== RESULT ====================

if [ "$STATUS" -eq 0 ]; then

  # Resolve GoFile server list once, reuse for all uploads
  mapfile -t GOFILE_SERVERS < <(curl -s "https://api.gofile.io/servers" | jq -r '.data.servers[].name')

  if [ "${#GOFILE_SERVERS[@]}" -eq 0 ]; then
    tg_post_msg "⚠️ Could not resolve any GoFile server. Uploads skipped."
  fi

  # FIX #7: Resolve ROM zip glob safely; abort early if no zip found
  mapfile -t ROM_ZIPS < <(compgen -G "$ROM_ZIP" 2>/dev/null)
  if [ "${#ROM_ZIPS[@]}" -eq 0 ]; then
    tg_post_msg "⚠️ Build reported success but no ROM zip found at \`${ROM_ZIP}\`. Check the build output."
    exit 1
  fi

  tg_edit_msg "$PROGRESS_MSG_ID" "
⚙️ *Building ${ROM_NAME}*

📱 Device: \`${DEVICE}\`
🔥 Status: ✅ Success
🕛 Time: ${TIME_FMT}
📦 Uploading build..."

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
  if [ "$IS_ONEPLUS" = true ]; then
    IMAGES_TO_UPLOAD=("${ONEPLUS_IMAGES[@]}")
  else
    IMAGES_TO_UPLOAD=("${COMMON_IMAGES[@]}")
  fi

  for IMG in "${IMAGES_TO_UPLOAD[@]}"; do
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

  if [ -n "$IMG_MSG" ]; then
    FINAL_MSG="${FINAL_MSG}

🔧 *Recovery Images*
$(echo -e "$IMG_MSG")"
  fi

  FINAL_MSG="${FINAL_MSG}
  
📋 *Device JSON*
$(echo -e "$JSON_MSG")

👤 By: \`${USER}\`
🕛 Build Time: ${TIME_FMT}"

  tg_post_msg "$FINAL_MSG"

else

  tg_edit_msg "$PROGRESS_MSG_ID" "
⚙️ *Building ${ROM_NAME}*

📱 Device: \`${DEVICE}\`
🔥 Status: ❌ Failed
🕛 Time: ${TIME_FMT}"

  if [ -f "out/error.log" ]; then
    tg_send_file "out/error.log" "📜 Build Error Log — ${DEVICE}"
  else
    tail -n 120 "$LOG" > error_tail.log
    tg_send_file "error_tail.log" "📜 Last 120 lines — ${DEVICE} (no out/error.log found)"
    rm -f error_tail.log
  fi

fi
