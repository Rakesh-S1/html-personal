#!/usr/bin/env bash
# Look up the values for .env from your Google Cloud project and print them.
# Run in Cloud Shell:
#
#   bash make_env.sh                      # print .env (MySQL password left as a placeholder)
#   bash make_env.sh --new-db-password    # also (re)create user betty_reader with a new random
#                                         # password and print it in the .env
#   bash make_env.sh --write              # same as printing, but also saves it to ./.env
#   (options can be combined: bash make_env.sh --new-db-password --write)
set -uo pipefail

NEW_PW=0; WRITE=0
for a in "$@"; do
  case "$a" in
    --new-db-password) NEW_PW=1 ;;
    --write) WRITE=1 ;;
  esac
done
note() { echo "# >> $*" >&2; }

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[ -n "$PROJECT_ID" ] || { echo "No project set. Run: gcloud config set project <your-project-id>"; exit 1; }
note "Project: $PROJECT_ID"

# ---------------- Cloud SQL
SQL_INSTANCE="${SQL_INSTANCE:-}"
if [ -z "$SQL_INSTANCE" ]; then
  mapfile -t instances < <(gcloud sql instances list --format='value(name)' 2>/dev/null)
  if [ "${#instances[@]}" -eq 0 ]; then
    note "No Cloud SQL instance found - create one first (MySQL 8.0, public IP)."
  else
    SQL_INSTANCE="${instances[0]}"
    [ "${#instances[@]}" -gt 1 ] && note "Several instances: ${instances[*]} - using $SQL_INSTANCE (set SQL_INSTANCE=... to choose)"
  fi
fi
SQL_HOST="<public-ip-of-cloud-sql>"
if [ -n "$SQL_INSTANCE" ]; then
  SQL_HOST="$(gcloud sql instances describe "$SQL_INSTANCE" --format='value(ipAddresses[0].ipAddress)')"
  STATE="$(gcloud sql instances describe "$SQL_INSTANCE" --format='value(state)')"
  NETS="$(gcloud sql instances describe "$SQL_INSTANCE" --format='value(settings.ipConfiguration.authorizedNetworks[].value)')"
  MY_IP="$(curl -s https://ifconfig.me)"
  note "Cloud SQL: $SQL_INSTANCE  state=$STATE  ip=$SQL_HOST"
  if ! echo "$NETS" | grep -q "$MY_IP"; then
    note "Cloud Shell IP $MY_IP is NOT authorized on $SQL_INSTANCE. Fix with:"
    note "  gcloud sql instances patch $SQL_INSTANCE --authorized-networks=$MY_IP/32 --quiet"
  fi
fi

DB_USER="betty_reader"
DB_PASSWORD="<mysql-password-for-$DB_USER>"
if [ "$NEW_PW" = 1 ] && [ -n "$SQL_INSTANCE" ]; then
  DB_PASSWORD="$(python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print(''.join(secrets.choice(a) for _ in range(24)))")"
  if gcloud sql users list --instance="$SQL_INSTANCE" --format='value(name)' | grep -qx "$DB_USER"; then
    gcloud sql users set-password "$DB_USER" --host=% --instance="$SQL_INSTANCE" --password="$DB_PASSWORD" >/dev/null 2>&1 \
      && note "Set a new password for $DB_USER" || note "Could not set password for $DB_USER"
  else
    gcloud sql users create "$DB_USER" --host=% --instance="$SQL_INSTANCE" --password="$DB_PASSWORD" >/dev/null 2>&1 \
      && note "Created MySQL user $DB_USER" || note "Could not create MySQL user $DB_USER"
  fi
fi

# ---------------- Vertex AI Search
DE="https://discoveryengine.googleapis.com/v1/projects/$PROJECT_ID/locations/global/collections/default_collection"
api() { curl -s "$1" -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "x-goog-user-project: $PROJECT_ID"; }
ENGINE_ID="$(api "$DE/engines" | python3 -c '
import json,sys
try: e=json.load(sys.stdin).get("engines",[])
except Exception: e=[]
for x in e: print(x["name"].rsplit("/",1)[1], "|", x.get("displayName",""), "|", ",".join(x.get("dataStoreIds",[])), file=sys.stderr)
print(e[0]["name"].rsplit("/",1)[1] if e else "")')"
RESULT_MODE="CHUNKS"
if [ -z "$ENGINE_ID" ]; then
  ENGINE_ID="<your-search-app-id>"
  note "No Vertex AI Search app found in location 'global' - create one connected to the PDFs."
else
  note "Search app (engine) used: $ENGINE_ID   (all apps listed above as: id | name | data stores)"
  CHUNKING="$(api "$DE/dataStores" | python3 -c '
import json,sys
try: d=json.load(sys.stdin).get("dataStores",[])
except Exception: d=[]
print("yes" if any("chunkingConfig" in (x.get("documentProcessingConfig") or {}) for x in d) else "no")')"
  [ "$CHUNKING" = "no" ] && { RESULT_MODE="DOCUMENTS"; note "Data store has no chunking -> DATASTORE_RESULT_MODE=DOCUMENTS"; }
fi

ENV_TEXT="# Gemini on Vertex AI
GOOGLE_GENAI_USE_VERTEXAI=TRUE
GOOGLE_CLOUD_PROJECT=$PROJECT_ID
GOOGLE_CLOUD_LOCATION=us-central1

# Vertex AI Search (store PDFs)
DATASTORE_PROJECT_ID=$PROJECT_ID
DATASTORE_ENGINE_ID=$ENGINE_ID
DATASTORE_LOCATION=global
DATASTORE_RESULT_MODE=$RESULT_MODE

# Cloud SQL for MySQL via MCP Toolbox
MYSQL_HOST=$SQL_HOST
MYSQL_PORT=3306
MYSQL_DATABASE=betty
MYSQL_USER=$DB_USER
MYSQL_PASSWORD=$DB_PASSWORD
TOOLBOX_URL=http://127.0.0.1:5000
BETTY_SQL_INSTANCE=$SQL_INSTANCE"

echo
echo "########## copy everything below into ~/project/.env ##########"
echo "$ENV_TEXT"
echo "########## end ##########"
if [ "$WRITE" = 1 ]; then
  echo "$ENV_TEXT" > .env && chmod 600 .env && echo "Saved to $(pwd)/.env"
fi
case "$DB_PASSWORD" in "<"*) echo "Replace the MYSQL_PASSWORD placeholder, or re-run with --new-db-password." ;; esac
