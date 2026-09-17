#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==============================================================================
# install_rails_env.sh
#
# Prepara um servidor Debian/Ubuntu para receber uma aplicação Ruby on Rails.
#
# Uso:
#   sudo ./install_rails_env.sh <nome_aplicacao> <diretorio_aplicacao>
#
# Exemplo:
#   sudo ./install_rails_env.sh model5_support /var/www/model5_support
#
# O script:
#   - instala dependências de compilação do Ruby/Rails;
#   - instala uma versão específica do Ruby em /opt/ruby;
#   - instala Bundler;
#   - opcionalmente instala Node.js/NPM;
#   - permite instalar PostgreSQL, MySQL/MariaDB compatível, ou nenhum banco;
#   - cria banco e credenciais informadas pelo operador;
#   - cria usuário/grupo de serviço para a aplicação;
#   - dá acesso colaborativo aos administradores do grupo sudo;
#   - prepara diretórios e permissões do Rails;
#   - cria /etc/rails-apps/<app>/app.env com DATABASE_URL e SECRET_KEY_BASE.
#
# Observação:
#   O script NÃO publica a aplicação, NÃO cria Nginx/Puma/systemd e NÃO executa
#   migrations automaticamente. Ele apenas prepara o ambiente do servidor.
# ==============================================================================

RUBY_VERSION_DEFAULT="3.4.10"
RAILS_APPS_CONFIG_ROOT="/etc/rails-apps"

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '\n\033[1;31m[ERRO]\033[0m Falha na linha %s. Código: %s\n' "${BASH_LINENO[0]}" "$exit_code" >&2
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<EOF
Uso:
  sudo $0 <nome_aplicacao> <diretorio_aplicacao>

Exemplo:
  sudo $0 model5_support /var/www/model5_support
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Execute como root ou instale/use sudo."
    log "Elevando privilégios com sudo..."
    exec sudo --preserve-env=TERM bash "$(readlink -f "$0")" "$@"
  fi
}

validate_app_args() {
  [[ $# -eq 2 ]] || { usage; exit 1; }

  APP_NAME="$1"
  APP_DIR="$(realpath -m "$2")"

  [[ -n "$APP_NAME" ]] || die "O nome da aplicação não pode ser vazio."
  [[ "$APP_DIR" != "/" ]] || die "O diretório da aplicação não pode ser /."

  APP_SLUG="$(
    printf '%s' "$APP_NAME" |
      tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
  )"

  [[ -n "$APP_SLUG" ]] || die "Não foi possível gerar um nome válido para a aplicação."

  # Mantém nome de usuário/grupo bem abaixo do limite tradicional de 32 chars.
  APP_ACCOUNT_SLUG="${APP_SLUG:0:24}"
  APP_USER="rails_${APP_ACCOUNT_SLUG}"
  APP_GROUP="rails_${APP_ACCOUNT_SLUG}"
  APP_HOME="/var/lib/${APP_USER}"
  APP_CONFIG_DIR="${RAILS_APPS_CONFIG_ROOT}/${APP_SLUG}"
  APP_ENV_FILE="${APP_CONFIG_DIR}/app.env"
}

detect_os() {
  [[ -r /etc/os-release ]] || die "Não foi possível identificar o sistema operacional."
  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID:-}" in
    ubuntu|debian)
      ;;
    *)
      die "Sistema não suportado: ${PRETTY_NAME:-${ID:-desconhecido}}. Este script suporta Debian/Ubuntu."
      ;;
  esac

  command -v apt-get >/dev/null 2>&1 || die "apt-get não encontrado."
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  while true; do
    if [[ "$default" == "S" ]]; then
      read -r -p "$prompt [S/n]: " answer
      answer="${answer:-s}"
    else
      read -r -p "$prompt [s/N]: " answer
      answer="${answer:-n}"
    fi

    case "${answer,,}" in
      s|sim|y|yes) return 0 ;;
      n|nao|não|no) return 1 ;;
      *) echo "Responda com s ou n." ;;
    esac
  done
}

prompt_nonempty() {
  local __var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local value

  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "${prompt} [${default}]: " value
      value="${value:-$default}"
    else
      read -r -p "${prompt}: " value
    fi

    if [[ -n "$value" ]]; then
      printf -v "$__var_name" '%s' "$value"
      return 0
    fi

    echo "O valor não pode ser vazio."
  done
}

