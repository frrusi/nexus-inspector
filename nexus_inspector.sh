#!/usr/bin/bash

set -o errexit
set -o nounset
set -o pipefail

### Константы ###
HOME_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
readonly HOME_DIR

readonly LOG_DIR="$HOME_DIR/log"

DEBUG_DIR="$LOG_DIR/debug/$(date +"%F")"
readonly DEBUG_DIR
mkdir -p "$DEBUG_DIR"

# https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html#index-BASH_005fXTRACEFD
exec {fileDescriptor}>"$DEBUG_DIR/$(date +"%H-%M-%S").txt" # ToDo: видны креды
BASH_XTRACEFD="$fileDescriptor"

function __msg_error { >&2 echo -e "$1"; exit "$2"; }

# shellcheck disable=SC1090,SC1091
if ! source "${HOME_DIR}/.env"; then
    __msg_error 'Файл .env не найден. Убедитесь, что он существует' '1'
fi

set -x

readonly BROWSE_NEXUS_URL="$BASE_NEXUS_URL/#browse/browse"
readonly ASSETS_NEXUS_URL="$BASE_NEXUS_URL/service/rest/v1/assets"

## Коды выхода
readonly ARGUMENT_ERROR=201
readonly ROOT_ERROR=202
readonly CURL_ERROR=203
readonly DEPENDENCY_ERROR=204
readonly ENV_VARIABLE_ERROR=205

function __usage {
    echo "Usage: $0 [OPTIONS]"
    echo ""
	echo "Options:"
    echo "  --repository  STRING  Репозиторий для проверки"
	echo "  --recipients  LIST    Получатели отчета о сканировании (через запятую, без пробела)"
    echo "  -h, --help            Вывод этого сообщения и выход из программы"
}

function __check_dependencies {
	local dependencies=('curl' 'jq' 'sendmail')
	for dep in "${dependencies[@]}"; do
		command -v "$dep" &> /dev/null || __msg_error "Необходимая зависимость '$dep' не найдена" "$DEPENDENCY_ERROR"
	done

	return 0
}

function __check_env {
	local variables=('BASE_NEXUS_URL' 'NEXUS_LOGIN' 'NEXUS_PASSWORD' 'AUTHORISED_ACCOUNT' 'MAIL_SENDER')
	for var  in "${variables[@]}"; do
		[[ -z "${!var}" ]] && __msg_error "Переменная '$var' не задана. Проверьте .env" "$ENV_VARIABLE_ERROR"
	done

	return 0
}

function __check_root {
	[[ "$EUID" -ne 0 ]] && __msg_error "Скрипт требует root-прав" "$ROOT_ERROR"
	return 0
}

function __toggle_debug {
	if [[ "$1" == "on" ]]; then
		set -x
	else
		set +x
	fi
}

function __is_argument { [[ -n "$1" && "$1" != -* ]]; }

function __init {
    __check_dependencies

	__toggle_debug off # Скрываем креды в логе
	__check_env
	__toggle_debug on

    __check_root

    repoName=""
   	recipients=""
    while [[ $# -gt 0 ]]; do
        case $1 in
           	--repository)
                if ! __is_argument "$2"; then
                    __msg_error "Ошибка: Не указано имя репозитория. Используйте --repository <имя>" "$ARGUMENT_ERROR"
                fi

				repoName="$2"
                shift 2 ;;
			--recipients)
                if ! __is_argument "$2"; then
                    __msg_error "Ошибка: Не указаны получатели. Используйте --recipients <список>" "$ARGUMENT_ERROR"
                fi

				recipients="$2"
                shift 2 ;;
			-h | --help)
                __usage
				exit 0 ;;
			*)
				__msg_error "Неизвестный параметр '$1'. Используйте --help" "$ARGUMENT_ERROR" ;;
        esac
    done

    if [[ -z "$repoName" ]]; then
        __msg_error "Ошибка: Репозиторий не указан. Используйте --repository <имя>" "$ARGUMENT_ERROR"
    fi

    if [[ -z "$recipients" ]]; then
        __msg_error "Ошибка: Список получателей не указан. Используйте --recipients <список>" "$ARGUMENT_ERROR"
    fi
}

function nexus::__get_next_page {
	local url="$1"

	__toggle_debug off # Скрываем креды в логе
	local response
	if ! response=$(curl -u "${NEXUS_LOGIN}:${NEXUS_PASSWORD}" -s "$url"); then
		__msg_error 'Ошибка запроса к Nexus' "$CURL_ERROR"
	fi
	__toggle_debug on

	token=$(jq -r ".continuationToken // empty" <<< "$response")
	readarray -t artifacts < <(jq -c -r '.items[]' <<< "$response")
}

function __cleanup_logs {
    find "$LOG_DIR/reports" -name "*.json" -type f -mtime +7 -delete 2>/dev/null
}

function main {
    __init "$@"

    local repoLogDir="${LOG_DIR}/reports/${repoName}"
    mkdir -p "$repoLogDir"

    local reportFile
	reportFile="${repoLogDir}/report_$(date +"%Y%m%d_%H%M%S").json"
    : > "$reportFile"

	local nexusFinalURL="${ASSETS_NEXUS_URL}?repository=${repoName}"
	local artifactsBlock=""

	local yesterday
	yesterday="$(date -d 'yesterday' +'%Y-%m-%d')"

	nexus::__get_next_page "$nexusFinalURL"
	while true; do
		for artifact in "${artifacts[@]}"; do
			uploader=$(jq -r '.uploader' <<< "$artifact")
			local uploadDate
			uploadDate=$(date +'%Y-%m-%d' -d "$(echo "${artifact}" | jq -r '.lastModified')")

			# Проверяем, загружались ли вчера артефакты не от учетной записи $AUTHORISED_ACCOUNT
			if [[ "$uploadDate" == "$yesterday" && "$uploader" != "$AUTHORISED_ACCOUNT" ]]; then
				echo "$artifact" >> "$reportFile"

				filePath=$(jq -r '.path' <<< "$artifact")
				fileURL="$BROWSE_NEXUS_URL:$repoName:$filePath"
				filename="${fileURL##*/}"

				artifactsBlock+="<tr>
					<td style='padding: 10px; border: 1px solid #ddd;'><a href='${fileURL}'>${filename}</a></td>
					<td style='padding: 10px; border: 1px solid #ddd;'>${uploader}</td>
				</tr>"
			fi
		done

		[[ -n "$token" ]] || break # Если токена нет, выходим из цикла
		nexus::__get_next_page "${nexusFinalURL}&continuationToken=${token}"
	done

	export REPOSITORY="$repoName"
	export REPOSITORY_URL="$BROWSE_NEXUS_URL:$repoName"
	export AUTHORISED_ACCOUNT
	export REPORTFILE_NAME="${reportFile##*/}"
	export MAILFROM="$MAIL_SENDER"
	export MAILTO="$recipients"
	export SUBJECT="Неавторизованные загрузки в ${REPOSITORY}"

	export CURRENT_YEAR
	CURRENT_YEAR=$(date +%Y)

	ARTIFACTS=$(printf "%s" "$artifactsBlock")
	export ARTIFACTS

	if [ -s "$reportFile" ]; then
		jq -s '.' "$reportFile" > tmpfile && mv tmpfile "$reportFile"
		ATTACHMENT=$(base64 "$reportFile")
		export ATTACHMENT

		sendmail -t < <(envsubst < "$HOME_DIR/templates/email.html")
	fi
}

trap __cleanup_logs EXIT SIGINT
main "$@"
