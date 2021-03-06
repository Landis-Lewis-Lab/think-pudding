#!/usr/bin/env bash

# Requires xmllint to be installed
command -v fuseki-server 1> /dev/null 2>&1 || \
  { echo >&2 "fuseki-server required but it's not installed.  Aborting."; exit 1; }

# Usage message
read -r -d '' USE_MSG <<'HEREDOC'
Usage:
  thinkpudding.sh -h
  thinkpudding.sh -p causal_pathway.json   
  thinkpudding.sh -s spek.json -p causal_pathway.json   

TP reads a spek from stdin or provided file path.  
Emits updated spek to stdout unless update-only is used.

Options:
  -h | --help     print help and exit
  -p | --pathways path to configuration file
  -s | --spek     path to spek file (default to stdin)
  -u | --update-only Load nothing. Run update query. 
HEREDOC

# From Chris Down https://gist.github.com/cdown/1163649
urlencode() {
    # urlencode <string>
    old_lc_collate=$LC_COLLATE
    LC_COLLATE=C
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:$i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
    LC_COLLATE=$old_lc_collate
}

# From Chris Down https://gist.github.com/cdown/1163649
urldecode() {
    # urldecode <string>
    local url_encoded="${1//+/ }"
    printf '%b' "${url_encoded//%/\\x}"
}

# Parse args
PARAMS=()
while (( "$#" )); do
  case "$1" in
    -h|--help)
      echo "${USE_MSG}"
      exit 0
      ;;
    -p|--pathways)
      CP_FILE="${2}"
      shift 2
      ;;
    -s|--spek)
      SPEK_FILE="${2}"
      shift 2
      ;;
    -u|--update-only)
      UPDATE_ONLY="TRUE"
      shift 1
      ;;
    --) # end argument parsing
      shift
      break
      ;;
    -*|--*=) # unsupported flags
      echo "Aborting: Unsupported flag $1" >&2
      exit 1
      ;;
    *) # preserve positional arguments
      PARAMS+=("${1}")
      shift
      ;;
  esac
done

# Unless update only, require causal pathways
if [ -z ${UPDATE_ONLY} ]; then

  # Die if causal pathways file not given.
  if [[ -z ${CP_FILE} ]]; then
    echo >&2 "Causal pathway file required."; 
    exit 1;
  fi

  # Die if causal pathways file not found.
  if [[ ! -r ${CP_FILE} ]]; then
    echo >&2 "Causal Pathway file not readable."; 
    exit 1;
  fi
fi

# Check if FUSEKI is running.

FUSEKI_PING=$(curl -s -o /dev/null -w "%{http_code}" localhost:3030/$/ping)
if [[ -z ${FUSEKI_PING}} || ${FUSEKI_PING} -ne 200 ]]; then
  # Error
  echo >&2 "Fuseki not running locally."; 

  # Try to start custom fuseki locally
  fuseki-server --mem --update /ds 1> fuseki.out 2>&1 &
  read -p "Waiting five secs for Fuseki to start..." -t 5
fi

# SPARQL Queries for updates
read -r -d '' UPD_SPARQL <<'USPARQL'
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX obo: <http://purl.obolibrary.org/obo/>
PREFIX slowmo: <http://example.com/slowmo#>

INSERT {
  GRAPH <http://localhost:3030/ds/spek> {
    ?candi slowmo:acceptable_by ?path .
  }
}
USING <http://localhost:3030/ds/spek>
USING <http://localhost:3030/ds/seeps>
WHERE {
  ?path a obo:cpo_0000029 .
  ?candi a obo:cpo_0000053 .

  FILTER NOT EXISTS {
    ?path slowmo:HasPrecondition ?attr .
    ?attr a ?atype .
    FILTER NOT EXISTS {
      ?candi obo:RO_0000091 ?disp .
      ?disp a ?atype
    }
  }
}
USPARQL


# Read from SPEK_FILE or pipe from stdin
#   Use '-' to instruct curl to read from stdin
if [[ -z ${SPEK_FILE} ]]; then
  SPEK_FILE="-"
fi

# Unless update only, load spek and causal pathways into fuseki.
if [ -z ${UPDATE_ONLY} ]; then

  VAL_SPEK="http://localhost:3030/ds/spek"
  ENC_SPEK=$(urlencode "${VAL_SPEK}")
  PARAM_SPEK="graph=${ENC_SPEK}"

  VAL_SEEPS="http://localhost:3030/ds/seeps"
  ENC_SEEPS=$(urlencode "${VAL_SEEPS}")
  PARAM_SEEPS="graph=${ENC_SEEPS}"

  # Load in spek
  curl --silent -X PUT --data-binary "@${SPEK_FILE}" \
    --header 'Content-type: application/ld+json' \
    "http://localhost:3030/ds?${PARAM_SPEK}" >&2

  # Load in causal pathways
  curl --silent -X PUT --data-binary @${CP_FILE} \
    --header 'Content-type: application/ld+json' \
    "http://localhost:3030/ds?${PARAM_SEEPS}" >&2
fi

# run update sparql
curl --silent -X POST --data-binary "${UPD_SPARQL}" \
  --header 'Content-type: application/sparql-update' \
  'http://localhost:3030/ds/update' >&2

# Unless update only, get updated spek and emit to stdout.
if [ -z ${UPDATE_ONLY} ]; then
  curl --silent -G --header 'Accept: application/ld+json' \
    --data-urlencode "graph=http://localhost:3030/ds/spek" \
    'http://localhost:3030/ds'
fi