prompt_identifier() {
  local __var_name="$1"
  local prompt="$2"
  local default="$3"
  local value

  while true; do
    prompt_nonempty value "$prompt" "$default"
    if [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf -v "$__var_name" '%s' "$value"
      return 0
    fi
    echo "Use somente letras, números e '_' e não inicie por número."
  done
}

prompt_password() {
  local __var_name="$1"
  local prompt="$2"
  local p1 p2

  while true; do
    read -r -s -p "${prompt}: " p1
    echo
    [[ -n "$p1" ]] || { echo "A senha não pode ser vazia."; continue; }

    read -r -s -p "Confirme a senha: " p2
    echo

    [[ "$p1" == "$p2" ]] || { echo "As senhas não conferem."; continue; }

    printf -v "$__var_name" '%s' "$p1"
    unset p1 p2
    return 0
  done
}

collect_options() {
  echo
  echo "=============================================="
  echo " Configuração do ambiente Rails"
  echo "=============================================="
  echo "Aplicação : $APP_NAME"
  echo "Diretório : $APP_DIR"
  echo "Usuário   : $APP_USER"
  echo "Grupo     : $APP_GROUP"
  echo

  prompt_nonempty RUBY_VERSION "Versão do Ruby" "$RUBY_VERSION_DEFAULT"

  INSTALL_NODE="0"
  if prompt_yes_no "Instalar Node.js e NPM do repositório da distribuição?" "S"; then
    INSTALL_NODE="1"
  fi

  echo
  echo "Banco de dados local:"
  echo "  1) PostgreSQL"
  echo "  2) MySQL/MariaDB compatível"
  echo "  3) Nenhum"
  echo

  while true; do
    read -r -p "Escolha [1-3]: " DB_CHOICE
    case "$DB_CHOICE" in
      1) DB_ENGINE="postgresql"; break ;;
      2) DB_ENGINE="mysql"; break ;;
      3) DB_ENGINE="none"; break ;;
      *) echo "Opção inválida." ;;
    esac
  done

  DB_NAME=""
  DB_USER=""
  DB_PASSWORD=""

  if [[ "$DB_ENGINE" != "none" ]]; then
    prompt_identifier DB_NAME "Nome do banco" "${APP_SLUG}_production"
    prompt_identifier DB_USER "Usuário do banco" "$APP_SLUG"
    prompt_password DB_PASSWORD "Senha do usuário do banco"
  fi

  echo
  echo "----------------------------------------------"
  echo "Resumo"
  echo "----------------------------------------------"
  echo "Aplicação       : $APP_NAME"
  echo "Diretório       : $APP_DIR"
  echo "Ruby            : $RUBY_VERSION"
  echo "Node.js/NPM     : $([[ "$INSTALL_NODE" == "1" ]] && echo "sim" || echo "não")"
  echo "Banco local     : $DB_ENGINE"
  if [[ "$DB_ENGINE" != "none" ]]; then
    echo "Database        : $DB_NAME"
    echo "Usuário DB      : $DB_USER"
    echo "Senha DB        : ********"
  fi
  echo "Usuário serviço : $APP_USER"
  echo "Grupo serviço   : $APP_GROUP"
  echo "Config ambiente : $APP_ENV_FILE"
  echo "----------------------------------------------"
  echo

  prompt_yes_no "Continuar com a instalação?" "N" || {
    echo "Instalação cancelada."
    exit 0
  }
}

install_base_packages() {
  log "Atualizando índices do APT..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  local packages=(
    build-essential
    ca-certificates
    curl
    git
    pkg-config
    autoconf
    bison
    rustc
    xz-utils
    acl
    openssl
    libssl-dev
    libyaml-dev
    zlib1g-dev
    libgmp-dev
    libreadline-dev
    libffi-dev
    libgdbm-dev
    libncurses-dev
    libdb-dev
    liblzma-dev
    libxml2-dev
    libxslt1-dev
    libvips
    sqlite3
    libsqlite3-dev
  )

  if [[ "$INSTALL_NODE" == "1" ]]; then
    packages+=(nodejs npm)
  fi

  log "Instalando dependências base..."
  apt-get install -y "${packages[@]}"
  ok "Dependências base instaladas."
}

