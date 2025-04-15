#!/usr/bin/bash

set -o errexit
set -o nounset
set -o pipefail

### Константы ###
HOME_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
readonly HOME_DIR

readonly NEXUS_INSPECTOR_DIR="/var/lib/nexus_inspector"
mkdir -p "$NEXUS_INSPECTOR_DIR"

readonly LAST_RUN_FILE="$NEXUS_INSPECTOR_DIR/state.json"
if [[ ! -f "$LAST_RUN_FILE" ]]; then
    echo '{ "repositories": {} }' > "$LAST_RUN_FILE"
fi

readonly TMP_FILE="$NEXUS_INSPECTOR_DIR/tmpfile"

# Коды ошибок
readonly ARGUMENT_ERROR=201
readonly ROOT_ERROR=202
readonly DEPENDENCY_ERROR=203

function __msg_error { >&2 echo -e "$1"; exit "$2"; }
function __usage {
    echo "Usage: $0 [OPTIONS]"
    echo ""
	echo "Options:"
    echo "  -c, --config  STRING  Путь до конфигурационного JSON-файла"
    echo "  -h, --help            Вывод этого сообщения и выход из программы"
}

function __check_dependencies {
	local dependencies=('jq')
	for dep in "${dependencies[@]}"; do
		command -v "$dep" &> /dev/null || __msg_error "Необходимая зависимость '$dep' не найдена" "$DEPENDENCY_ERROR"
	done

    return 0
}

function __check_root {
	[[ "$EUID" -ne 0 ]] && __msg_error "Скрипт требует root-прав" "$ROOT_ERROR"
    return 0
}

function __is_argument { [[ -n "$1" && "$1" != -* ]]; }

function __init {
    __check_dependencies
    __check_root

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c | --config)
                if ! __is_argument "$2" || [[ ! -s "$2" ]]; then
                    __msg_error "Ошибка: Указан некорректный конфигурационный файл" "$ARGUMENT_ERROR"
                fi

                configPath=$(realpath "$2")
                shift 2 ;;
			-h | --help)
                __usage
				exit 0 ;;
			*)
				__msg_error "Неизвестный параметр '$1'. Используйте --help" "$ARGUMENT_ERROR" ;;
        esac
    done

    if [[ -z "${configPath:-}" ]]; then
        __msg_error "Ошибка: Путь до конфигурационного файла не указан. Используйте --config <путь>" "$ARGUMENT_ERROR"
    fi
}

__run_control() {
    local repository="$1"
    local hour="$2"
    local minute="$3"
    local recipients="$4"

    local scheduledTimeEpoch
    scheduledTimeEpoch=$(date -u -d "$(date +%F)T${hour}:${minute}:00" +%s)

    local lastRunTime lastRunTimeEpoch
    lastRunTime=$(jq -r --arg repo "$repository" '.repositories[$repo] // ""' "$LAST_RUN_FILE")

    lastRunTimeEpoch=0
    [[ -n "$lastRunTime" ]] && lastRunTimeEpoch=$(date -u -d "$lastRunTime" +%s)

    if (( lastRunTimeEpoch >= scheduledTimeEpoch )); then
        return
    fi

    /bin/bash "$HOME_DIR/nexus_inspector.sh" --repository "$repository" --recipients "$recipients"

    local currentTime
    currentTime=$(date +"%Y-%m-%dT%H:%M:%S%z")
    jq --arg repo "$repository" \
       --arg time "$currentTime" \
       '.repositories[$repo] = $time' "$LAST_RUN_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$LAST_RUN_FILE"
}

function __cleanup {
    rm -f "$TMP_FILE"
}

function main {
    __init "$@"

    while read -r repository; do
        local repositoryName repositoryEnabled scheduledHour scheduledMinute recipients

        repositoryName=$(jq -r '.name' <<< "$repository")
        repositoryEnabled=$(jq -r '.enabled' <<< "$repository")
        scheduledHour=$(jq -r '.schedule.hour' <<< "$repository")
        scheduledMinute=$(jq -r '.schedule.minute' <<< "$repository")
        recipients=$(jq -r '.recipients | join(",")' <<< "$repository")

        if [[ "$repositoryEnabled" == "true" ]]; then
            __run_control "$repositoryName" "$scheduledHour" "$scheduledMinute" "$recipients"
        fi
    done < <(jq -c '.repositories[]' "$configPath")
}

trap __cleanup EXIT SIGINT
main "$@"
