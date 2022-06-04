#!/bin/sh

export TEAM_ID=5NN7GUYB6T
# export APNS_KEY_FILE=""
# export APNS_KEY_ID=""
export TOPIC=chat.simplex.app
# export DEVICE_TOKEN=
export APNS_HOST_NAME=api.sandbox.push.apple.com

export JWT_ISSUE_TIME=$(date +%s)
export JWT_HEADER=$(printf '{"alg":"ES256","kid":"%s"}' "${APNS_KEY_ID}" | openssl base64 -e -A | tr -- '+/' '-_' | tr -d =)
export JWT_CLAIMS=$(printf '{"iss":"%s","iat":%d}' "${TEAM_ID}" "${JWT_ISSUE_TIME}" | openssl base64 -e -A | tr -- '+/' '-_' | tr -d =)
export JWT_HEADER_CLAIMS="${JWT_HEADER}.${JWT_CLAIMS}"

export JWT_SIGNED_HEADER_CLAIMS=$(printf "${JWT_HEADER_CLAIMS}" | openssl dgst -binary -sha256 -sign "${APNS_KEY_FILE}" | openssl base64 -e -A | tr -- '+/' '-_' | tr -d =)
export AUTHENTICATION_TOKEN="${JWT_HEADER}.${JWT_CLAIMS}.${JWT_SIGNED_HEADER_CLAIMS}"

# simple alert
# curl -v --header "apns-topic: $TOPIC" --header "apns-push-type: alert" --header "authorization: bearer $AUTHENTICATION_TOKEN" --data '{"aps":{"alert":"you have a new message"},"data":{"test":"123"}}' --http2 https://${APNS_HOST_NAME}/3/device/${DEVICE_TOKEN}

# background notification
# curl -v --header "apns-topic: $TOPIC" --header "apns-push-type: background" --header "apns-priority: 5" --header "authorization: bearer $AUTHENTICATION_TOKEN" --data '{"aps":{"content-available":1}}' --http2 https://${APNS_HOST_NAME}/3/device/${DEVICE_TOKEN}

# mutable-content notification
# NTF_CAT_CHECK_MESSAGE category will not show alert if the app is in foreground
curl -v --header "apns-topic: $TOPIC" --header "apns-push-type: alert" --header "authorization: bearer $AUTHENTICATION_TOKEN" --data '{"aps":{"category": "NTF_CAT_CHECK_MESSAGE__SECRET", "mutable-content": 1, "alert":"received encrypted message"}, "data": {"test":"123"}}' --http2 https://${APNS_HOST_NAME}/3/device/${DEVICE_TOKEN}