install_ruby() {
  local ruby_prefix="/opt/ruby/${RUBY_VERSION}"
  local ruby_mm
  ruby_mm="$(awk -F. '{print $1"."$2}' <<<"$RUBY_VERSION")"
  local ruby_tar="ruby-${RUBY_VERSION}.tar.xz"
  local ruby_url="https://cache.ruby-lang.org/pub/ruby/${ruby_mm}/${ruby_tar}"
  local build_dir="/usr/local/src/ruby-${RUBY_VERSION}-build"

  if [[ -x "${ruby_prefix}/bin/ruby" ]]; then
    log "Ruby ${RUBY_VERSION} já está instalado em ${ruby_prefix}; reutilizando."
  else
    log "Baixando Ruby ${RUBY_VERSION}..."
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    curl --fail --location --retry 3 --output "${build_dir}/${ruby_tar}" "$ruby_url"

    log "Compilando Ruby ${RUBY_VERSION}. Esta etapa pode usar bastante CPU."
    tar -xJf "${build_dir}/${ruby_tar}" -C "$build_dir"

    pushd "${build_dir}/ruby-${RUBY_VERSION}" >/dev/null
    ./configure \
      --prefix="$ruby_prefix" \
      --disable-install-doc \
      --enable-shared

    make -j"$(nproc)"
    make install
    popd >/dev/null

    rm -rf "$build_dir"
  fi

  ln -sfn "${ruby_prefix}" /opt/ruby/current

  # Wrappers globais: mantêm um único Ruby ativo para este servidor.
  local executable
  for executable in ruby gem bundle bundler erb irb rake rdoc ri; do
    if [[ -e "/opt/ruby/current/bin/${executable}" ]]; then
      ln -sfn "/opt/ruby/current/bin/${executable}" "/usr/local/bin/${executable}"
    fi
  done

  export PATH="/opt/ruby/current/bin:/usr/local/bin:${PATH}"

  log "Instalando/atualizando Bundler para este Ruby..."
  gem install bundler --no-document

  # Recria links depois da instalação do Bundler.
  ln -sfn /opt/ruby/current/bin/bundle /usr/local/bin/bundle
  ln -sfn /opt/ruby/current/bin/bundler /usr/local/bin/bundler

  ok "Ruby instalado: $(ruby --version)"
  ok "Bundler instalado: $(bundle --version)"
}

create_app_account() {
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    log "Criando grupo de serviço ${APP_GROUP}..."
    groupadd --system "$APP_GROUP"
  else
    log "Grupo ${APP_GROUP} já existe."
  fi

  if ! id "$APP_USER" >/dev/null 2>&1; then
    log "Criando usuário de serviço ${APP_USER}..."
    useradd \
      --system \
      --gid "$APP_GROUP" \
      --home-dir "$APP_HOME" \
      --create-home \
      --shell /usr/sbin/nologin \
      "$APP_USER"
  else
    log "Usuário ${APP_USER} já existe."
  fi

  # Adiciona os membros atuais do grupo sudo ao grupo da aplicação.
  if getent group sudo >/dev/null 2>&1; then
    local sudo_members
    sudo_members="$(getent group sudo | awk -F: '{print $4}' | tr ',' '\n' || true)"

    while IFS= read -r admin_user; do
      [[ -n "$admin_user" ]] || continue
      id "$admin_user" >/dev/null 2>&1 || continue
      usermod -aG "$APP_GROUP" "$admin_user"
    done <<<"$sudo_members"
  fi

  # Garante também o usuário que chamou sudo, mesmo que a regra de sudo não
  # venha diretamente do grupo "sudo".
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
    usermod -aG "$APP_GROUP" "$SUDO_USER"
  fi

  ok "Usuário/grupo da aplicação preparados."
}

