#!/bin/zsh

# Title         : attempt_account_unlock.zsh
# Description   : This script is to be used in a policy to attempt a local account unlock. The user is prompted for their
#                 FileVault password, and if successful will attempt to reenable the account.
#
#                 System logs are also collected as a logarchive in /var/log/ for additional troubleshooting.
#                   
#                 Requires JamfHelper
#                 
# Authors       : Dan Brodjieski
#               : Bob Gendler
# Date          : 2026-03-04
# Version       : 1.0
# Changelog     : 2026-03-04 - Initial Script

# get the currently logged in user (or passed from Jamf)
if [[ ! -z "$3" ]]; then
    CURRENT_USER=$3
else
    CURRENT_USER=$(/usr/sbin/scutil <<<"show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}')
fi

# Get information necessary to display messages in the current user's context.
USER_ID=$(id -u "$CURRENT_USER")
USER_GUID=$(dscl . -read /Users/"$CURRENT_USER" GeneratedUID | awk '{print $NF}')

# define all the various prompts for jamfHelper
PROMPT_TITLE="Reenable Local User Account"

PROMPT_MESSAGE="Use this utility to attempt to unlock and reenable your local user account.

In our environment, with smartcards being enforced, there are times where an account can get inadvertently locked and disabled. 

This is typically due to an incorrectly typed password during manually triggered Software Updates from Apple.

You will be prompted for your FileVault password, and if it is correct, will attempt to unlock and reenable your local account.
"

# location for icons to use in jamfHelper, if one is not provided, the script will default to the Keychain Access icon
LOGO_PNG="/System/Library/CoreServices/Applications/Keychain Access.app/Contents/Resources/AppIcon.icns"

# path to jamfHelper
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
if [[ ! -x "$jamfHelper" ]]; then
    echo "This script relies on jamfHelper but cannot find it, exiting..."
    exit 1
fi

# Display a branded prompt explaining the password prompt.
PROMPT=$(launchctl asuser "$USER_ID" "$jamfHelper" -windowType utility -icon "$LOGO_PNG" -title "$PROMPT_TITLE" -description "$PROMPT_MESSAGE" -button1 "Next" -button2 "Cancel" -defaultButton 1)
if [[ $PROMPT == "2" ]]; then
    echo "User pressed Cancel, exiting ..."
    exit 0
fi

PWPOLICY_STATUS=$(pwpolicy authentication-allowed -u "${CURRENT_USER}")
FAILED_LOGIN_COUNT=$(dscl . readpl /Users/$CURRENT_USER accountPolicyData failedLoginCount)
echo "----INITIAL ACCOUNT STATUS----"

echo "ACCOUNT STATUS: $PWPOLICY_STATUS - $FAILED_LOGIN_COUNT"

if [[ $PWPOLICY_STATUS == *"Policy allows user"* ]]; then
    launchctl asuser "$USER_ID" "$jamfHelper" -windowType utility -icon "$LOGO_PNG" -title "Account is not disabled." -description "User account $CURRENT_USER is not disabled and does not need any further action." -button1 "Ok" -defaultButton 1
    exit 0
fi

userpassword=$(osascript -e 'set theResultReturned to display dialog "Please verify by typing your FileVault password. This password is also typically your Keychain Password which was defined when you first set up your system." default answer "" with icon stop buttons {"Cancel", "Continue"} default button "Continue" with hidden answer' -e 'set theTextReturned to the text returned of theResultReturned' -e "return theTextReturned")

if [ -z "$userpassword" ]; then
    echo "Password entry cancelled"
    exit 1
fi

userpasswordverify=$(osascript -e 'set theResultReturned to display dialog "Please verify by re-typing your password." default answer "" with icon stop buttons {"Cancel", "Continue"} default button "Continue" with hidden answer' -e 'set theTextReturned to the text returned of theResultReturned' -e "return theTextReturned")

loopexit=""

while [ "${loopexit}" != "true" ]; do
    if [ "${userpassword}" != "${userpasswordverify}" ]; then
        /Library/Application\ Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper -windowType utility -title "Passwords Mismatch" -description "The passwords you typed did not match." -button1 "Ok" -defaultButton 1 -icon /System/Library/CoreServices/Problem\ Reporter.app/Contents/Resources/ProblemReporter.icns
        userpassword=$(osascript -e 'set theResultReturned to display dialog "Please verify by typing your FileVault password. This password is also typically your Keychain Password which was defined when you first set up your system." default answer "" with icon stop buttons {"Cancel", "Continue"} default button "Continue" with hidden answer' -e 'set theTextReturned to the text returned of theResultReturned' -e "return theTextReturned")
        userpasswordverify=$(osascript -e 'set theResultReturned to display dialog "Please verify by re-typing your password." default answer "" with icon stop buttons {"Cancel", "Continue"} default button "Continue" with hidden answer' -e 'set theTextReturned to the text returned of theResultReturned' -e "return theTextReturned")
    else
        loopexit="true"
    fi
done

# Check password against SecureToken unlock
diskutil apfs unlockVolume / -verify -user "$USER_GUID" -passphrase "$userpassword"

# Check exit status
if [ $? -eq 0 ]; then
    /Library/Application\ Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper -windowType utility -title "Password Successful" -description "${CURRENT_USER} password was successfully verified. The local account should be reenabled. Use this password during future Software Updates." -button1 "Ok" -defaultButton 1 -icon "$LOGO_PNG"
    echo "Passphrase verification successful, setting failedLoginCount to 0"
    dscl . createpl /Users/$CURRENT_USER accountPolicyData failedLoginCount 0
    echo "----ACCOUNT STATUS----"
    pwpolicy authentication-allowed -u "${CURRENT_USER}"
    echo "$(dscl . readpl /Users/$CURRENT_USER accountPolicyData failedLoginCount)"
    /usr/bin/log collect --output "/var/log/$(date +%s).logarchive"
    echo "Collected additional logs for troubleshooting in /var/log/$(date +%s).logarchive"
    exit 0
else
    echo "Passphrase verification failed"
    /usr/bin/log collect --output "/var/log/$(date +%s).logarchive"
    echo "Collected additional logs for troubleshooting in /var/log/$(date +%s).logarchive"
    /Library/Application\ Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper -windowType utility -title "Password Incorrect" -description "The password entered for ${CURRENT_USER} does not appear to be the correct FileVault password. Reach out to your System Administrator for additional help." -button1 "Ok" -defaultButton 1 -icon "$LOGO_PNG"
    exit 1
fi
