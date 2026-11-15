#!/bin/sh
# Regression test: concurrent OpenID challenges must not corrupt the shared
# login-state table.
#
# Builds the plugin from the working tree, loads it into a throwaway Jellyfin
# next to a static mock OpenID provider, and starts 400 logins, 50 at a time.
# Every one must be answered with a redirect to the provider. With a
# non-thread-safe state table some of them fail with HTTP 500
# ("Collection was modified", KeyNotFoundException) and the table can be left
# broken until Jellyfin restarts.
#
# Needs docker, curl and jq. Run from anywhere: tests/concurrent-challenge/run.sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=$HERE/.work
SDK_IMAGE=${SDK_IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}
JELLYFIN_IMAGE=${JELLYFIN_IMAGE:-lscr.io/linuxserver/jellyfin:12.3ubu2604-ls56}
PORT=${PORT:-18097}
REQUESTS=${REQUESTS:-400}
PARALLEL=${PARALLEL:-50}
JF=http://127.0.0.1:$PORT
AUTH='MediaBrowser Client="test", Device="test", DeviceId="concurrent-challenge", Version="1.0"'

cleanup() {
  docker rm -f sso-test-jellyfin sso-test-mock >/dev/null 2>&1 || true
  docker network rm sso-test >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

rm -rf "$WORK"
mkdir -p "$WORK/out" "$WORK/config/data/plugins/SSO-Auth"

echo "building the plugin from the working tree..."
docker run --rm -v "$REPO:/repo:ro" -v "$WORK/out:/out" "$SDK_IMAGE" sh -c '
  set -eu
  mkdir /src && cd /repo && tar -c --exclude=.git --exclude=bin --exclude=obj --exclude=.work . | tar -x -C /src
  cd /src
  dotnet restore SSO-Auth/SSO-Auth.csproj --locked-mode >/dev/null
  dotnet publish SSO-Auth/SSO-Auth.csproj -c Release --no-restore -o /out >/dev/null
  cp meta.json /out/' 
for f in meta.json SSO-Auth.dll Duende.IdentityModel.dll Duende.IdentityModel.OidcClient.dll; do
  cp "$WORK/out/$f" "$WORK/config/data/plugins/SSO-Auth/"
done

echo "starting Jellyfin and the mock provider..."
docker network create sso-test >/dev/null
docker run -d --name sso-test-mock --network sso-test --network-alias mock \
  -v "$HERE/mock:/usr/share/nginx/html:ro" nginx:alpine >/dev/null
docker run -d --name sso-test-jellyfin --network sso-test -p "$PORT:8096" \
  -v "$WORK/config:/config" "$JELLYFIN_IMAGE" >/dev/null

for i in $(seq 1 100); do
  [ "$(curl -fsS "$JF/health" 2>/dev/null)" = "Healthy" ] && break
  [ "$i" -eq 100 ] && { echo "FAIL: Jellyfin did not become healthy"; exit 1; }
  sleep 3
done

curl -fsS -X POST "$JF/Startup/Configuration" -H 'Content-Type: application/json' \
  -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'
curl -fsS "$JF/Startup/User" >/dev/null
curl -fsS -X POST "$JF/Startup/User" -H 'Content-Type: application/json' \
  -d '{"Name":"test","Password":"test-password-1"}'
curl -fsS -X POST "$JF/Startup/Complete"
TOKEN=$(curl -fsS -X POST "$JF/Users/AuthenticateByName" \
  -H 'Content-Type: application/json' -H "Authorization: $AUTH" \
  -d '{"Username":"test","Pw":"test-password-1"}' | jq -r .AccessToken)
curl -fsS -X POST "$JF/sso/OID/Add/mock" \
  -H "Authorization: $AUTH, Token=\"$TOKEN\"" -H 'Content-Type: application/json' \
  -d '{"oidEndpoint":"http://mock","oidClientId":"jellyfin","oidSecret":"x","enabled":true,
       "enableAuthorization":true,"enableAllFolders":true,"enabledFolders":[],"roles":[],
       "adminRoles":[],"oidScopes":["openid"],"disableHttps":true,
       "doNotValidateEndpoints":true,"disablePushedAuthorization":true}' >/dev/null

echo "starting $REQUESTS logins, $PARALLEL at a time..."
seq 1 "$REQUESTS" | xargs -P "$PARALLEL" -I{} \
  curl -s -o /dev/null -w '%{http_code}\n' "$JF/sso/OID/start/mock" | sort | uniq -c > "$WORK/codes.txt"
cat "$WORK/codes.txt"
after=$(curl -s -o /dev/null -w '%{http_code}' "$JF/sso/OID/start/mock")
echo "one more login afterwards: $after"
docker logs sso-test-jellyfin > "$WORK/jellyfin.log" 2>&1

redirects=$(awk '$2 == "302" { print $1 }' "$WORK/codes.txt")
if [ "${redirects:-0}" -ne "$REQUESTS" ] || [ "$after" != "302" ]; then
  echo "FAIL: expected $REQUESTS redirects and a redirect afterwards. Exceptions logged:"
  grep -E '^System\.[A-Za-z.]+Exception' "$WORK/jellyfin.log" | cut -c1-100 | sort | uniq -c
  exit 1
fi
echo "PASS: all $REQUESTS concurrent logins were redirected"