prepare_app_directories() {
  log "Preparando diretórios da aplicação..."

  mkdir -p \
    "$APP_DIR" \
    "$APP_DIR/log" \
    "$APP_DIR/storage" \
    "$APP_DIR/tmp/cache" \
    "$APP_DIR/tmp/pids" \
    "$APP_DIR/tmp/sockets" \
    "$APP_DIR/shared"

  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"

  # Colaboração entre o usuário da aplicação e administradores.
  chmod -R g+rwX "$APP_DIR"
  find "$APP_DIR" -type d -exec chmod g+s {} +

  # ACL do grupo da aplicação: novos arquivos continuam editáveis pelo grupo.
  setfacl -R -m "g:${APP_GROUP}:rwX,m::rwX" "$APP_DIR"
  setfacl -R -d -m "g:${APP_GROUP}:rwX,m::rwX" "$APP_DIR"

  # Também permite acesso direto aos membros atuais/futuros do grupo sudo.
  # Isto evita depender somente de usermod para administradores criados depois.
  if getent group sudo >/dev/null 2>&1; then
    setfacl -R -m "g:sudo:rwX,m::rwX" "$APP_DIR"
    setfacl -R -d -m "g:sudo:rwX,m::rwX" "$APP_DIR"
  fi

  ok "Permissões do diretório da aplicação configuradas."
}

install_postgresql() {
  log "Instalando PostgreSQL..."
  apt-get install -y postgresql postgresql-client postgresql-contrib libpq-dev

  systemctl enable --now postgresql

  log "Configurando usuário e banco PostgreSQL..."

  if ! runuser -u postgres -- psql -tAc \
      "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'" | grep -q 1; then
    runuser -u postgres -- createuser "$DB_USER"
  fi

  # psql faz quoting seguro:
  #   :"db_user" = identificador
  #   :'db_pass' = literal SQL
  runuser -u postgres -- psql \
    --set=ON_ERROR_STOP=1 \
    --set=db_user="$DB_USER" \
    --set=db_pass="$DB_PASSWORD" <<'PSQL'
ALTER ROLE :"db_user" WITH LOGIN PASSWORD :'db_pass';
PSQL

  if ! runuser -u postgres -- psql -tAc \
      "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1; then
    runuser -u postgres -- createdb --owner="$DB_USER" "$DB_NAME"
  else
    runuser -u postgres -- psql \
      --set=ON_ERROR_STOP=1 \
      --set=db_name="$DB_NAME" \
      --set=db_user="$DB_USER" <<'PSQL'
ALTER DATABASE :"db_name" OWNER TO :"db_user";
PSQL
  fi

  ok "PostgreSQL configurado."
}

