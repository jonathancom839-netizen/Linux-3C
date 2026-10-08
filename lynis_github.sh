#!/usr/bin/env bash
set -Eeuo pipefail
set +x

REPO_URL="https://github.com/unciafidelis/lynis.git"
REPO_DIR="${HOME}/lynis-github"

CONFIG_DIR="${HOME}/.config/lynis-github"
CRED_FILE="${CONFIG_DIR}/.github_credentials.enc"
KEY_FILE="${CONFIG_DIR}/.github_credentials.key"

LYNIS_LOG="/var/log/lynis.log"
LYNIS_REPORT="/var/log/lynis-report.dat"

HOST_ID="$(hostname -s 2>/dev/null || hostname)"
DEST_REL="logs/${HOST_ID}"
DEST_DIR="${REPO_DIR}/${DEST_REL}"

ASKPASS_FILE=""

cleanup() {
    if [[ -n "${ASKPASS_FILE:-}" && -f "${ASKPASS_FILE}" ]]; then
        rm -f "${ASKPASS_FILE}"
    fi

    unset GITHUB_USER || true
    unset GITHUB_TOKEN || true
    unset DECRYPTED_CREDENTIALS || true
}

trap cleanup EXIT INT TERM

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    printf '[INFO] %s\n' "$*"
}

install_dependencies() {
    local missing=0

    command -v git >/dev/null 2>&1 || missing=1
    command -v openssl >/dev/null 2>&1 || missing=1

    if [[ "${missing}" -eq 1 ]]; then
        info "Instalando Git y OpenSSL..."
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git openssl ca-certificates
    fi

    command -v git >/dev/null 2>&1 || die "Git no pudo instalarse."
    command -v openssl >/dev/null 2>&1 || die "OpenSSL no pudo instalarse."
}

create_credentials_if_needed() {
    if [[ -f "${CRED_FILE}" && -f "${KEY_FILE}" ]]; then
        return
    fi

    info "Configuración inicial de acceso a GitHub."
    echo "GitHub requiere un Personal Access Token (PAT) para Git por HTTPS."
    echo "El token debe tener permiso de escritura sobre el repositorio."
    echo

    local github_user=""
    local github_token=""
    local tmp_plain=""

    read -r -p "Usuario de GitHub: " github_user
    [[ -n "${github_user}" ]] || die "El usuario no puede estar vacío."

    read -r -s -p "Personal Access Token (PAT): " github_token
    echo
    [[ -n "${github_token}" ]] || die "El token no puede estar vacío."

    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"

    umask 077
    openssl rand -hex 32 > "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"

    tmp_plain="$(mktemp)"
    chmod 600 "${tmp_plain}"

    {
        printf 'username=%s\n' "${github_user}"
        printf 'token=%s\n' "${github_token}"
    } > "${tmp_plain}"

    openssl enc \
        -aes-256-cbc \
        -salt \
        -pbkdf2 \
        -iter 200000 \
        -in "${tmp_plain}" \
        -out "${CRED_FILE}" \
        -pass "file:${KEY_FILE}"

    chmod 600 "${CRED_FILE}"

    # Borrar el temporal de texto claro.
    if command -v shred >/dev/null 2>&1; then
        shred -u "${tmp_plain}"
    else
        rm -f "${tmp_plain}"
    fi

    unset github_token

    info "Credenciales guardadas de forma cifrada en:"
    echo "  ${CRED_FILE}"
    info "Clave local protegida en:"
    echo "  ${KEY_FILE}"
}

load_credentials() {
    [[ -r "${CRED_FILE}" ]] || die "No se puede leer ${CRED_FILE}"
    [[ -r "${KEY_FILE}" ]] || die "No se puede leer ${KEY_FILE}"

    DECRYPTED_CREDENTIALS="$(
        openssl enc \
            -d \
            -aes-256-cbc \
            -pbkdf2 \
            -iter 200000 \
            -in "${CRED_FILE}" \
            -pass "file:${KEY_FILE}" 2>/dev/null
    )" || die "No fue posible descifrar las credenciales."

    GITHUB_USER="$(printf '%s\n' "${DECRYPTED_CREDENTIALS}" | sed -n 's/^username=//p' | head -n 1)"
    GITHUB_TOKEN="$(printf '%s\n' "${DECRYPTED_CREDENTIALS}" | sed -n 's/^token=//p' | head -n 1)"

    unset DECRYPTED_CREDENTIALS

    [[ -n "${GITHUB_USER}" ]] || die "Usuario de GitHub ausente en el archivo cifrado."
    [[ -n "${GITHUB_TOKEN}" ]] || die "Token de GitHub ausente en el archivo cifrado."

    export GITHUB_USER
    export GITHUB_TOKEN
}

