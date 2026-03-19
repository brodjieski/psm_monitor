#!/bin/zsh

# Title       : ea_psm_last_user.zsh
# Description : Jamf Pro Extension Attribute — reports the current psm failed-unlock-attempt
#               and backoff values for the last logged-in user.
# Author      : Dan Brodjieski, NASA - CSET
# Date        : 2026-03-18
# Version     : 1.0
# Output      : <result>FUA[console,other] BO[console,other]</result>
#               e.g. <result>FUA[0,0] BO[0,0]</result>

LOGINWINDOW_PLIST="/Library/Preferences/com.apple.loginwindow.plist"

result() { echo "<result>$1</result>"; exit 0; }

# --- Resolve the last logged-in username ---
username=$(defaults read "$LOGINWINDOW_PLIST" lastUserName 2>/dev/null)
if [[ -z "$username" ]]; then
    result "ERROR: lastUserName not found in loginwindow.plist"
fi

# --- Resolve the user's UUID via dscl (matches KEK UUID in psm list) ---
uuid=$(dscl . -read "/Users/${username}" GeneratedUID 2>/dev/null | awk '{print $2}')
if [[ -z "$uuid" ]]; then
    result "ERROR: Could not resolve UUID for user '${username}'"
fi

# --- Parse psm list and find the block matching this UUID ---
strip_ansi() { sed 's/\x1b\[[0-9;]*[mGKHF]//g'; }

psm_output=$(psm list 2>&1 | strip_ansi)

in_block=false
current_uuid=""
fc="" fo="" bc="" bo=""
found=false

while IFS= read -r line; do
    if [[ "$line" =~ ^-=-=-=-=-=-=- ]]; then
        # Check if the block we just finished is the one we want
        if [[ "$in_block" == true && "$current_uuid" == "$uuid" && -n "$fc" ]]; then
            found=true
            break
        fi
        in_block=true
        current_uuid=""
        fc="" fo="" bc="" bo=""
        continue
    fi

    [[ "$in_block" == false ]] && continue

    if [[ "$line" =~ "uuid: " ]]; then
        current_uuid=$(echo "$line" | sed -E 's/.*uuid: ([A-Fa-f0-9-]+).*/\1/' | tr 'a-f' 'A-F')
    fi

    if [[ "$line" =~ "failed-unlock-attempts\[console,other\]" ]]; then
        fc=$(echo "$line" | sed -E 's/.*failed-unlock-attempts\[console,other\]: ([0-9]+),.*/\1/')
        fo=$(echo "$line" | sed -E 's/.*failed-unlock-attempts\[console,other\]: [0-9]+, ([0-9]+);.*/\1/')
        bc=$(echo "$line" | sed -E 's/.*backoff\[console,other\]: ([0-9]+),.*/\1/')
        bo=$(echo "$line" | sed -E 's/.*backoff\[console,other\]: [0-9]+, ([0-9]+);.*/\1/')
    fi

done <<< "$psm_output"

# Catch the final block if the loop ended without hitting another divider
if [[ "$found" == false && "$current_uuid" == "$uuid" && -n "$fc" ]]; then
    found=true
fi

if [[ "$found" == false ]]; then
    result "ERROR: No psm entry found for user '${username}' (${uuid})"
fi

if [[ "$fc" == "0" && "$fo" == "0" && "$bc" == "0" && "$bo" == "0" ]]; then
    result "Account OK"
fi

result "FUA[${fc},${fo}] BO[${bc},${bo}]"