mysql_escape_literal() {
  # Escapa \ e ' para uso dentro de literal SQL MySQL.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

install_mysql() {
  log "Instalando servidor MySQL/MariaDB compatível..."

  if [[ "${ID}" == "ubuntu" ]]; then
    apt-get install -y mysql-server libmysqlclient-dev
  else
    # Debian normalmente entrega MariaDB através do metapacote default-mysql-*.
    apt-get install -y default-mysql-server default-libmysqlclient-dev
  fi

  local mysql_service=""
  if systemctl list-unit-files --type=service | grep -q '^mysql\.service'; then
    mysql_service="mysql"
  elif systemctl list-unit-files --type=service | grep -q '^mariadb\.service'; then
    mysql_service="mariadb"
  else
    die "Serviço MySQL/MariaDB não encontrado após a instalação."
  fi

  systemctl enable --now "$mysql_service"

  local db_pass_sql
  db_pass_sql="$(mysql_escape_literal "$DB_PASSWORD")"

  log "Configurando usuário e banco MySQL/MariaDB..."

  mysql --protocol=socket -uroot <<MYSQLSQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
  IDENTIFIED BY '${db_pass_sql}';
ALTER USER '${DB_USER}'@'localhost'
  IDENTIFIED BY '${db_pass_sql}';

CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1'
  IDENTIFIED BY '${db_pass_sql}';
ALTER USER '${DB_USER}'@'127.0.0.1'
  IDENTIFIED BY '${db_pass_sql}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQLSQL

  ok "MySQL/MariaDB configurado."
}

urlencode_with_ruby() {
  ruby -r uri -e 'print URI.encode_www_form_component(ARGV.fetch(0))' "$1"
}

create_environment_file() {
  log "Criando arquivo de ambiente protegido..."

  mkdir -p "$APP_CONFIG_DIR"
  chown root:"$APP_GROUP" "$APP_CONFIG_DIR"
  chmod 0750 "$APP_CONFIG_DIR"

  local secret_key_base
  secret_key_base="$(openssl rand -hex 64)"

  umask 0077
  {
    echo "# Gerado por install_rails_env.sh"
    echo "# Não versionar este arquivo."
    echo "RAILS_ENV=production"
    echo "RACK_ENV=production"
    echo "RAILS_LOG_TO_STDOUT=true"
    echo "RAILS_SERVE_STATIC_FILES=true"
    echo "SECRET_KEY_BASE=${secret_key_base}"

    if [[ "$DB_ENGINE" == "postgresql" ]]; then
      local encoded_password
      encoded_password="$(urlencode_with_ruby "$DB_PASSWORD")"
      echo "DATABASE_URL=postgresql://${DB_USER}:${encoded_password}@127.0.0.1:5432/${DB_NAME}"
    elif [[ "$DB_ENGINE" == "mysql" ]]; then
      local encoded_password
      encoded_password="$(urlencode_with_ruby "$DB_PASSWORD")"
      echo "DATABASE_URL=mysql2://${DB_USER}:${encoded_password}@127.0.0.1:3306/${DB_NAME}?encoding=utf8mb4"
    fi
  } > "$APP_ENV_FILE"

  chown root:"$APP_GROUP" "$APP_ENV_FILE"
  chmod 0640 "$APP_ENV_FILE"

  ln -sfn "$APP_ENV_FILE" "$APP_DIR/shared/app.env"
  chown -h "$APP_USER:$APP_GROUP" "$APP_DIR/shared/app.env"

  ok "Arquivo criado em $APP_ENV_FILE"
}

create_runtime_profile() {
  local profile_file="/etc/profile.d/${APP_SLUG}_rails.sh"

  cat > "$profile_file" <<EOF
# Ambiente Ruby da aplicação ${APP_NAME}
export PATH="/opt/ruby/current/bin:/usr/local/bin:\$PATH"
EOF

  chmod 0644 "$profile_file"
}

print_final_instructions() {
  echo
  echo "============================================================"
  echo " Ambiente Rails preparado com sucesso"
  echo "============================================================"
  echo "Aplicação       : $APP_NAME"
  echo "Diretório       : $APP_DIR"
  echo "Usuário serviço : $APP_USER"
  echo "Grupo           : $APP_GROUP"
  echo "Ruby            : $(ruby --version)"
  echo "Bundler         : $(bundle --version)"
  echo "Banco           : $DB_ENGINE"
  echo "EnvironmentFile : $APP_ENV_FILE"
  echo
  echo "Próximos passos sugeridos após copiar/clonar a aplicação:"
  echo
  echo "  1. Ajustar a propriedade/permissões, se novos arquivos forem copiados:"
  echo "       chown -R ${APP_USER}:${APP_GROUP} ${APP_DIR}"
  echo "       chmod -R g+rwX ${APP_DIR}"
  echo
  echo "  2. Instalar as gems como o usuário da aplicação:"
  echo "       sudo -u ${APP_USER} -H bash -c 'cd ${APP_DIR} && bundle config set --local deployment true && bundle install'"
  echo
  echo "  3. Para comandos Rails, carregue o ambiente:"
  echo "       sudo -u ${APP_USER} -H bash -c 'set -a; source ${APP_ENV_FILE}; set +a; cd ${APP_DIR}; bundle exec rails about'"
  echo
  echo "  4. Informe RAILS_MASTER_KEY separadamente, caso sua aplicação use"
  echo "     config/credentials.yml.enc. Não gere uma nova chave no servidor."
  echo
  echo "IMPORTANTE:"
  echo "  - usuários adicionados agora ao grupo ${APP_GROUP} precisam abrir uma"
  echo "    nova sessão para a nova associação de grupo valer;"
  echo "  - este script não expõe o banco externamente;"
  echo "  - este script não cria o serviço Puma/systemd nem o proxy Nginx."
  echo "============================================================"
}

main() {
  require_root "$@"
  validate_app_args "$@"
  detect_os
  collect_options

  install_base_packages
  install_ruby
  create_app_account
  prepare_app_directories

  case "$DB_ENGINE" in
    postgresql) install_postgresql ;;
    mysql)      install_mysql ;;
    none)       log "Instalação de banco local ignorada." ;;
  esac

  create_environment_file
  create_runtime_profile

  # Apaga da memória do shell assim que não forem mais necessárias.
  unset DB_PASSWORD || true

  print_final_instructions
}

main "$@"