configure_git_askpass() {
    ASKPASS_FILE="$(mktemp)"
    chmod 700 "${ASKPASS_FILE}"

    cat > "${ASKPASS_FILE}" <<'ASKPASS'
#!/usr/bin/env sh
case "$1" in
    Username|username)
        printf '%s\n' "${GITHUB_USER}"
        ;;
    Password|password)
        printf '%s\n' "${GITHUB_TOKEN}"
        ;;
    *)
        exit 1
        ;;
esac
ASKPASS

    export GIT_ASKPASS="${ASKPASS_FILE}"
    export GIT_TERMINAL_PROMPT=0
}

check_remote_access() {
    info "Verificando acceso al repositorio GitHub..."
    git ls-remote "${REPO_URL}" HEAD >/dev/null 2>&1 || {
        echo >&2
        echo "No fue posible autenticarse o acceder al repositorio." >&2
        echo "Revise:" >&2
        echo "  1) usuario de GitHub;" >&2
        echo "  2) PAT vigente;" >&2
        echo "  3) permiso de escritura sobre unciafidelis/lynis." >&2
        echo >&2
        echo "Para forzar una nueva configuración de credenciales:" >&2
        echo "  rm -f '${CRED_FILE}' '${KEY_FILE}'" >&2
        exit 1
    }
}

prepare_repository() {
    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        if [[ -e "${REPO_DIR}" ]]; then
            die "${REPO_DIR} existe, pero no es un repositorio Git."
        fi

        info "Clonando ${REPO_URL}..."
        git clone "${REPO_URL}" "${REPO_DIR}"
    else
        info "Repositorio local encontrado."

        git -C "${REPO_DIR}" remote set-url origin "${REPO_URL}"

        if [[ -n "$(git -C "${REPO_DIR}" status --porcelain)" ]]; then
            die "El repositorio local contiene cambios sin commit. Revise ${REPO_DIR} antes de continuar."
        fi

        info "Sincronizando con GitHub..."
        git -C "${REPO_DIR}" fetch origin --prune

        local branch
        branch="$(git -C "${REPO_DIR}" symbolic-ref --quiet --short HEAD || true)"
        [[ -n "${branch}" ]] || die "No se pudo determinar la rama activa."

        git -C "${REPO_DIR}" pull --rebase origin "${branch}"
    fi

    if ! git -C "${REPO_DIR}" config user.name >/dev/null 2>&1; then
        git -C "${REPO_DIR}" config user.name "${GITHUB_USER}"
    fi

    if ! git -C "${REPO_DIR}" config user.email >/dev/null 2>&1; then
        git -C "${REPO_DIR}" config user.email "${GITHUB_USER}@users.noreply.github.com"
    fi
}

copy_lynis_files() {
    sudo test -f "${LYNIS_LOG}" || die "No existe ${LYNIS_LOG}. Ejecute Lynis primero."
    sudo test -f "${LYNIS_REPORT}" || die "No existe ${LYNIS_REPORT}. Ejecute Lynis primero."

    mkdir -p "${DEST_DIR}"

    info "Copiando archivos de Lynis desde /var/log..."
    sudo cat "${LYNIS_LOG}" > "${DEST_DIR}/lynis.log"
    sudo cat "${LYNIS_REPORT}" > "${DEST_DIR}/lynis-report.dat"

    chmod 640 "${DEST_DIR}/lynis.log" "${DEST_DIR}/lynis-report.dat"

    info "Destino:"
    echo "  ${DEST_DIR}/lynis.log"
    echo "  ${DEST_DIR}/lynis-report.dat"
}

commit_and_push() {
    local branch
    local timestamp

    branch="$(git -C "${REPO_DIR}" symbolic-ref --quiet --short HEAD || true)"
    [[ -n "${branch}" ]] || die "No se pudo determinar la rama activa."

    git -C "${REPO_DIR}" add \
        "${DEST_REL}/lynis.log" \
        "${DEST_REL}/lynis-report.dat"

    if git -C "${REPO_DIR}" diff --cached --quiet; then
        info "Los archivos no cambiaron. No hay nada nuevo que subir."
        return
    fi

    timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"

    info "Creando commit..."
    git -C "${REPO_DIR}" commit \
        -m "Actualizar resultados Lynis de ${HOST_ID} - ${timestamp}"

    info "Subiendo cambios a GitHub..."
    git -C "${REPO_DIR}" push origin "${branch}"

    info "Proceso completado correctamente."
}

main() {
    install_dependencies
    create_credentials_if_needed
    load_credentials
    configure_git_askpass
    check_remote_access
    prepare_repository
    copy_lynis_files
    commit_and_push
}

main "$@"