#!/bin/bash

# 檢查是否以root權限運行
if [ "$(id -u)" -ne 0 ]; then
  echo "此腳本需要root權限運行" 
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  else
    install_sudo_cmd=""
    if command -v apt >/dev/null 2>&1; then
      install_sudo_cmd="apt-get update && apt-get install -y sudo"
    elif command -v dnf >/dev/null 2>&1; then
      install_sudo_cmd="dnf install -y sudo"
    elif command -v apk >/dev/null 2>&1; then
      install_sudo_cmd="apk add sudo"
    else
      echo "無sudo指令"
      sleep 1
      exit 1
    fi
    su -c "$install_sudo_cmd"
    if [ $? -eq 0 ] && command -v sudo >/dev/null 2>&1; then
      echo "sudo指令已經安裝成功，請等下輸入您的密碼"
      exec sudo "$0" "$@"
    fi
  fi
fi

# 版本
version="8.3.3"

#變量
CURRENT_PAGE_NGINX=1
TOTAL_PAGES_NGINX=1

# 顏色定義
RED="\033[1;31m"    # ❌ 錯誤用紅色
GREEN="\033[1;32m"   # ✅ 成功用綠色
YELLOW='\033[1;33m'  # ⚠️ 警告用黃色
CYAN="\033[1;36m"    # ℹ️ 一般提示用青色
GRAY='\033[0;90m'
RESET='\033[0m'      # 清除顏色

phpini_path()(
  local php_var=$(check_php_version)
  local php_ini
  if [ "$system" -eq 1 ]; then
    php_ini="/etc/php/$php_var/fpm/php.ini"
  else
    php_ini=$(php -i | grep "Loaded Configuration File" | awk '{print $5}')
  fi
  echo $php_ini
)

check_system(){
  selinux_enforcing=false
  if command -v apt >/dev/null 2>&1; then
    system=1
  elif command -v dnf >/dev/null 2>&1; then
    if grep -q -Ei "release 7|release 8" /etc/redhat-release; then
      echo -e "${RED}不支援 CentOS 7 或 CentOS 8，請升級至 9 系列 (Rocky/Alma/CentOS Stream)${RESET}"
      exit 1
    fi
    if command -v getenforce >/dev/null 2>&1; then
      if [ "$(getenforce)" == "Enforcing" ]; then
        selinux_enforcing=true
      fi
    fi
    system=2
  elif command -v apk >/dev/null 2>&1; then
    system=3
  else
    echo -e "${RED}不支援的系統。${RESET}"
    exit 1
  fi
}

check_and_start_service() {
  local service_name=""
  
  # 1. 確定服務名稱 (保持不變)
  if command -v openresty >/dev/null 2>&1; then
    service_name="openresty"
  elif command -v nginx >/dev/null 2>&1; then
    service_name="nginx"
  fi

  if [ -n "$service_name" ]; then
    case "$system" in
      1|2)
        if ! systemctl is-active --quiet "$service_name"; then
          systemctl start "$service_name"
        fi
        ;;

      3)
        if service -e "$service_name" >/dev/null 2>&1; then
          if ! service "$service_name" status 2>/dev/null | grep -q 'started'; then
            service "$service_name" start
          fi
        fi
        ;;
    esac
  fi
}

check_web_environment() {
  use_my_app=false
  port_in_use=false
  
  # 檢查端口佔用
  if ss -tln | grep -qE ':(80|443)\s'; then
    port_in_use=true
  fi

  # 判斷是否可用：有 Docker 容器 OR 本機有安裝 binary
  if [ -n "$docker_name" ]; then
    use_my_app=true
  elif command -v nginx >/dev/null 2>&1 || command -v openresty >/dev/null 2>&1 || command -v caddy >/dev/null 2>&1; then
    use_my_app=true
  fi
}

check_cert() {
  local domain="$1"
  local acme_home="$HOME/.acme.sh"
  
  # --- 第一階段：極速模式 (修正版) ---
  if [ -d "$acme_home" ]; then
    local wildcard_domain="*.${domain#*.}"
    local found_conf
    found_conf=$(grep -r -l -e "$domain" -e "$wildcard_domain" "$acme_home" --include="*.conf" 2>/dev/null | head -n 1)

    if [ -n "$found_conf" ]; then
      local le_domain
      le_domain=$(grep "^Le_Domain=" "$found_conf" | cut -d= -f2 | tr -d "'")
      
      if [ -n "$le_domain" ] && [ -f "/etc/letsencrypt/live/$le_domain/fullchain.pem" ]; then
        echo "$le_domain"
        return 0
      fi
    fi
  fi
  
  # --- 第二階段：相容模式 (保持不變，作為備案) ---
  local cert_dir="/etc/letsencrypt/live"
  [ ! -d "$cert_dir" ] && return 1

  for dir in "$cert_dir"/*; do
    [ -d "$dir" ] || continue
    local cert_path="$dir/fullchain.pem"

    if [ -f "$cert_path" ]; then
      local san_list=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null | \
        grep -oE 'DNS:[^,]+' | sed 's/DNS://g')

      for san in $san_list; do
        if [[ "$san" == "$domain" ]] || [[ "$san" == "*.${domain#*.}" ]]; then
          echo "$(basename "$dir")"
          return 0
        fi
      done
    fi
  done

  return 1
}

check_app(){
  local install_list=""
  
  if [ "$system" -eq 2 ] && [ ! -f /etc/fedora-release ]; then
    if [ ! -f /etc/yum.repos.d/epel.repo ]; then
       dnf install -y epel-release
    fi
  fi

  for cmd in wget jq nano openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      install_list+=" $cmd"
    fi
  done

  if ! command -v lsb_release >/dev/null 2>&1; then
      install_list+=" lsb-release"
  fi

  if ! command -v dig >/dev/null 2>&1; then
    case $system in
      1) install_list+=" dnsutils" ;;
      2) install_list+=" bind-utils" ;;
      3) install_list+=" bind-tools" ;;
    esac
  fi

  if ! command -v ss >/dev/null 2>&1; then
    case $system in
      1|3) install_list+=" iproute2" ;;
      2)   install_list+=" iproute" ;;
    esac
  fi

  if [ "$system" -eq 2 ] && [ "$selinux_enforcing" = true ]; then
    if ! command -v semanage >/dev/null 2>&1; then
      install_list+=" policycoreutils-python-utils"
    fi
    if ! command -v getfacl >/dev/null 2>&1; then
      install_list+=" acl"
    fi
  fi

  if [ -n "$install_list" ]; then
    case "$system" in
      1) apt update && apt install -y $install_list ;;
      2) dnf install -y $install_list ;;
      3) apk add $install_list ;;
    esac
  fi
}

check_webserver_install(){
  if [[ $use_my_app = false && $port_in_use = false ]]; then
    while true; do
      clear
      echo "=========站點管理器之安裝網站伺服器=========="
      echo "1. 安裝nginx（支援HTTP3）"
      echo "2. 安裝Openresy（支援LUA）"
      echo "3. 安裝caddy server (個人站適用)"
      read -p "請選擇安裝的伺服器[1-3，預設為2]" choice
      choice=${choice:-2}
      case $choice in
      1)
        install_web_server nginx 
        break
        ;;
      2)
        if [ $system == 1 ]; then
          local codename
          local os=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
          if [[ $os == kali ]]; then
            codename=bookworm
            os=debain
          else
            codename=$(grep -Po 'VERSION="[0-9]+ \(\K[^)]+' /etc/os-release)
          fi
          if ! curl -sf "https://openresty.org/package/$os/dists/${codename}/" >/dev/null; then
            if command -v docker >/dev/null; then
              install_web_server openresty docker
              break
            else
              echo -e "${RED}官方倉庫尚未支援 ${codename}${RESET}"
              sleep 2
            fi
          else
            install_web_server openresty
            break
          fi
        elif [ $system -eq 2 ]; then
          local os=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
          local version=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
          if curl -sf https://openresty.org/package/$os/$version/main >/dev/null; then
            install_web_server openresty
            break
          else
            if command -v docker >/dev/null; then
              install_web_server openresty docker
              break
            else
              echo -e "${RED}官方倉庫尚未支援 ${codename}${RESET}"
              sleep 2
            fi
          fi
        elif [ $system == 3 ]; then
          if curl -sf https://openresty.org/package/alpine/v$(cut -d. -f1,2 /etc/alpine-release)/main >/dev/null; then
            install_web_server openresty
          else
            if command -v docker >/dev/null; then
              install_web_server openresty docker
              break
            else
              install_web_server openresty compile
              break
            fi
          fi
        fi
        ;;
      3)
        if [ $system -eq 3 ]; then
          echo -e "${YELLOW}官方倉庫尚未支援${RESET}"
          sleep 1
        fi
        install_web_server caddy
        break
      esac
    done
  fi
}

check_web_server() {
  openresty=0
  nginx=0
  caddy=0
  docker_name=""
  command -v openresty >/dev/null 2>&1 && openresty=1
  command -v nginx    >/dev/null 2>&1 && nginx=1
  command -v caddy    >/dev/null 2>&1 && caddy=1
  
  if [ -S /var/run/docker.sock ]; then
    local containers
    containers=$(docker ps --format '{{.Names}}')
    if [[ "$containers" =~ "openresty" ]]; then
      openresty=1
      docker_name="openresty"
    elif [[ "$containers" =~ "nginx" ]]; then
      nginx=1
      docker_name="nginx"
    elif [[ "$containers" =~ "caddy" ]]; then
      caddy=1
      docker_name="caddy"
    fi
  fi
}

detect_nginx_conf_paths(){
  local cmd_bin=""
  local conf_path=""

  # --- Docker 模式 ---
  if [ -n "$docker_name" ]; then
    # 判斷容器內的 binary 名稱 (OpenResty 容器內通常也是叫 openresty 或 nginx)
    if [ "$openresty" -eq 1 ]; then
      cmd_bin="openresty"
    elif [ "$nginx" -eq 1 ]; then
      cmd_bin="nginx"
    fi
    
    # 執行 docker exec 取回 config 路徑
    # 注意：這裡拿到的是【容器內路徑】，如果你要編輯，需要確保你的腳本知道對應的 Host 路徑
    conf_path="/etc/nginx/nginx.conf"

  # --- Host 模式 ---
  else
    if [ "$openresty" -eq 1 ]; then
      cmd_bin="openresty"
    elif [ "$nginx" -eq 1 ]; then
      cmd_bin="nginx"
    fi
    conf_path=$($cmd_bin -t 2>&1 | sed -n 's#.*configuration file \([^ ]*\.conf\).*#\1#p' | head -n1)
  fi

  echo "$conf_path"
}
# WordPress備份
# 回傳 wp/flarum/unknown

detect_site_type() {
  local web_root="$1"
  if [[ -f "$web_root/wp-config.php" ]]; then
    echo "wp" 
  elif [[ -f "$web_root/config.php" && -d "$web_root/vendor/flarum" ]]; then
    echo "flarum"
  else
    echo "unknown"
  fi
}

# 多站型備份主函式，$1=wp/flarum，$2=domain
backup_site_type() {
  local type="$1"
  local domain="$2"
  local web_root="/var/www/$domain"
  local backup_dir="/opt/backups/$domain"
  local timestamp=$(date +"%Y%m%d-%H%M%S")
  local backup_file="$backup_dir/backup-$timestamp.tar.gz"
  mkdir -p "$backup_dir"

  # --- 資料庫備份 (DB Backup) ---
  local db_name=""
  local dba_export_dir="/root/mysql_backups"

  if [[ "$type" == "wp" ]]; then
    local wp_config="$web_root/wp-config.php"
    db_name=$(awk -F"'" '/DB_NAME/{print $4}' "$wp_config")
  elif [[ "$type" == "flarum" ]]; then
    local config="$web_root/config.php"
    db_name=$(php -r "\$c = include '$config'; echo \$c['database']['database'] ?? '';")
  else
    echo -e "${RED}不支援的站點類型：$type${RESET}"
    sleep 1
    return 1
  fi
  if [[ -z "$db_name" ]]; then
    echo -e "${RED}無法從設定檔中讀取到資料庫名稱！${RESET}"
    sleep 1
    return 1
  fi
  if ! command -v dba >/dev/null 2>&1; then
    bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh) install_script
  fi 
    
  latest_sql_export=$(dba mysql export "$db_name" "$dba_export_dir")
  if [ $? -ne 0 ]; then
    echo -e "${RED}使用 'dba' 工具備份資料庫失敗！${RESET}"
    sleep 1
    return 1
  fi
  if [[ ! -f "$latest_sql_export" ]]; then
    echo -e "${RED}資料庫備份指令執行成功，但在預期目錄中找不到 SQL 檔案！(${dba_export_dir})${RESET}"
    sleep 1
    return 1
  fi

  echo -e "${GREEN}資料庫已成功匯出至：$latest_sql_export${RESET}"
  tar -czf "$backup_file" \
    --exclude='wp-content/cache' \
    --exclude='wp-content/updraft' \
    --exclude='storage/cache' \
    -C "$web_root" . \
    -C "$(dirname "$latest_sql_export")" "$(basename "$latest_sql_export")"
  rm -f "$latest_sql_export"
  echo -e "${GREEN}備份完成！檔案位置：$backup_file${RESET}"
}

backup_site() {
  local conf_dir=$(detect_conf_path)
  # 取得所有 .conf
  local raw_files=("$conf_dir"/*.conf)
  local site_files=()

  # 過濾掉 basename 不含 "." 的
  for f in "${raw_files[@]}"; do
    local name=$(basename "$f" .conf)
    if [[ "$name" == *.* ]]; then
      site_files+=("$f")
    fi
  done

  if [ ${#site_files[@]} -eq 0 ]; then
    echo -e "${YELLOW}目前沒有任何可備份的站點。${RESET}"
    return 0
  fi

  echo "請選擇要備份的站點："
  local idx=1
  for f in "${site_files[@]}"; do
    local name=$(basename "$f" .conf)
    echo "  $idx) $name"
    idx=$((idx + 1))
  done

  echo
  read -p "請輸入數字：" choice

  # 非數字
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}無效的選擇。${RESET}"
    sleep 1
    return 1
  fi

  local max=${#site_files[@]}
  if (( choice < 1 || choice > max )); then
    echo -e "${RED}選擇超出範圍。${RESET}"
    sleep 1
    return 1
  fi

  local conf_file="${site_files[$((choice - 1))]}"
  local domain=$(basename "$conf_file" .conf)
  local web_root="/var/www/$domain"
  local backup_dir="/opt/wp_backups/$domain"
  mkdir -p "$backup_dir"

  local type=$(detect_site_type "$web_root")

  if [[ "$type" == "unknown" ]]; then
    echo -e "${RED}不支援的站點類型，取消備份。${RESET}"
    sleep 1
    return 1
  fi

  backup_site_type "$type" "$domain" || return 1
  echo -e "${GREEN}備份作業完成${RESET}"
}

clean_ssl_session_cache() {
  [ $caddy -eq 1 ] && return 0
  local paths=$(detect_nginx_conf_paths)
  if [ -f "$paths" ]; then
    # 先計算未註解的 ssl_session_cache 行數
    local count_before count_after
    count_before=$(grep -E '^[[:space:]]*ssl_session_cache' "$paths" | wc -l)
    # 刪除未註解的 ssl_session_cache 行（前面不能有 # 和任意空白）
    sed -i '/^[[:space:]]*ssl_session_cache[[:space:]]/d' "$paths"
    count_after=$(grep -E '^[[:space:]]*ssl_session_cache' "$paths" | wc -l)
    if [ "$count_before" -gt "$count_after" ]; then
      echo -e "${GREEN}已清除 $file 中的 ssl_session_cache 設定${RESET}"
    fi
  fi
}

check_http3_support() {
  support_http3=false
  local check_cmd=""

  # --- Docker 模式 ---
  if [ -n "$docker_name" ]; then
    if [ "$openresty" -eq 1 ]; then
      check_cmd="docker exec $docker_name openresty"
    elif [ "$nginx" -eq 1 ]; then
      check_cmd="docker exec $docker_name nginx"
    fi

  # --- Host 模式 ---
  else
    if command -v openresty >/dev/null 2>&1; then
      check_cmd=$(command -v openresty)
    elif command -v nginx >/dev/null 2>&1; then
      check_cmd=$(command -v nginx)
    fi
  fi

  # 如果找不到執行命令的方式，直接回傳
  [ -z "$check_cmd" ] && echo "$support_http3" && return

  # 執行檢查 (由 host 或 docker exec 執行)
  if $check_cmd -V 2>&1 | grep -q -- '--with-http_v3_module'; then
    support_http3=true
  fi
  
  echo "$support_http3"
}

check_nginx(){
  check_web_environment
  if [[ $use_my_app = false && $port_in_use = true ]]; then
    echo -e "${RED}偵測到您的系統已安裝其他 Web Server，或 80/443 端口已被佔用。${RESET}"
    echo -e "${YELLOW}請手動停止或解除安裝相關服務，例如 apache、Caddy 或其他佔用程式。${RESET}"
    read -n1 -r -p "請處理完畢後再繼續，按任意鍵結束..." _
    return 1
  elif [[ $use_my_app = false && $port_in_use = false ]]; then
    check_web_server
  else
    echo -e "${YELLOW}您已成功安裝，不用重複安裝${RESET}"
    sleep 1
  fi
}

check_acme(){
  [ $caddy -eq 1 ] && return 0
  
  # 【修正】直接檢查執行檔是否存在，這是最可靠的方法
  if [ -f "$HOME/.acme.sh/acme.sh" ]; then
    [ -f "$HOME/.acme.sh/acme.sh.env" ] && . "$HOME/.acme.sh/acme.sh.env"
    return 0
  fi

  # --- 如果上面沒找到，才執行安裝 ---
  local user_email
  read -p "請輸入您的 Email (用於證書過期通知，可留空自動生成): " user_email
  # 如果為空，給一個隨機的，避免用你自己的 Email
  if [ -z "$user_email" ]; then
    user_email="admin@$(hostname).local"
    echo "使用默認 Email: $user_email"
  fi
  
  # 執行安裝
  curl https://get.acme.sh | sh -s email="$user_email"
  if [ $? -ne 0 ]; then
    echo -e "${RED}acme.sh 安裝失敗，請檢查網路或 curl。${RESET}"
    return 1
  fi
  
  # 安裝完後，手動載入一次環境，讓後續指令能立刻生效
  . "$HOME/.acme.sh/acme.sh.env"
  ln -s "$HOME/.acme.sh/acme.sh" /usr/local/bin/acme.sh
  
  # 設定自動升級與預設 CA
  acme.sh --upgrade --auto-upgrade
  acme.sh --set-default-ca --server letsencrypt
}

check_php(){
  if ! command -v php >/dev/null 2>&1; then
    php_install
    sleep 5
    php_fix
  fi
}

check_flarum_supported_php() {
  local versions
  local valid_versions=()
  local base_url="https://github.com/flarum/installation-packages/raw/main/packages/v1.x"

  case $system in
    1) # Debian/Ubuntu
      versions=$(apt-cache search ^php[0-9.]+$ | grep -oP '^php\K[0-9.]+' | awk -F. '$1 >= 8 {print}' | sort -Vr)
      ;;
    2) # CentOS
      versions=$(dnf module list php | grep -E '^php\s+(remi-)?8\.[0-9]+' | awk '{print $2}' | sed 's/remi-//' | sort -Vu | xargs)
      ;;
    3) # Alpine
      versions=$(apk search -x php[0-9]* | grep -oE 'php[0-9]+' | sed 's/php//' | sort -u | awk '{printf "8.%d\n", $1 - 80}' | sort -Vr)
      ;;
  esac

  for ver in $versions; do
    url="$base_url/flarum-v1.x-no-public-dir-php$ver.zip"
    if curl -s -I "$url" | grep -q '^HTTP/.* 302'; then
      valid_versions+=("$ver")
    fi
  done

  if [[ ${#valid_versions[@]} -eq 0 ]]; then
    echo "${RED}沒有任何版本符合 Flarum 安裝包${RESET}"
    return 1
  fi

  echo "${valid_versions[*]}"
}


create_directories() {
  [ $caddy -eq 1 ] && return 0
  mkdir -p /home/web/cert
  mkdir -p /etc/nginx/conf.d/
  mkdir -p /var/www
}
chown_set(){
  local ngx_user=$(get_web_run_user)
  case $system in
    1|2)
      mkdir -p /run/php
      chown -R $ngx_user:$ngx_user /run/php
      chmod 755 /run/php
      ;;
    3)
      mkdir -p /run/php
      chown $ngx_user:$ngx_user /run/php
      chmod 755 /run/php
      rc-service php-fpm83 restart
      ;;
  esac
}

check_no_ngx(){
  check_web_environment
  if [[ $use_my_app != true ]]; then
    echo -e "${RED}您好,您現在使用其他web server 無法使用此功能${RESET}"
    read -p "操作完成,請按任意鍵..." -n1
    return 1
  fi
}

check_php_version() {
  case "$system" in
    1)
      if command -v php >/dev/null 2>&1; then
        phpver=$(php -v | head -n1 | grep -oP '\d+\.\d+')
        echo "$phpver" 
      else
        echo -e "${RED}PHP 尚未安裝。${RESET}" >&2
        return 1
      fi
      ;;
    2) 
      if command -v php >/dev/null 2>&1; then
        phpver=$(php -v | head -n1 | grep -oP '\d+\.\d+')
        echo "$phpver" # ex 8.3
      else
        echo -e "${RED}PHP 尚未安裝。${RESET}" >&2
        return 1
      fi
      ;;
    3)
      if command -v php >/dev/null 2>&1; then
        local rawver=$(php -v | head -n1 | grep -oE '[0-9]+\.[0-9]+')  # 使用 -E（延伸正規表示式）
        alpver=$(echo "$rawver" | tr -d '.')
        echo "$alpver" #出現83
      else
        echo -e "${RED}PHP 尚未安裝。${RESET}" >&2
        return 1
      fi
      ;;
  esac
}

check_php_ext_available() {
  local ext_name="$1"
  local phpver="$2"  # e.g., "8.2"
  local shortver=$(echo "$phpver" | tr -d '.')

  case "$system" in
    1)  # Debian / Ubuntu (APT)
      apt-cache show "php$phpver-$ext_name" &>/dev/null && return 0
      ;;

    2)  # CentOS / RHEL / AlmaLinux / Rocky (dnf + Remi)
      dnf --quiet list available "php-$ext_name" &>/dev/null && return 0
      dnf --quiet list available "php-pecl-$ext_name" &>/dev/null && return 0
      ;;

    3)  # Alpine (APK)
      apk search "php$shortver-$ext_name" | grep -q "^php$shortver-$ext_name" && return 0
      ;;
  esac

  return 1
}
cf_cert_autogen() (
  key_file="/ssl_ca/.cf_origin.key"
  enc_file="/ssl_ca/.cf_origin.enc"

  echo "===== Cloudflare Origin 憑證自動申請器 ====="
  echo "感謝NS論壇之bananapork提供的cf文檔"

  # 1. 檢查加密檔案
  if [ ! -f "$key_file" ] || [ ! -f "$enc_file" ]; then
    echo -e "${YELLOW}尚未設定帳號資訊，請輸入：${RESET}"
    read -p "Cloudflare 登入信箱: " cf_email
    read -p "Global API Key（將加密儲存）: " -s cf_key
    echo

    mkdir -p "$(dirname "$key_file")"
    head -c 32 /dev/urandom > "$key_file"
    chmod 600 "$key_file"

    echo "$cf_email:$cf_key" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:"$key_file" -out "$enc_file"
    chmod 600 "$enc_file"
    echo -e "${GREEN}Cloudflare 認證資料已加密儲存${RESET}"
  fi

  # 2. 解密帳號資訊
  cf_cred=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$key_file" -in "$enc_file")
  cf_email="$(echo "$cf_cred" | cut -d':' -f1)"
  cf_api_key="$(echo "$cf_cred" | cut -d':' -f2)"

  # 3. 讀取用戶輸入的任何子域名
  while true; do
    read -p "請輸入你擁有的主域名（如 xxx.eu.org 或 xxx.com）: " input_domain
    if [[ "$input_domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      echo -e "${YELLOW}請輸入正確格式的域名（不可含 http/https/空格）${RESET}"
    fi
  done
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
    -H "X-Auth-Email: $cf_email" \
    -H "X-Auth-Key: $cf_api_key" \
    -H "Content-Type: application/json")
  all_zones=$(echo "$response" | jq -r '.result[].name')
  base_domain=""
  for zone in $all_zones; do
    if [[ "$input_domain" == *"$zone" ]]; then
      base_domain="$zone"
      break
    fi
  done
  if [ -z "$base_domain" ]; then
    echo -e "${RED}找不到與 $input_domain 對應的根域名，請確認該域名是否在你帳號內託管。${RESET}"
    sleep 1
    return 1
  fi
  le_dir="/etc/letsencrypt/live/$base_domain"
  mkdir -p "$le_dir"
  cd "$le_dir"

  openssl req -new -newkey rsa:2048 -nodes \
    -keyout privkey.pem \
    -out domain.csr \
    -subj "/CN=$base_domain"
  csr_content=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' domain.csr)
  response=$(curl -s -X POST https://api.cloudflare.com/client/v4/certificates \
    -H "Content-Type: application/json" \
    -H "X-Auth-Email: $cf_email" \
    -H "X-Auth-Key: $cf_api_key" \
    -d "{
      \"hostnames\": [\"$base_domain\", \"*.$base_domain\"],
      \"requested_validity\": 5475,
      \"request_type\": \"origin-rsa\",
      \"csr\": \"$csr_content\"
    }")

  if echo "$response" | grep -q '"success":true'; then
    echo "$response" | jq -r '.result.certificate' > cert.pem
    cat cert.pem > fullchain.pem
    local cert_id=$(echo "$response" | jq -r '.result.id')
    echo "$cert_id" > cf_cert_id.txt
    echo -e "${GREEN}成功！憑證已儲存於：$le_dir${RESET}"
    echo "- cert.pem"
    echo "- fullchain.pem"
    echo "- privkey.pem"
  else
    echo -e "${RED}憑證申請失敗，錯誤如下：${RESET}"
    echo "$response" | jq
    sleep 9
  fi
)

cf_cert_revoke() (
  input_domain="$1"
  key_file="/ssl_ca/.cf_origin.key"
  enc_file="/ssl_ca/.cf_origin.enc"
  cf_cred=""
  cf_api_key=""
  cf_email=""
    

  echo "===== Cloudflare Origin 憑證吊銷器 ====="

  if [ ! -f "$key_file" ] || [ ! -f "$enc_file" ]; then
    echo -e "${RED}尚未設定 Cloudflare 認證資料，請先執行申請功能${RESET}"
    sleep 1
    return 1
  fi

  # 解密認證資料
  cf_cred=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$key_file" -in "$enc_file")
  cf_email="$(echo "$cf_cred" | cut -d':' -f1)"
  cf_api_key="$(echo "$cf_cred" | cut -d':' -f2)"

  # 輸入主域名
  if [ -z "$input_domain" ]; then 
    while true; do
      read -p "請輸入你想吊銷憑證的主域名（如 example.com）: " input_domain
      if [[ "$input_domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        break
      else
        echo -e "${YELLOW} 請輸入正確格式的域名${RESET}"
      fi
    done
  fi

  le_dir="/etc/letsencrypt/live/$input_domain"
  cert_id_file="$le_dir/cf_cert_id.txt"

  if [ ! -f "$cert_id_file" ]; then
    echo -e "${RED} 找不到本地憑證 ID ($cert_id_file)，無法吊銷${RESET}"
    sleep 1
    return 1
  fi
  certificate_id=$(cat "$cert_id_file")

  read -p "確定要吊銷 Cloudflare Origin 憑證 ID [$certificate_id] 嗎？(y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    revoke_response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/certificates/$certificate_id" \
      -H "X-Auth-Email: $cf_email" \
      -H "X-Auth-Key: $cf_api_key" \
      -H "Content-Type: application/json")

    if echo "$revoke_response" | grep -q '"success":true'; then
      echo -e "${GREEN}Cloudflare Origin 憑證已成功吊銷${RESET}"
      rm -f "$le_dir/cert.pem" "$le_dir/fullchain.pem" "$le_dir/privkey.pem" "$cert_id_file"
    else
      echo -e "${RED}吊銷失敗，回傳如下：${RESET}"
      echo "$revoke_response" | jq
    fi
  fi
)

change_wp_admin_username() {
  local domain="$1"
  local site_path="/var/www/$domain"

  # 確認 WordPress 路徑
  if [ ! -f "$site_path/wp-config.php" ]; then
    echo -e "${RED}找不到 WordPress 安裝路徑：$site_path${RESET}"
    return 1
  fi

  # 取得管理員用戶名列表
  mapfile -t admins < <(wp --skip-plugins --skip-themes --allow-root --path="$site_path" user list --role=administrator --field=user_login)

  if [ ${#admins[@]} -eq 0 ]; then
    echo -e "${RED}沒有找到管理員用戶${RESET}"
    return 1
  fi

  local selected_admin=""
  if [ ${#admins[@]} -eq 1 ]; then
    selected_admin="${admins[0]}"
    echo "只有一個管理員用戶：$selected_admin"
  else
    echo "請選擇要修改的管理員用戶："
    select admin in "${admins[@]}"; do
      if [ -n "$admin" ]; then
        selected_admin="$admin"
        break
      else
        echo "請輸入有效選項"
      fi
    done
  fi

  read -p "請輸入新的管理員使用者名稱：" new_username
  if [ -z "$new_username" ]; then
    echo -e "${RED}新用戶名不可為空，取消修改${RESET}"
    return 1
  fi

  # 確認新用戶名是否已存在
  if wp --skip-plugins --skip-themes --allow-root --path="$site_path" user get "$new_username" >/dev/null 2>&1; then
    echo -e "${RED} 新用戶名已存在，請換一個${RESET}"
    return 1
  fi

  # 用 SQL 方式修改用戶名（因為 wp-cli 沒有直接修改用戶名指令）
  local sql="UPDATE wp_users SET user_login='${new_username}' WHERE user_login='${selected_admin}';"
  wp --skip-plugins --skip-themes --allow-root --path="$site_path" db query "$sql"

  echo -e "${GREEN}管理員使用者名稱已從 '$selected_admin' 修改為 '$new_username'${RESET}"
}

change_wp_admin_password() {
  local domain="$1"
  local site_path="/var/www/$domain"
  
  # 確認 WordPress 路徑
  if [ ! -f "$site_path/wp-config.php" ]; then
    echo "${RED}找不到 WordPress 安裝路徑：$site_path${RESET}"
    return 1
  fi

  # 取得管理員用戶名列表
  mapfile -t admins < <(wp --skip-plugins --skip-themes --allow-root --path="$site_path" user list --role=administrator --field=user_login)

  if [ ${#admins[@]} -eq 0 ]; then
    echo -e "${RED}沒有找到管理員用戶${RESET}"
    return 1
  fi

  local selected_admin=""
  if [ ${#admins[@]} -eq 1 ]; then
    selected_admin="${admins[0]}"
    echo "只有一個管理員用戶：$selected_admin"
  else
    echo "請選擇要修改密碼的管理員用戶："
    select admin in "${admins[@]}"; do
      if [ -n "$admin" ]; then
        selected_admin="$admin"
        break
      else
        echo "請輸入有效選項"
      fi
    done
  fi

  # 輸入新密碼（隱藏輸入）
  read -s -p "請輸入新的密碼：" new_password
  echo
  if [ -z "$new_password" ]; then
    echo -e "${RED} 密碼不可為空，取消修改${RESET}"
    return 1
  fi

  read -s -p "請再輸入一次新的密碼以確認：" confirm_password
  echo
  if [ "$new_password" != "$confirm_password" ]; then
    echo -e "${RED}兩次輸入的密碼不一致，取消修改${RESET}"
    return 1
  fi

  # 修改密碼
  wp --skip-plugins --skip-themes --allow-root --path="$site_path" user update "$selected_admin" --user_pass="$new_password" --skip-email

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}管理員 '$selected_admin' 的密碼已更新成功${RESET}"
  else
    echo -e "${RED}密碼更新失敗${RESET}"
    return 1
  fi
}


clean_nginx_ssl_config() {
  conf_path=$(detect_conf_path)

  # 遍歷所有 conf 檔
  find "$conf_path" -type f -name "*.conf" | while read -r file; do

    # 刪掉常見 SSL/TLS 設定行
    sed -i \
      -e '/^\s*ssl_protocols/d' \
      -e '/^\s*ssl_ciphers/d' \
      -e '/^\s*ssl_prefer_server_ciphers/d' \
      -e '/^\s*ssl_session_cache/d' \
      -e '/^\s*ssl_session_timeout/d' \
    "$file"
  done
  restart_webserver
}

default(){
  local mode=$1
  local detect_conf_path=$(detect_conf_path)
  local ngx_conf=$(detect_nginx_conf_paths)
  create_directories
  generate_ssl_cert
  if [[ "$docker_name" == "openresty" || "$docker_name" == "nginx" ]]; then
    mkdir -p /var/log/openresty/logs
    touch /var/log/openresty/error.log
    touch /var/log/openresty/access.log
    case $system in
    1|2)  id -u nginx &>/dev/null || (groupadd -g 1689 nginx && useradd -u 1689 -g 1689 -s /sbin/nologin -M nginx) ;;
    3)  id -u nginx &>/dev/null || (addgroup -g 1689 nginx && adduser -u 1689 -G nginx -D -H -s /sbin/nologin nginx) ;;
    esac
    wget -qO $ngx_conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/nginx.conf
    wget -qO $detect_conf_path/default.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/default_system
    sed -i 's|include /etc/nginx/conf.d/\*.conf;|include /usr/local/openresty/nginx/conf/conf.d/*.conf;|' "$ngx_conf"
    return 0
  fi
  case "$system" in
  1|2)
    if [ $mode == openresty ]; then
      rm -f $ngx_conf
      wget -O $ngx_conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/nginx.conf
      id -u nginx &>/dev/null || useradd -r -s /sbin/nologin -M nginx
      wget -O $detect_conf_path/default.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/default_system
    fi
    if [ $mode == caddy ]; then
      rm -f /etc/caddy/Caddyfile
      wget -O /etc/caddy/Caddyfile https://gitlab.com/gebu8f/sh/-/raw/main/nginx/caddy/Caddyfile
      mkdir -p /etc/caddy/conf.d
    else
      rm -f $detect_conf_path/default.conf $detect_conf_path/default
      wget -O $detect_conf_path/default.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/default_system
    fi
    restart_webserver
    ;;
  3)
    if [ $mode == openresty ]; then
      id -u nginx &>/dev/null || adduser -D -H -s /sbin/nologin nginx
    fi
    # download default
    rm -f $detect_conf_path/default.conf
    rm -f $ngx_conf
    wget -O $ngx_conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/nginx.conf
    wget -O $detect_conf_path/default.conf https://gitlab.com/gebu8f/sh/-/raw/main/nginx/default_system
    restart_webserver
    ;;
  esac
}

detect_conf_path() {
  if [ -n "$docker_name" ]; then
  
    local docker_host_vhost_path="/etc/nginx/conf.d"
    
    # 確保這個目錄在宿主機上存在，如果不存在就建立它
    mkdir -p "$docker_host_vhost_path"
    
    # 直接回傳此固定路徑，並結束函數，不再執行後面的 Host 檢測邏輯
    echo "$docker_host_vhost_path"
    return 0
  fi

  # --- 以下為 Host 原生環境處理 (維持你原本的邏輯不變) ---
  
  local conf=""
  local default_conf_dir=""
  
  if command -v openresty >/dev/null 2>&1 || command -v nginx >/dev/null 2>&1; then
    # 在 Host 模式下，呼叫 detect_nginx_conf_paths 來取得主設定檔路徑
    conf=$(detect_nginx_conf_paths)
  elif command -v caddy >/dev/null 2>&1; then
    conf="/etc/caddy/Caddyfile"
  fi

  # Caddy 的處理邏輯 (不變)
  if command -v caddy >/dev/null 2>&1; then
    local import_line
    import_line=$(grep -E '^[[:space:]]*import[[:space:]]+/' "$conf" | grep '\*' | head -n 1)

    if [[ -n "$import_line" ]]; then
      local path
      path=$(echo "$import_line" | sed -E 's/^[[:space:]]*import[[:space:]]+([^*]+)\*.*/\1/')
      path="${path%/}"

      echo "$path"
      return 0
    fi

    default_conf_dir="/etc/caddy/conf.d"
    mkdir -p "$default_conf_dir"
    echo "" >> "$conf"
    echo "import ${default_conf_dir}/*" >> "$conf"
    restart_webserver
    echo "$default_conf_dir"
    return 0
  fi

  # Nginx / OpenResty 在 Host 上的處理邏輯 (不變)
  local search_regex='^[[:space:]]*include[[:space:]]+([^;]*\*[^;]*);'
  # 從主設定檔中尋找 include xxx/*.conf; 這樣的行
  local included_path=$(sed -E -n "s/${search_regex}/\1/p" "$conf" | head -n 1)

  if [[ -n "$included_path" ]]; then
    local target_dir
    target_dir=$(dirname "$included_path")
    mkdir -p "$target_dir"
    echo "$target_dir"
    return 0
  fi

  # 如果在主設定檔中找不到 include，則使用預設路徑
  if command -v openresty >/dev/null 2>&1; then
    # OpenResty 的預設路徑
    default_conf_dir="/usr/local/openresty/nginx/conf/conf.d"
  else
    # Nginx 的預設路徑
    default_conf_dir="/etc/nginx/conf.d"
  fi

  mkdir -p "$default_conf_dir"

  # 檢查主設定檔是否已經包含了這個預設目錄，如果沒有就自動加上
  if ! grep -qE "include[[:space:]]+${default_conf_dir}/\*\.conf;" "$conf"; then
    sed -i "/^http[[:space:]]*{/,/^}/ {
      /^}/i\\    include ${default_conf_dir}/*.conf;
    }" "$conf" 2>/dev/null
    
    restart_webserver
  fi

  echo "$default_conf_dir"
  return 0
}
detect_sites() {
  local app_type="$1"
  local base_dir="/var/www"

  for dir in "$base_dir"/*; do
    [ ! -d "$dir" ] && continue

    case "$app_type" in
      WordPress)
        if [ -f "$dir/wp-config.php" ]; then
          echo "$(basename "$dir")"
        fi
        ;;
      Flarum)
        if [ -f "$dir/flarum" ] || [ -f "$dir/site.php" ] || [ -d "$dir/vendor/flarum" ]; then
          echo "$(basename "$dir")"
        fi
        ;;
    esac
  done
}

detect_sites_menu() {
  local app_type="$1"
  local base_dir="/var/www"
  local sites=()
  for dir in "$base_dir"/*; do
    [ ! -d "$dir" ] && continue

    case "$app_type" in
      WordPress)
        [ -f "$dir/wp-config.php" ] && sites+=("$(basename "$dir")")
        ;;
      Flarum)
        [ -f "$dir/flarum" ] || [ -f "$dir/site.php" ] || [ -d "$dir/vendor/flarum" ] && \
          sites+=("$(basename "$dir")")
        ;;
      *)
        echo -e "${RED}暫不支援偵測此應用：$app_type${RESET}" >&2
        return 1
        ;;
    esac
  done

  if [ ${#sites[@]} -eq 0 ]; then
    echo -e "${RED}未偵測到任何 $app_type 網站${RESET}" >&2
    return 1
  fi

  if ! [ -t 0 ]; then
    echo -e "${RED}非交互式環境，無法使用選單${RESET}" >&2
    return 1
  fi

  echo "請選擇欲操作的 $app_type 網站：" >&2
  select site in "${sites[@]}"; do
    if [ -n "$site" ]; then
      echo "$site"
      return 0
    else
      echo -e "${YELLOW}請輸入有效的編號${RESET}" >&2
    fi
  done
}

deploy_or_remove_theme() {
  local action="$1"           # install or remove
  local domain="$2"           # 網址 (如 aa.com)

  local site_path="/var/www/$domain"
  local wp_theme_dir="$site_path/wp-content/themes"
  local wp_cli="wp --skip-plugins --skip-themes --allow-root"

  # 確保 wp-cli 存在
  if ! command -v wp >/dev/null 2>&1; then
    echo -e "${RED}找不到 wp-cli，可先執行 install_wp_cli${RESET}"
    return 1
  fi

  # 確保路徑存在
  if [ ! -d "$wp_theme_dir" ]; then
    echo -e "${RED}找不到 WordPress themes 目錄：$wp_theme_dir${RESET}"
    return 1
  fi

  case "$action" in
    install)
      read -p "請輸入主題名稱或下載 URL：" theme_input
      if [ -z "$theme_input" ]; then
        echo -e "${RED}未輸入任何主題名稱或 URL，取消安裝${RESET}"
        return 1
      fi

      if [[ "$theme_input" =~ ^https?:// ]]; then
        # 是網址，先下載
        tmp_file="/tmp/theme_download.$(date +%s)"
        echo -e "${CYAN}正在下載主題：$theme_input${RESET}"
        curl -L "$theme_input" -o "$tmp_file" || {
          echo -e "${RED}無法下載 $theme_input${RESET}"
          return 1
        }

        # 解壓縮
        case "$theme_input" in
          *.zip)
            unzip -q "$tmp_file" -d "$wp_theme_dir" || {
              echo -e "${RED}解壓縮失敗${RESET}"
              rm -f "$tmp_file"
              return 1
            }
            ;;
          *.tar.gz|*.tgz)
            tar -xzf "$tmp_file" -C "$wp_theme_dir" || {
              echo -e "${RED}解壓縮失敗${RESET}"
              rm -f "$tmp_file"
              return 1
            }
            ;;
          *.tar)
            tar -xf "$tmp_file" -C "$wp_theme_dir" || {
              echo -e "${RED}解壓縮失敗${RESET}"
              rm -f "$tmp_file"
              return 1
            }
            ;;
          *)
            echo -e "${RED}不支援的壓縮格式：$theme_input${RESET}"
            rm -f "$tmp_file"
            return 1
            ;;
        esac

        echo -e "${GREEN}主題已部署到 $wp_theme_dir${RESET}"
        rm -f "$tmp_file"

      else
        # 非網址 → 當作主題名稱 → wp-cli 搜尋
        echo -e "${CYAN}正在搜尋主題：$theme_input${RESET}"

        mapfile -t themes < <(
          $wp_cli --path="$site_path" theme search "$theme_input" --per-page=10 --format=json \
          | jq -r '.[] | "\(.name)|\(.slug)"'
        )

        if [ ${#themes[@]} -eq 0 ]; then
          echo -e "${RED}找不到任何與 \"$theme_input\" 相關的主題${RESET}"
          return 1
        fi

        local options=()
        local slugs=()

        for entry in "${themes[@]}"; do
          name="${entry%%|*}"
          slug="${entry##*|}"
          [ -n "$slug" ] && options+=("$name (slug: $slug)") && slugs+=("$slug")
        done

        echo "請選擇要安裝的主題："
        select opt in "${options[@]}"; do
          if [ -n "$opt" ]; then
            idx=$((REPLY - 1))
            slug="${slugs[$idx]}"
            echo -e "${CYAN}正在安裝主題：$slug${RESET}"
            $wp_cli --path="$site_path" theme install "$slug" --activate
            echo -e "${GREEN}已安裝並啟用主題：$slug${RESET}"
            return 0
          else
            echo -e "${RED}無效的選項，請重新選擇${RESET}"
          fi
        done
      fi
      ;;

    remove)
      echo "正在偵測已安裝的主題..."

      mapfile -t themes < <(
        $wp_cli --path="$site_path" theme list --status=active,inactive --format=json \
        | jq -r '.[] | "\(.name)|\(.status)|\(.slug)"'
      )

      if [ ${#themes[@]} -eq 0 ]; then
        echo -e "${YELLOW}尚未安裝任何主題${RESET}"
        return 0
      fi

      local options=()
      local slugs=()

      for theme in "${themes[@]}"; do
        name=$(echo "$theme" | cut -d'|' -f1)
        status=$(echo "$theme" | cut -d'|' -f2)
        slug=$(echo "$theme" | cut -d'|' -f3)

        options+=("$name [$status]")
        slugs+=("$slug")
      done

      echo "請選擇要移除的主題："
      select opt in "${options[@]}"; do
        if [ -n "$opt" ]; then
          idx=$((REPLY - 1))
          slug="${slugs[$idx]}"

          echo -e "${CYAN}正在移除主題：$slug${RESET}"
          $wp_cli --path="$site_path" theme delete "$slug"
          echo -e "${GREEN}已移除主題：$slug${RESET}"
          return 0
        else
          echo -e "${RED}無效的選項，請重新選擇${RESET}"
        fi
      done
      ;;

    *)
      echo -e "${RED}不支援的操作：$action${RESET}"
      return 1
      ;;
  esac
}

flarum_setup() {
  local php_var=$(check_php_version)
  local supported_php_versions=$(check_flarum_supported_php)
  local max_supported_php=$(echo "$supported_php_versions" | tr ' ' '\n' | sort -V | tail -n1)
  local ngx_user=$(get_web_run_user)
  local php_ini=$(phpini_path)

  # 判斷 PHP 是否高於支援版本
  if [ "$(printf '%s\n' "$php_var" "$max_supported_php" | sort -V | tail -n1)" != "$php_var" ]; then
    echo -e "${YELLOW}您目前使用的 PHP 版本是 $php_var，但 Flarum 僅建議使用到 $max_supported_php。${RESET}"
    read -p "是否仍要繼續安裝？(y/N)：" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 1
  fi
  # 根據是否支援決定使用哪個 zip 檔
  if echo "$supported_php_versions" | grep -qw "$php_var"; then
    local download_phpver="$php_var"
  else
    echo -e "${YELLOW}您選擇的 PHP 版本不在 Flarum 支援列表，因為實測發現很不穩定，故禁止安裝${RESET}"
    sleep 3
    return 1
  fi

  if ! command -v dba >/dev/null 2>&1; then
    bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh) install_script
  fi
  if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
    dba mysql install true
  fi

  if ! command -v composer &>/dev/null; then
    echo "正在安裝 Composer..."
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
  fi

  read -p "請輸入您的Flarum網址（例如 bbs.example.com）：" domain

  # 自動申請 SSL（若不存在）
  check_cert "$domain" || {
    echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
    if ssl_apply "$domain"; then
      echo "申請成功，重新驗證憑證..."
      check_cert "$domain" || {
        echo "申請成功但仍無法驗證憑證，中止建立站點"
        return 1
      }
    else
      echo "SSL 申請失敗，中止建立站點"
      return 1
    fi
  }
  local db_name="flarum_$(echo $domain | sed 's/\./_/g; s/-//g')"
  local db_user="${db_name}_user"
  local db_pass=$(dba mysql add $db_name $db_user false)

  # 下載 Flarum
  mkdir -p /var/www/$domain
  wget "https://github.com/flarum/installation-packages/raw/main/packages/v1.x/flarum-v1.x-no-public-dir-php$download_phpver.zip" -O /tmp/flarum.zip
  mkdir -p /tmp/flarum
  unzip /tmp/flarum.zip -d /tmp/flarum
  cp -a /tmp/flarum/. /var/www/$domain/
  rm -rf /tmp/flarum.zip /tmp/flarum
  cd "/var/www/$domain"

  export COMPOSER_ALLOW_SUPERUSER=1
  composer install --no-dev --no-interaction
  composer require --no-interaction flarum-lang/chinese-traditional
  composer require --no-interaction flarum-lang/chinese-simplified
  php flarum cache:clear
  echo "已安裝繁體與簡體中文語系，可至 Flarum 後台 Extensions 啟用。"

  rhel_selinux_enforcing_permissions "/var/www/$domain" label
  rhel_selinux_enforcing_permissions "/var/www/$domain" permissions
  setup_site "$domain" flarum
  
  case $system in
  1)
    service php$php_var-fpm restart
    ;;
  2)
    service php-fpm restart
    ;;
  3)
    service php$php_var-fpm restart
    ;;
  esac
  
  echo "===== Flarum 資訊 ====="
  echo "網址：https://$domain"
  echo "資料庫名稱：$db_name"
  echo "資料庫用戶：$db_user"
  echo "資料庫密碼：$db_pass"
  echo "請在安裝介面輸入以上資訊完成安裝。"
  echo "======================="
}

flarum_extensions() {
  read -p "請輸入 Flarum 網址（例如 bbs.example.com）：" flarum_domain

  local site_path="/var/www/$flarum_domain"
  if [ ! -f "$site_path/config.php" ]; then
    echo "此站點並非 Flarum 網站（缺少 config.php）。"
    return 1
  fi

  echo "已偵測為 Flarum 網站：$flarum_domain"
  echo "選擇操作："
  echo "1) 安裝擴展"
  echo "2) 移除擴展"
  read -p "請選擇操作（預設 1）：" action
  action="${action:-1}"

  read -p "請輸入擴展套件名稱（例如 flarum-lang/chinese-traditional）：" ext_name

  cd "$site_path"
  
  if [ "$action" = "1" ]; then
    export COMPOSER_ALLOW_SUPERUSER=1
    composer require --no-interaction "$ext_name"
    php flarum cache:clear
    echo "擴展已安裝並清除快取。請至後台啟用擴展。"
  elif [ "$action" = "2" ]; then
    export COMPOSER_ALLOW_SUPERUSER=1
    composer remove --no-interaction "$ext_name"
    php flarum cache:clear
    echo "擴展已移除並清除快取。"
  else
    echo "無效選項。"
  fi
}


generate_ssl_cert(){
  [ $caddy -eq 1 ] && return 0
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /home/web/cert/default_server.key \
  -out /home/web/cert/default_server.crt \
  -days 5475 \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=Organizational Unit/CN=Common Name" >/dev/null
}

get_web_run_user() {
  # --- 1. 偵測 Nginx ---
  local nginx_conf=$(detect_nginx_conf_paths)

  if [ -n "$nginx_conf" ]; then
    # 讀取 user 行，抓第一個 user 名稱，去掉分號
    local user
    user=$(grep -E '^\s*user\s+' "$nginx_conf" | head -1 | awk '{print $2}' | sed 's/;//')
    if [ -z "$user" ]; then
      user="nobody"
    fi
    echo "$user"
    return 0
  fi

  # --- 2. 偵測 Caddy ---
  local pid=$(ss -ltnp 2>/dev/null | awk '/:(80|443)/ && /users:/{gsub(/.*pid=/,""); gsub(/,.*$/,""); print $NF; exit}')
    
  if [ -n "$pid" ]; then
    local user
    user=$(awk '/^Uid:/ {print $2}' "/proc/$pid/status")
    if [ -n "$user" ]; then
      user=$(getent passwd "$user" | cut -d: -f1)
      echo "$user"
    else
      return 1
    fi
    return 0
  fi
}

html_sites(){
  local ngx_user=$(get_web_run_user)
  read -p "請輸入網址:" domain
  check_cert "$domain" || {
    echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
    if ssl_apply "$domain"; then
      echo "申請成功，重新驗證憑證..."
        check_cert "$domain" || {
          echo "申請成功但仍無法驗證憑證，中止建立站點"
          return 1
        }
    else
      echo "SSL 申請失敗，中止建立站點"
      return 1
    fi
  }
  mkdir -p /var/www/$domain
  local confirm
  read -p "是否自訂html?(Y/n)" confirm
  confirm=${confirm,,}
  if [[ $confirm == y || $confirm == "" ]]; then
    nano /var/www/$domain/index.html
  else
    echo "<h1>歡迎來到 $domain</h1>" > /var/www/$domain/index.html
  fi
  rhel_selinux_enforcing_permissions "/var/www/$domain" permissions
  setup_site "$domain" html
  echo "已建立 $domain 之html站點。"
}
httpguard_setup() {
  [ "$caddy" -eq 1 ] && return 0
  check_php
  
  local guard_dir_host="/etc/nginx/HttpGuard" # 統一宿主機路徑
  local guard_dir_container=""
  local ngx_conf=$(detect_nginx_conf_paths)
  
  # --- 1. 環境檢測與路徑設定 ---
  if [ -n "$docker_name" ]; then
    guard_dir_container="/usr/local/openresty/nginx/conf/HttpGuard"
  else
    case $system in
      1|2)
        [ ! -x "$(command -v openresty)" ] && { echo "未偵測到 openresty"; return 1; }
        guard_dir_host="/usr/local/openresty/nginx/conf/HttpGuard"
        guard_dir_container="/usr/local/openresty/nginx/conf/HttpGuard"
        ;;
      3)
        [ ! -x "$(command -v nginx)" ] && { echo "未偵測到 nginx"; return 1; }
        guard_dir_container="/etc/nginx/HttpGuard"
        ;;
    esac
  fi

  if [ -f "$guard_dir_host/config.lua" ]; then
    menu_httpguard; return 0
  fi

  local tmp_zip="/tmp/HttpGuard.zip"
  local tmp_dir="/tmp/httpguard_unpack"
  mkdir -p "$tmp_dir"
  wget -qO "$tmp_zip" https://files.gebu8f.com/site/HttpGuard.zip || return 1
  unzip -qo "$tmp_zip" -d "$tmp_dir"

  # 判斷裡面有沒有多一層 HttpGuard 目錄，有的話就平鋪移動
  rm -rf "$guard_dir_host"
  if [ -d "$tmp_dir/HttpGuard" ]; then
    mv "$tmp_dir/HttpGuard" "$guard_dir_host"
  else
    mkdir -p "$guard_dir_host"
    mv "$tmp_dir"/* "$guard_dir_host/"
  fi
  rm -rf "$tmp_dir" "$tmp_zip"

  # --- 3. 配置修正與驗證碼生成 ---
  sed -i "s|^baseDir *=.*|baseDir = '${guard_dir_container}/'|" "$guard_dir_host/config.lua"
  local ss_cmd=""
  if [ -n "$docker_name" ]; then
    ss_cmd=$(docker exec "$docker_name" which ss 2>/dev/null | tr -d '\r')
    [ -z "$ss_cmd" ] && ss_cmd="/usr/sbin/ss"
  else
    ss_cmd=$(command -v ss 2>/dev/null || echo "/usr/sbin/ss")
  fi
  sed -i "s|ssCommand *= *\"[^\"]*\"|ssCommand = \"$ss_cmd\"|" "$guard_dir_host/config.lua"

  echo "正在生成驗證碼圖檔..."
  (cd "$guard_dir_host/captcha" && php getImg.php)
  chown -R nginx:nginx "$guard_dir_host"

  # --- 4. 緊湊插入配置到 nginx.conf (關鍵修正) ---
  echo "正在注入配置到 $ngx_conf..."
  
  # 根據環境準備 Lua 路徑
  local lualib_path="/usr/local/openresty/lualib"
  [ -z "$docker_name" ] && [ "$system" -eq 3 ] && lualib_path="/usr/local/share/lua/5.1"
  local luaso_path="/usr/local/openresty/lualib"
  [ -z "$docker_name" ] && [ "$system" -eq 3 ] && luaso_path="/usr/local/lib/lua/5.1"

  # 建立一個暫存檔來存放要插入的內容，確保沒有空行
  local tmp_block="/tmp/lua_block.tmp"
  cat > "$tmp_block" <<EOF
    lua_package_path "$lualib_path/?.lua;${guard_dir_container}/?.lua;;";
    lua_package_cpath "$luaso_path/?.so;;";
    lua_shared_dict guard_dict 100m;
    lua_shared_dict dict_captcha 8m;
    init_by_lua_file ${guard_dir_container}/init.lua;
    access_by_lua_file ${guard_dir_container}/runtime.lua;
    lua_max_running_timers 1;
EOF

  sed -i "/http {/r $tmp_block" "$ngx_conf"
  rm -f "$tmp_block"

  # --- 5. 重啟與測試 ---
  if restart_webserver; then
    echo "HttpGuard 安裝完成"
    menu_httpguard
  else
    echo "配置測試失敗，請手動檢查 $ngx_conf"
    return 1
  fi
}

install_wp_plugin_with_search_or_url() {
  local domain="$1"
  local site_path="/var/www/$domain"
  local plugin_dir="$site_path/wp-content/plugins"

  read -p "請輸入插件關鍵字 或 ZIP 下載網址: " input
  [ -z "$input" ] && echo -e "${RED}未輸入內容${RESET}" && return 1

  # ---------------------------------------------------
  # 如果是 ZIP 下載網址
  # ---------------------------------------------------
  if [[ "$input" =~ ^https?://.*\.zip$ ]]; then
    echo "偵測到為 ZIP 插件連結，開始下載..."
    tmp_file="/tmp/plugin_$$.zip"

    if ! wget -qO "$tmp_file" "$input"; then
      echo -e "${RED}下載失敗${RESET}"
      return 1
    fi

    if ! unzip -t "$tmp_file" >/dev/null 2>&1; then
      echo -e "${RED}下載的檔案不是有效的 ZIP 壓縮檔${RESET}"
      rm -f "$tmp_file"
      return 1
    fi

    unzip -q "$tmp_file" -d "$plugin_dir" || {
      echo -e "${RED}解壓失敗${RESET}"
      rm -f "$tmp_file"
      return 1
    }
    rm -f "$tmp_file"
    echo -e "${GREEN}插件已解壓至：$plugin_dir${RESET}"

    plugin_slug=$(ls -1 "$plugin_dir" | head -n 1)
    if [ -n "$plugin_slug" ]; then
      echo -e "${GREEN}正在嘗試啟用插件...${RESET}"
      wp --skip-plugins --skip-themes --allow-root --path="$site_path" plugin activate "$plugin_slug" 2>/dev/null \
         && echo -e "${GREEN}已啟用插件：$plugin_slug${RESET}" \
         || echo -e "${YELLOW}無法自動啟用，請手動啟用插件${RESET}"
    else
      echo -e "${YELLOW}無法偵測插件目錄，請手動啟用插件${RESET}"
    fi
    return 0
  fi

  # ---------------------------------------------------
  # 插件關鍵字搜尋（使用 JSON 以避免 CSV 問題）
  # ---------------------------------------------------
  echo "正在搜尋包含 \"$input\" 的插件..."

  mapfile -t plugins < <(
    wp --skip-plugins --skip-themes --allow-root --path="$site_path" plugin search "$input" --per-page=10 --format=json | jq -r '.[] | "\(.name)|\(.slug)"'
  )

  if [ ${#plugins[@]} -eq 0 ]; then
    echo -e "${RED}找不到任何相關插件${RESET}"
    return 1
  fi

  local options=()
  local slugs=()

  for entry in "${plugins[@]}"; do
    name="${entry%%|*}"
    slug="${entry##*|}"
    [ -n "$slug" ] && options+=("$name (slug: $slug)") && slugs+=("$slug")
  done

  if [ ${#options[@]} -eq 0 ]; then
    echo -e "${RED}找不到任何有效插件${RESET}"
    return 1
  fi

  echo "請選擇欲安裝的插件："
  select opt in "${options[@]}"; do
    if [ -n "$opt" ]; then
      idx=$((REPLY - 1))
      slug="${slugs[$idx]}"
      echo -e "${CYAN}開始安裝插件：$slug${RESET}"
      wp --skip-plugins --skip-themes --allow-root --path="$site_path" plugin install "$slug" --activate
      return
    else
      echo -e "${YELLOW}無效的選項，請重新選擇${RESET}"
    fi
  done
}

install_web_server(){
  local mode=$1
  local other=$2
  local os=$(grep -w "^ID" /etc/os-release | cut -d= -f2 | tr -d '"')
  local codename=$(grep -w "^VERSION_CODENAME" /etc/os-release | cut -d= -f2 | tr -d '"')
  if [ $mode == openresty ]; then
    if [[ "$other" == "docker" ]]; then
      check_web_server
      openresty=1
      docker_name=openresty
      default $mode
      mkdir -p /etc/nginx/conf.d
      mkdir -p /var/log/openresty
      docker run -d \
        --name openresty \
        --restart always \
        --network host \
        -v /etc/letsencrypt:/etc/letsencrypt:ro \
        -v /etc/nginx/conf.d:/usr/local/openresty/nginx/conf/conf.d:ro \
        -v /etc/nginx/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro \
        -v /var/www:/var/www \
        -v /run/php:/run/php:ro \
        -v /home/web/cert:/home/web/cert:ro \
        -v /etc/nginx/HttpGuard:/usr/local/openresty/nginx/conf/HttpGuard \
        -v /var/log/openresty/access.log:/usr/local/openresty/nginx/logs/access.log \
        -v /var/log/openresty/error.log:/usr/local/openresty/nginx/logs/error.log \
        -v /etc/localtime:/etc/localtime:ro \
        gebu8f/openresty:latest
      check_web_server
      return 0
    fi
    case "$system" in
    1)
      apt update
      apt install -y curl gnupg2 ca-certificates lsb-release
      curl -s https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/openresty.gpg
      if [[ $os == "debian" ]]; then
        echo "deb https://openresty.org/package/debian $codename openresty" | tee /etc/apt/sources.list.d/openresty.list
      elif [[ $os == "kali" ]]; then
        codename="bookworm"
        echo "deb https://openresty.org/package/debian $codename openresty" | tee /etc/apt/sources.list.d/openresty.list
      elif [[ $os == "ubuntu" ]]; then
        echo "deb https://openresty.org/package/ubuntu $codename openresty" | tee /etc/apt/sources.list.d/openresty.list
      fi
      apt update
      apt install openresty -y
      rm -rf /etc/nginx
      ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
      ln -sf /usr/local/openresty/nginx/conf /etc/nginx
      mkdir -p /etc/nginx/conf.d
      systemctl enable openresty
    ;;
    2)
      dnf update
      dnf install -y dnf-utils
      dnf-config-manager --add-repo https://openresty.org/package/$os/openresty.repo
      dnf update
      dnf install -y openresty --nogpgcheck
      rm -rf /etc/nginx
      ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
      ln -sf /usr/local/openresty/nginx/conf /etc/nginx
      mkdir -p /etc/nginx/conf.d
      systemctl enable openresty
      ;;
    3)
      if [[ $other == compile ]]; then
        apk add build-base perl pcre2-dev openssl-dev zlib-dev curl git
        ver=$(curl -s https://openresty.org/en/download.html | grep -m 1 -Eo 'openresty-[0-9.]+\.tar\.gz' | sed 's/^openresty-\(.*\)\.tar\.gz$/\1/' | head -n 1)
        if [ -z $ver ]; then
          echo "${RED} 無法辨識版本${RESET}"
          sleep 1
          return 1
        fi
        mkdir -p /usr/local/src/ && cd /usr/local/src/
        curl -O https://openresty.org/download/openresty-$ver.tar.gz
        tar -xzvf openresty-$ver.tar.gz
        rm openresty-$ver.tar.gz
        cd openresty-$ver/
        ./configure --prefix=/usr/local/openresty \
          --with-compat \
          --with-threads \
          --with-pcre-jit \
          --with-http_ssl_module \
          --with-http_v2_module \
          --with-http_v3_module \
          --with-http_realip_module \
          --with-http_stub_status_module \
          --with-http_gzip_static_module \
          --with-http_gunzip_module \
          --with-stream \
          --with-stream_ssl_module \
          --with-stream_ssl_preread_module
        make -j$(nproc)
        make install
        ln -s /usr/local/openresty/bin/openresty /usr/local/bin/openresty
        ln -s /usr/local/openresty/nginx/sbin/nginx /usr/local/bin/nginx
        ln -s /usr/local/openresty/bin/resty /usr/local/bin/resty
        cat > /etc/init.d/openresty << 'EOF'
#!/sbin/openrc-run

name="openresty"
description="OpenResty Web Platform"

command="/usr/local/openresty/nginx/sbin/nginx"
command_args="-p /usr/local/openresty/nginx/ -c /usr/local/openresty/nginx/conf/nginx.conf"
pidfile="/usr/local/openresty/nginx/logs/nginx.pid"

depend() {
    need net
    use dns logger
}

start_pre() {
    checkpath --directory --mode 0755 /usr/local/openresty/nginx/logs
}

reload() {
    ebegin "Reloading $name"
    if [ -f "$pidfile" ]; then
        start-stop-daemon --signal HUP --pidfile "$pidfile"
        eend $?
    else
        eend 1 "PID file not found, is $name running?"
    fi
}
EOF
      chmod +x /etc/init.d/openresty
      rc-update add openresty default
      rc-service openresty start
      else
        apk update
        apk add --no-cache pcre openssl curl gnupg
        curl -O https://openresty.org/package/admin@openresty.com-5ea678a6.rsa.pub
        mv admin@openresty.com-5ea678a6.rsa.pub /etc/apk/keys/
        echo "https://openresty.org/package/alpine/v$(cut -d. -f1,2 /etc/alpine-release)/main" \
          | tee -a /etc/apk/repositories
        apk update
        apk add --no-cache openresty
        ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
        ln -sf /usr/local/openresty/nginx/conf /etc/nginx
        mkdir -p /etc/nginx/conf.d
        rc-update add openresty default
      fi
      ;;
    esac
    check_web_server
    default $mode
  elif [ $mode == nginx ]; then
    case $system in
    1)
      apt update
      apt install -y curl gnupg2 ca-certificates lsb-release
      curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
      if [[ $os == "debian" ]]; then
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian $codename nginx" | tee /etc/apt/sources.list.d/nginx.list
      elif [[ $os == "ubuntu" ]]; then
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu $codename nginx" | tee /etc/apt/sources.list.d/nginx.list
      elif [[ $os == "kali" ]]; then
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian bookworm nginx" | tee /etc/apt/sources.list.d/nginx.list
      fi
      apt update
      apt install nginx -y
      systemctl enable nginx
      ;;
    2)
      tee /etc/dnf.repos.d/nginx.repo << 'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
      dnf install nginx -y
      systemctl enable nginx
      ;;
    3)
      wget -O /tmp/nginx_signing.rsa.pub https://nginx.org/keys/nginx_signing.rsa.pub
      mv /tmp/nginx_signing.rsa.pub /etc/apk/keys/
      echo "https://nginx.org/packages/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/main" | tee -a /etc/apk/repositories
      apk update
      apk add nginx
      rc-update add nginx default
      ;;
    esac
    check_web_server
    default $mode
  elif [ $mode == caddy ]; then 
    case $system in
    1)
      apt install -y debian-keyring debian-archive-keyring apt-transport-https
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
      chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      chmod o+r /etc/apt/sources.list.d/caddy-stable.list
      apt update
      apt install caddy
      systemctl enable caddy
      ;;
    2)
      if [ -f /etc/fedora-release ]; then
        dnf install -y dnf5-plugins
        dnf copr enable @caddy/caddy
        dnf install -y caddy
      else
        dnf install -y dnf-plugins-core
        dnf copr enable @caddy/caddy
        dnf install -y caddy
      fi
      systemctl enable caddy
    esac
    check_web_server
    default $mode
  fi
}

install_wpcli_if_needed() {
  if ! command -v wp >/dev/null 2>&1; then
    curl -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || {
      echo "下載失敗，請檢查網路！"
      return 1
    }
    chmod +x /tmp/wp-cli.phar
    mv /tmp/wp-cli.phar /usr/local/bin/wp
  fi
}

php_install() {
  case $system in
    1)
      local os=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
      local DEB_VER=$(cat /etc/debian_version | cut -d. -f1)
      local codename=$(lsb_release -sc)
      apt update
      apt install -y software-properties-common ca-certificates lsb-release gnupg curl
      
      if [[ $os == "kali" ]]; then
        # Kali rolling 沒有對應的 Sury 名稱，強制指定為 bookworm
        codename="bookworm"
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/ondrej_php.gpg
        echo "deb https://packages.sury.org/php/ $codename main" > /etc/apt/sources.list.d/php.list
      elif [[ $os == "debian" ]]; then
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/ondrej_php.gpg
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
      elif [[ $os == "ubuntu" ]]; then
        add-apt-repository -y ppa:ondrej/php
      fi

      apt update

      echo -e "${CYAN}偵測可用 PHP 版本...${RESET}"
      local flarum_php_var=$(check_flarum_supported_php)
      local versions=$(apt-cache search ^php[0-9.]+$ | grep -oP '^php\K[0-9.]+' | sort -Vu | awk -F. '$1>=8 {print}')
      if [[ -z "$versions" ]]; then
        echo -e "${RED}無法取得 PHP 版本列表，請檢查倉庫是否正常。${RESET}"
        return 1
      fi

      echo -e "${YELLOW}可用 PHP 版本如下（僅列出 8.0 以上）：${GREEN}$(echo "$versions" | xargs)${RESET}"
      echo -e "${CYAN}您好，如果您要使用 flarum 的話，這是它現在支援建議的版本，請留意：${GREEN}${flarum_php_var}${RESET}"
      read -p "請輸入要安裝的 PHP 版本（例如 8.3）[預設8.3]: " phpver
      phpver=${phpver:-8.3}
      if ! echo "$versions" | grep -qx "$phpver"; then
        echo -e "${RED}無效版本號：$phpver${RESET}"
        return 1
      fi
      if [ "$DEB_VER" -ge 13 ]; then
        apt install valkey-server -y
      else
        apt install -y redis-server
      fi

      apt install -y php$phpver php$phpver-fpm php$phpver-mysql php$phpver-curl php$phpver-gd \
        php$phpver-xml php$phpver-mbstring php$phpver-zip php$phpver-intl php$phpver-bcmath php$phpver-imagick unzip

      systemctl enable --now php$phpver-fpm
      ;;

    2)
      dnf update -y
      dnf install -y epel-release dnf-plugins-core
      local REHL_VER=$(grep -oP 'release \K[0-9]+' /etc/redhat-release)
      dnf install -y https://rpms.remirepo.net/enterprise/remi-release-$REHL_VER.rpm
      dnf update -y
      dnf config-manager --set-enabled remi-modular
      dnf makecache -y 
      
      local flarum_php_var=$(check_flarum_supported_php)

      local php_versions=$(dnf module list php | grep -E '^php\s+(remi-)?8\.[0-9]+' | awk '{print $2}' | sed 's/remi-//' | sort -Vu | xargs)

      if [[ -z "$php_versions" ]]; then
        echo -e "${RED}無法偵測可用 PHP 模組版本。${RESET}"
        return 1
      fi

      echo -e "${YELLOW}可用 PHP 版本如下（僅列出 8.0 以上）：${GREEN}$(echo "$php_versions" | xargs)${RESET}"
      echo -e "${CYAN}您好，如果您要使用 flarum 的話，這是它現在支援建議的版本，請留意：${GREEN}${flarum_php_var}${RESET}"
      read -p "請輸入要安裝的 PHP 版本（例如 8.3）[預設8.3]: " phpver
      phpver=${phpver:-8.3}

      if [[ ! " $php_versions " =~ " $phpver " ]]; then
        echo -e "${RED}無效版本號：$phpver${RESET}"
        return 1
      fi

      dnf module reset php -y
      dnf module enable php:remi-$phpver -y
      dnf install -y php php-fpm php-mysqlnd php-curl php-gd php-xml php-mbstring php-zip php-intl php-bcmath php-pecl-imagick unzip valkey

      systemctl enable --now php-fpm
      systemctl enable --now valkey
      echo -e "${GREEN}PHP $phpver 與 Valkey 安裝完成！${RESET}"
      sleep 1.5
      ;;

    3)
      local ALPINE_VER_FULL=$(cat /etc/alpine-release)
      local MAJOR=$(echo "$ALPINE_VER_FULL" | cut -d. -f1)
      local MINOR=$(echo "$ALPINE_VER_FULL" | cut -d. -f2)
      echo "@edgecommunity http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
      apk update
      
      local candidates=$(apk search -x php[0-9]* | grep -oE 'php[0-9]{2}' | sort -u)

      # 擷取可用版本
      local available_versions=""
      
      local flarum_php_var=$(check_flarum_supported_php)
      
      for c in $candidates; do
        if apk info "$c" >/dev/null 2>&1; then
          short=${c#php}
          [[ "$short" -ge 80 ]] && available_versions+=$'\n'"8.${short:1}"
        fi
      done

      # 過濾 80 以下版本
      local filtered_versions=$(echo "$available_versions" | sort -Vu)

      echo -e "${YELLOW}可用 PHP 版本如下（僅列出 8.0 以上）：${GREEN}$(echo "$filtered_versions" | xargs)${RESET}"
      
      echo -e "${CYAN}您好，如果您要使用 flarum 的話，這是它現在支援建議的版本，請留意：${GREEN}${flarum_php_var}${RESET}"

      read -p "請輸入要安裝的 PHP 版本（例如 8.3）[預設8.3]: " phpver
      phpver=${phpver:-8.3}

      if ! echo "$phpver" | grep -qE '^8\.[0-9]+$'; then
        echo -e "${RED}請輸入有效的 PHP 8.x 版本${RESET}"
        return 1
      fi

      local shortver=$(echo "$phpver" | tr -d '.')

      if ! echo "$available_versions" | grep -q "^8\.${shortver:1}$"; then
        echo -e "${RED}Edge 倉庫中找不到 php$shortver，請確認版本是否正確${RESET}"
        return 1
      fi
      
      if ! apk add --simulate php$shortver>/dev/null 2>&1; then
        echo -e "${RED}您好，您的php版本$phpver無法安裝${RESET}"
        return 1
      fi
      if [ "$MAJOR" -gt 3 ] || { [ "$MAJOR" -eq 3 ] && [ "$MINOR" -ge 20 ]; }; then
        apk add --no-cache valkey
        rc-update add valkey default
        rc-service valkey start
      else
        apk add --no-cache redis
        rc-update add redis default
        rc-service redis start
      fi

      apk add php$shortver php$shortver-fpm php$shortver-mysqli php$shortver-curl \
        php$shortver-gd php$shortver-xml php$shortver-mbstring php$shortver-zip \
        php$shortver-intl php$shortver-bcmath php$shortver-pecl-imagick php$shortver-phar unzip || {
          echo -e "${RED}安裝失敗，請確認版本是否存在於 Edge 社群源。${RESET}"
          return 1
        }

      ln -sf /usr/bin/php$shortver /usr/bin/php
      ln -sf /usr/sbin/php$shortver-fpm /usr/sbin/php-fpm
      rc-service php-fpm$shortver start
      rc-update add php-fpm$shortver default
      ;;
  esac
}


php_fix(){
  local php_var=$(check_php_version)
  local ngx_user=$(get_web_run_user)

  if [ $system -eq 1 ]; then  # Debian/Ubuntu
    sed -i -r "s|^;?(user\s*=\s*).*|\1$ngx_user|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(group\s*=\s*).*|\1$ngx_user|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(listen.owner\s*=\s*).*|\1$ngx_user|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(listen.group\s*=\s*).*|\1$ngx_user|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(listen.mode\s*=\s*).*|\10660|" /etc/php/$php_var/fpm/pool.d/www.conf
    sed -i -r "s|^;?(listen\s*=\s*).*|\1/run/php/php-fpm.sock|" /etc/php/$php_var/fpm/pool.d/www.conf
    chown -R root:$ngx_user /var/lib/php/sessions
    chown -R root:$ngx_user /var/lib/php/opcache
    chown -R root:$ngx_user /var/lib/php/wsdlcache
    chmod -R 770 /var/lib/php/session /var/lib/php/opcache /var/lib/php/wsdlcache
    chown_set
    systemctl restart php$php_var-fpm

  elif [ $system -eq 2 ]; then  # CentOS/RHEL
    if $selinux_enforcing; then
      semanage fcontext -a -t httpd_var_run_t "/run/php(/.*)?"
      restorecon -Rv /run/php
    fi
    echo "d /run/php 0755 nginx nginx - -" | sudo tee /etc/tmpfiles.d/php-fpm-custom.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/php-fpm-custom.conf
    local web_users="nginx,apache"
    if id "caddy" &>/dev/null; then
      web_users="$web_users,caddy"
    fi
    sed -i "s|^[;[:space:]]*user *=.*|user = $ngx_user|" /etc/php-fpm.d/www.conf
    sed -i "s|^[;[:space:]]*group *=.*|group = $ngx_user|" /etc/php-fpm.d/www.conf
    sed -i "s|^[;[:space:]]*listen.acl_users *=.*|listen.acl_users = $web_users|" /etc/php-fpm.d/www.conf
    sed -i "s|^[;[:space:]]*listen.mode *=.*|listen.mode = 0660|" /etc/php-fpm.d/www.conf
    sed -i "s|^[;[:space:]]*listen *=.*|listen = /run/php/php-fpm.sock|" /etc/php-fpm.d/www.conf
    
    chown -R root:$ngx_user /var/lib/php/session
    chown -R root:$ngx_user /var/lib/php/opcache
    chown -R root:$ngx_user /var/lib/php/wsdlcache
    chmod -R 770 /var/lib/php/session /var/lib/php/opcache /var/lib/php/wsdlcache
    chown_set
    systemctl restart php-fpm

  elif [ $system -eq 3 ]; then  # Alpine
    sed -i "s/^user =.*/user = $ngx_user/" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s/^group =.*/group = $ngx_user/" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s|^listen =.*|listen = /run/php/php-fpm.sock|" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s/^;listen.owner =.*/listen.owner = $ngx_user/" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s/^;listen.group =.*/listen.group = $ngx_user/" /etc/php$php_var/php-fpm.d/www.conf
    sed -i "s/^;listen.mode =.*/listen.mode = 0660/" /etc/php$php_var/php-fpm.d/www.conf
    chown -R root:$ngx_user /var/lib/php$php_var/sessions
    chown -R root:$ngx_user /var/lib/php$php_var/opcache
    chown -R root:$ngx_user /var/lib/php$php_var/wsdlcache
    chmod -R 770 /var/lib/php$php_var/session /var/lib/php$php_var/opcache /var/lib/php$php_var/wsdlcache
    chown_set
    rc-service php-fpm$php_var restart
  fi
}


php_switch_version() {
  case $system in
  1)
    oldver=$(check_php_version)
    local versions=$(apt-cache search ^php[0-9.]+$ | grep -oP '^php\K[0-9.]+' | sort -Vu | awk -F. '$1>=8 {print}')
    ;;
  2)
    oldver=$(check_php_version)
    local versions=$(dnf module list php | grep -E '^php\s+(remi-)?8\.[0-9]+' | awk '{print $2}' | sed 's/remi-//' | sort -Vu | xargs)
    ;;
  3)
    local oldver=$(php -v | head -n1 | grep -oE '[0-9]+\.[0-9]+') # 8.3
    local candidates=$(apk search -x php[0-9]* | grep -oE 'php[0-9]{2}' | sort -u)

      # 擷取可用版本
      local available_versions=""
      
      for c in $candidates; do
        if apk info "$c" >/dev/null 2>&1; then
          short=${c#php}
          [[ "$short" -ge 80 ]] && available_versions+=$'\n'"8.${short:1}"
        fi
      done

      # 過濾 80 以下版本
      local versions=$(echo "$available_versions" | sort -Vu)
    ;;
  esac
  

  echo "目前安裝的 PHP 版本為：$oldver"
  echo "可升級/降級版本：$versions"
  read -p "請輸入要升級/降級的 PHP 版本（例如 8.3）[預設與目前相同]: " newver
  newver=${newver:-$oldver}
  shortold=$(echo "$oldver" | tr -d '.')
  shortnew=$(echo "$newver" | tr -d '.')

  echo "準備擷取舊版已安裝擴充模組..."
  case $system in
    1)
      mapfile -t exts < <(dpkg -l | grep "^ii  php$oldver-" | awk '{print $2}' | grep -oP "(?<=php$oldver-).*" | grep -vE '^(fpm|cli|common)$')
      ;;
    2)
      mapfile -t exts < <(
        rpm -qa | grep "^php-" |
        grep -vE '^php-(cli|fpm|common|[0-9]+\.[0-9]+)' |
        sed -E 's/^php-pecl-//; s/^php-//' |
        sed -E 's/(-im[0-9]+)?-[0-9].*$//' |
        sort -u
      )
      ;;
    3)
      mapfile -t exts < <(apk info | grep "^php$shortold-" | sed "s/php$shortold-//" | grep -vE '^(fpm|cli|common)$')
      ;;
  esac

  echo -e "${CYAN}已偵測的擴充模組：${exts[*]:-無}${RESET}"
  
  case $system in
  3)
    echo "偵測是否能順利安裝..."
    if ! apk add --simulate php$shortnew>/dev/null 2>&1; then
      echo "您好，您的php版本$phpver無法安裝"
      return 1
    fi
    ;;
  esac

  echo -e "${CYAN}停止 PHP 與 Web 服務...${RESET}"
  case $system in
    1)
      systemctl stop php$oldver-fpm 2>/dev/null
      systemctl disable php$oldver-fpm 2>/dev/null
      systemctl stop nginx 2>/dev/null
      systemctl stop openresty 2>/dev/null
      ;;
    2)
      systemctl stop php-fpm 2>/dev/null
      systemctl disable php-fpm 2>/dev/null
      systemctl stop nginx 2>/dev/null
      systemctl stop openresty 2>/dev/null
      ;;
    3)
      rc-service php-fpm$shortold stop 2>/dev/null
      rc-update del php-fpm$shortold 
      rc-service nginx stop 2>/dev/null
      ;;
  esac

  echo -e "${CYAN}移除舊版 PHP...${RESET}"
  case $system in
    1)
      apt purge -y php$oldver* ;;
    2)
      dnf module reset php -y
      mapfile -t php_packages < <(rpm -qa | grep "^php-" | awk '{print $1}')
      if [[ ${#php_packages[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未發現任何 PHP 套件可移除。${RESET}"
      else
        echo -e "${CYAN}即將移除下列 PHP 套件：${RESET}"
        printf ' - %s\n' "${php_packages[@]}"
        dnf remove -y --noautoremove "${php_packages[@]}"
      fi
      ;;
    3)
      apk del php$shortold* ;;
  esac

  echo -e "${CYAN}安裝新版 PHP：$newver${RESET}"
  case $system in
    1)
      apt install php$newver php$newver-fpm -y
      ;;
    2)
      dnf module enable php:remi-$newver -y 
      dnf install php php-fpm -y
      ;;
    3)
      apk add php$shortnew php$shortnew-fpm
      ;;
  esac

  echo -e "${CYAN}重新安裝擴充模組...${RESET}"
  for ext in "${exts[@]}"; do
    echo " - 重新安裝模組：$ext"
    case $system in
      1) apt install -y php$newver-$ext ;;
      2) dnf install -y php-$ext ;;
      3) apk add php$shortnew-$ext ;;
    esac
  done

  case $system in
    1)
      systemctl enable php$newver-fpm
      systemctl restart php$newver-fpm
      systemctl start openresty
      ;;
    2)
      systemctl enable php-fpm
      systemctl restart php-fpm
      systemctl start openresty
      ;;
    3)
      rc-update add php-fpm$shortnew default
      rc-service php-fpm$shortnew restart
      rc-service nginx start
      ;;
  esac
  sleep 5
  php_fix

  echo -e "${GREEN}PHP 升級/降級完成（從 $oldver → $newver）${RESET}"
}


php_tune_upload_limit() {
  local php_var=$(check_php_version)
  if ! command -v php >/dev/null 2>&1; then
    echo "未偵測到 PHP，請先安裝 PHP 後再使用此功能。"
    return 1
  fi

  php_ini=$(phpini_path)

  echo "目前使用的 php.ini：$php_ini"
  read -p "請輸入最大上傳大小（例如 64M、100M、1G，預設 64M）：" max_upload
  max_upload="${max_upload:-64M}"

  # 將 max_upload 轉成 MB 數值（單位大小推算）
  unit=$(echo "$max_upload" | grep -oEi '[MG]' | tr '[:lower:]' '[:upper:]')
  value=$(echo "$max_upload" | grep -oE '^[0-9]+')

  if [ "$unit" == "G" ]; then
    post_size="$((value * 2))G"
  elif [ "$unit" == "M" ]; then
    post_size="$((value * 2))M"
  else
    echo "格式錯誤，請輸入例如 64M 或 1G"
    return 1
  fi

  # 固定設定 memory_limit 為 1536M（1.5GB）
  memory_limit="1536M"

  # 修改 php.ini 內容
  sed -i "s/^\s*upload_max_filesize\s*=.*/upload_max_filesize = $max_upload/" "$php_ini"
  sed -i "s/^\s*post_max_size\s*=.*/post_max_size = $post_size/" "$php_ini"
  sed -i "s/^\s*memory_limit\s*=.*/memory_limit = $memory_limit/" "$php_ini"

  echo -e "${GREEN}已設定：${RESET}"
  echo "  - upload_max_filesize = $max_upload"
  echo "  - post_max_size = $post_size"
  echo "  - memory_limit = $memory_limit"

  # 重啟 php-fpm
  if [ $system -eq 1 ]; then
    systemctl restart php$php_var-fpm
  elif [ $system -eq 2 ]; then
    systemctl restart php-fpm
  elif [ $system -eq 3 ]; then
    rc-service php-fpm$php_var restart
  fi

  echo -e "${GREEN}PHP FPM 已重新啟動${RESET}"
}

php_install_extensions() {
  local php_var=$(check_php_version)

  read -p "請輸入要安裝的 PHP 擴展名稱（如：gd、mbstring、curl、intl、zip、imagick 等）: " ext_name
  if [ -z "$ext_name" ]; then
    echo "未輸入擴展名稱，中止操作。"
    return 1
  fi

  echo -en "${CYAN}檢查 PHP 擴展：$ext_name ... ${RESET}"
  if php -m | grep -Fxiq -- "$ext_name"; then
    echo -e "${GREEN}已安裝${RESET}"
    return 0
  fi

  if ! check_php_ext_available "$ext_name" "$php_var"; then
    echo -e "${RED}擴展 $ext_name 不存在於倉庫，無法安裝${RESET}"
    return 1
  fi

  echo "倉庫中找到 $ext_name，開始安裝..."

  case $system in
    1)
      apt update
      apt install -y php$php_var-$ext_name
      systemctl restart php$php_var-fpm
      ;;
    2)
      dnf install -y php-$ext_name || dnf install -y php-pecl-$ext_name
      systemctl restart php-fpm
      ;;
    3)
      apk update
      apk add php$php_var-$ext_name
      rc-service php-fpm$php_var restart
      ;;
    *)
      echo "不支援的系統類型。"
      return 1
      ;;
  esac

  if php -m | grep -Fxiq -- "$ext_name"; then
    echo -e "${GREEN}PHP 擴展 $ext_name 安裝成功。${RESET}"
  else
    echo -e "${RED}PHP 擴展 $ext_name 安裝失敗，請檢查錯誤訊息。${RESET}"
    return 1
  fi
}



reverse_proxy(){
  read -p "請輸入網址（格式：(example.com))：" domain
  read -p "請輸入反向代理網址（如果是容器,則不用填,預設127.0.0.1）：" target_url
  read -p "請輸入反向代理網址的端口號：" target_port
  echo "正在檢查輸入的網址..."
  if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
    echo "端口號必須在1到65535之間。"
    return 1
  fi
  read -p "請輸入反向代理的http(s)(如果是容器的話預設是http):" target_protocol
  target_url=${target_url:-127.0.0.1}
  target_protocol=${target_protocol:-http}
  check_cert "$domain" || {
    echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
    if ssl_apply "$domain"; then
      echo "申請成功，重新驗證憑證..."
        check_cert "$domain" || {
          echo "申請成功但仍無法驗證憑證，中止建立站點"
          return 1
        }
    else
      echo "SSL 申請失敗，中止建立站點"
      return 1
    fi
  }
  setup_site "$domain" proxy "$target_url" "$target_protocol" "$target_port"
  echo "已建立 $domain 反向代理站點。"
}

restart_webserver() {
  local test_cmd=""
  local restart_cmd=""
  local web_server_name=""
  local test_output=""
  local exit_code=0

  # --- Docker 環境處理 ---
  if [ -n "$docker_name" ]; then
    
    # 根據容器類型，決定測試指令
    if [ "$openresty" -eq 1 ]; then
      web_server_name="OpenResty"
      test_cmd="docker exec $docker_name openresty -t"
    elif [ "$nginx" -eq 1 ]; then
      web_server_name="Nginx"
      test_cmd="docker exec $docker_name nginx -t"
    fi
    
    # 決定重啟指令
    restart_cmd="docker restart $docker_name"
    
  # --- Host 原生環境處理 ---
  else
    
    # 根據服務類型，決定測試和重啟指令
    if [ "$openresty" -eq 1 ]; then
      web_server_name="OpenResty"
      test_cmd="openresty -t"
      restart_cmd="service openresty restart"
    elif [ "$nginx" -eq 1 ]; then
      web_server_name="Nginx"
      test_cmd="nginx -t"
      restart_cmd="service nginx restart"
    elif [ "$caddy" -eq 1 ]; then
      web_server_name="Caddy"
      test_cmd="caddy validate --config /etc/caddy/Caddyfile"
      restart_cmd="service caddy restart"
    fi
  fi
  # --- 執行測試 ---
  # 執行測試指令，並將 stdout 和 stderr 都存到 test_output 變數中
  test_output=$($test_cmd 2>&1)
  exit_code=$?

  # --- 根據測試結果決定是否重啟 ---
  if [ $exit_code -eq 0 ]; then
    $restart_cmd >/dev/null 2>&1
    return 0
  else
    echo -e "${RED}錯誤：${web_server_name} 設定檔測試失敗！服務未重啟。${RESET}"
    echo -e "${RED}詳細錯誤訊息如下：${RESET}"
    echo -e "$test_output"
    echo -e "${RED}--------------------------------------------------${RESET}"
    return 1
  fi
}

remove_wp_plugin_with_menu() {
  local domain="$1"
  local site_path="/var/www/$domain"
  local plugin_dir="$site_path/wp-content/plugins"

  echo -e "${CYAN}正在偵測已安裝的插件...${RESET}"

  # 只抓目錄 (真正的 plugins)
  mapfile -t plugin_folders < <(
    find "$plugin_dir" -mindepth 1 -maxdepth 1 -type d -printf "%f\n"
  )

  if [ ${#plugin_folders[@]} -eq 0 ]; then
    echo -e "${YELLOW}此網站沒有安裝任何插件${RESET}"
    return 0
  fi

  local options=()
  for folder in "${plugin_folders[@]}"; do
    status=$(wp --skip-plugins --skip-themes --allow-root --path="$site_path" plugin get "$folder" --field=status 2>/dev/null)
    if [ -n "$status" ]; then
      options+=("$folder [$status]")
    else
      options+=("$folder [unknown]")
    fi
    if [ "$status" = "dropin" ]; then
      continue
    fi
  done

  echo "請選擇要移除的插件："
  select opt in "${options[@]}"; do
    if [ -n "$opt" ]; then
      slug=$(echo "$opt" | awk '{print $1}')
      echo -e "${CYAN}正在移除插件：$slug${RESET}"
      wp --skip-plugins --skip-themes --allow-root --path="$site_path" plugin deactivate "$slug"
      wp --skip-plugins --skip-themes --allow-root --path="$site_path" plugin delete "$slug"
      echo -e "${GREEN}插件已刪除：$slug${RESET}"
      return
    else
      echo -e "${RED}無效的選項，請重新選擇${RESET}"
    fi
  done
}


reset_wp_site() {
  local domain="$1"
  local path="/var/www/$domain"
  local wp_cli="wp --skip-plugins --skip-themes --allow-root"

  # 檢查該路徑是否是 WordPress
  if [ ! -f "$path/wp-config.php" ]; then
    echo -e "${RED}$domain 不是 WordPress 網站！${RESET}"
    return 1
  fi

  echo -e "${CYAN}正在對 $domain 執行 WordPress 緊急重置...${RESET}"

  # 停用全部外掛
  $wp_cli plugin deactivate --all --path="$path" || \
    echo -e "${YELLOW}停用外掛失敗。${RESET}"

  # 嘗試找預設主題
  default_theme=$($wp_cli theme list --path="$path" --status=inactive --field=name | grep -E '^twenty' | head -n 1)

  if [ -z "$default_theme" ]; then
    echo -e "${YELLOW}未發現預設佈景主題，嘗試安裝 Twenty Twenty-Four...${RESET}"
    $wp_cli theme install twentytwentyfour --path="$path"
    default_theme="twentytwentyfour"
  fi

  $wp_cli theme activate "$default_theme" --path="$path" || \
    echo -e "${YELLOW}切換佈景主題失敗。${RESET}"

  echo -e "${GREEN}$domain 已完成緊急重置。可嘗試重新登入後台。${RESET}"
}

restore_site_files() {
  local mode="$1"
  local domain="$2"
  local default_backup_dir="/opt/backups/$domain"
  local backup_dir=""
  local archive=""
  is_db_done=false

  # 讓使用者輸入或確認備份檔案所在的目錄
  read -p "請輸入備份檔案所在目錄 [預設: $default_backup_dir]: " backup_dir
  backup_dir="${backup_dir:-$default_backup_dir}"

  # 檢查目錄是否存在
  if [[ ! -d "$backup_dir" ]]; then
    echo -e "${RED}目錄不存在: $backup_dir${RESET}" >&2
    return 1
  fi

  # 使用 mapfile 讀取所有 .tar.gz 和 .zip 檔案，並按時間倒序排序
  mapfile -t backup_files < <(find "$backup_dir" -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "*.zip" \) -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)

  # 檢查是否有找到備份檔
  if [ ${#backup_files[@]} -eq 0 ]; then
    echo -e "${YELLOW}在 '$backup_dir' 目錄中找不到任何 .tar.gz 或 .zip 備份檔。${RESET}" >&2
    return 1
  fi

  # 列出檔案讓使用者選擇
  echo -e "${CYAN}在 '$backup_dir' 中找到以下備份檔：${RESET}"
  for i in "${!backup_files[@]}"; do
    printf "%3d) %s\n" "$((i + 1))" "$(basename "${backup_files[$i]}")"
  done
  read -p "請選擇要還原的檔案編號: " choice

  # 驗證選擇
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backup_files[@]} )); then
    echo -e "${RED}無效的選擇。${RESET}" >&2
    return 1
  fi
  archive="${backup_files[$((choice - 1))]}"
  # === 後續流程不變 ===
  local dest_dir="/var/www/$domain"
  if [[ -d "$dest_dir" ]]; then
    read -p "目錄已存在，是否清空目錄後還原？(y/N): " yn
    case "$yn" in
      [Yy]*) 
        rm -rf "${dest_dir:?}"/* 
        ;;
      *) 
        echo "已取消還原。"
        return 0 
        ;;
    esac
  fi

  mkdir -p "$dest_dir"

  if [[ "$archive" == *.tar.gz ]]; then
    tar -xzf "$archive" -C "$dest_dir"
  elif [[ "$archive" == *.zip ]]; then
    unzip -q "$archive" -d "$dest_dir"
  else
    echo -e "${RED}不支援的壓縮格式${RESET}"
    return 1
  fi

  # 檢查解壓是否成功 (一個簡單的檢查方法是看目錄是否仍為空)
  if [ -z "$(ls -A "$dest_dir")" ]; then
      echo -e "${RED}解壓縮失敗或壓縮檔為空！${RESET}"
      return 1
  fi

  set_site_permissions "$mode" "$dest_dir"

  echo -e "${GREEN}[$mode] 檔案還原完成！${RESET}"

  # 根據 system 呼叫不同的 DB restore
  case "$mode" in
    wp)
      echo -e "${GREEN}WordPress 檔案已還原，執行資料庫還原${RESET}"
      restore_site_db "$mode" "$domain" "true"
      ;;
    flarum)
      echo -e "${GREEN}Flarum 檔案已還原，執行資料庫還原${RESET}"
      restore_site_db "$mode" "$domain" "true"
      ;;
    *)
      echo -e "${YELLOW}尚未支援系統：$mode${RESET}"
      ;;
  esac
}

restore_site_db() {
  local type="$1"
  local domain="$2"
  local site_path="/var/www/$domain"
  local is_from_the_files=${3:-false}
  local db_name=""
  local db_user=""
  local db_pass=""
  local sql_to_restore=""

  # --- 步驟 1: 從設定檔讀取資料庫憑證 (不變) ---
  if [[ "$type" == "wp" ]]; then
    local config="$site_path/wp-config.php"
    db_name=$(awk -F"'" '/DB_NAME/{print $4}' "$config")
    db_user=$(awk -F"'" '/DB_USER/{print $4}' "$config")
    db_pass=$(awk -F"'" '/DB_PASSWORD/{print $4}' "$config")
  elif [[ "$type" == "flarum" ]]; then
    local config="$site_path/config.php"
    db_name=$(php -r "\$c = include '$config'; echo \$c['database']['database'] ?? '';")
    db_user=$(php -r "\$c = include '$config'; echo \$c['database']['username'] ?? '';")
    db_pass=$(php -r "\$c = include '$config'; echo \$c['database']['password'] ?? '';")
  fi

  if [[ -z "$db_name" || -z "$db_user" || -z "$db_pass" ]]; then
    echo -e "${RED}錯誤：無法從設定檔中完整讀取資料庫憑證。${RESET}" >&2
    return 1
  fi

  # 確保 dba 工具存在
  if ! command -v dba >/dev/null 2>&1; then
    bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh) install_script
  fi

  # --- 步驟 2: 智慧地尋找並讓使用者選擇 SQL 檔案 (核心修改) ---
  local search_dir="$site_path"
  mapfile -t sql_files < <(find "$search_dir" -maxdepth 1 -type f -name "*.sql" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
  
  # 如果在網站根目錄找不到，則詢問使用者
  if [ ${#sql_files[@]} -eq 0 ] || [[ ! -f "${sql_files[0]}" ]]; then
    echo -e "${YELLOW}在網站根目錄 '$site_path' 中未找到 .sql 檔案。${RESET}"
    local default_sql_dir="/root/mysql_backups"
    read -p "請輸入 .sql 檔案所在的目錄 [預設: $default_sql_dir]: " search_dir
    search_dir="${search_dir:-$default_sql_dir}"

    if [[ ! -d "$search_dir" ]]; then
        echo -e "${RED}目錄不存在: $search_dir${RESET}" >&2
        return 1
    fi
    # 重新在使用者指定的目錄中搜尋
    mapfile -t sql_files < <(find "$search_dir" -maxdepth 1 -type f -name "*.sql" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2-)
  fi

  # 檢查最終是否找到檔案
  if [ ${#sql_files[@]} -eq 0 ] || [[ ! -f "${sql_files[0]}" ]]; then
    echo -e "${RED}錯誤：在 '$search_dir' 目錄中仍然找不到任何 .sql 檔案。${RESET}" >&2
    return 1
  fi

  # 讓使用者從找到的檔案列表中選擇
  if [ ${#sql_files[@]} -gt 1 ]; then
    echo -e "${CYAN}在 '$search_dir' 中找到以下 SQL 檔案：${RESET}"
    for i in "${!sql_files[@]}"; do
      printf "%3d) %s\n" "$((i + 1))" "$(basename "${sql_files[$i]}")"
    done
    read -p "請選擇要還原的檔案編號: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#sql_files[@]} )); then
      echo -e "${RED}無效的選擇。${RESET}" >&2
      return 1
    fi
    sql_to_restore="${sql_files[$((choice - 1))]}"
  else
    # 如果只有一個檔案，就自動選擇，無需使用者操作
    sql_to_restore="${sql_files[0]}"
  fi
  
  # --- 步驟 3: 果斷執行還原 ---

  if dba mysql import "$db_name" "$db_user" "$db_pass" "$sql_to_restore"; then
    echo -e "${GREEN}資料庫還原成功！${RESET}"
    local confirm
    read -p "是否要做更改網域？[Y/n,預設:N]" confirm
    confirm=${confirm,,}
    confirm=${confirm:-n}
    if [ $confirm == y ]; then
      read -p "請輸入域名[空白是$domain]" db_domain
      install_wpcli_if_needed
      wp_change_domains "$db_domain" "$domain"
    fi
    if ! $is_db_done && $is_from_the_files; then
      is_db_done=true
    fi
    if [[ "$(dirname "$sql_to_restore")" == "$site_path" ]]; then
        rm -f "$sql_to_restore"
    fi
    return 0
  else
    echo -e "${RED}使用 'dba' 工具還原資料庫失敗！請檢查 'dba' 工具的輸出訊息。${RESET}" >&2
    return 1
  fi
}

wp_change_domains() {
  local db_domain="$1"
  local domain="$2"
  local old_domain=$(wp option get home --path="/var/www/$domain" --allow-root --skip-plugins --skip-themes)
  local site_url=$(wp option get siteurl --path="/var/www/$domain" --allow-root --skip-plugins --skip-themes)
  if [[ "$old_domain" == "$site_url" ]]; then
    wp search-replace "$old_domain" "https://$db_domain" --skip-plugins --skip-themes --all-tables --precise --skip-columns=guid --path="/var/www/$domain" --allow-root
    wp cache flush --skip-plugins --skip-themes --path="/var/www/$domain" --allow-root
    wp rewrite flush --skip-plugins --skip-themes --path="/var/www/$domain" --allow-root
  fi
}

rhel_selinux_enforcing_permissions() {
  local domain_path="$1"
  local tags="$2"
  if $selinux_enforcing && [ "$tags" = "label" ] ; then
    semanage fcontext -d "$domain_path(/.*)?" 2>/dev/null
    semanage fcontext -a -t httpd_sys_rw_content_t "$domain_path(/.*)?"
    restorecon -Rv $domain_path >/dev/null
  fi
  if $selinux_enforcing && [ "$tags" = "permissions" ]; then
    local ngx_user=$(get_web_run_user)
    local u_id=$(id -u)
    setfacl -R -b "$domain_path"
    chown -R $u_id:$u_id "$domain_path"
    chmod -R 700 "$domain_path"
    setfacl -R -m u:$ngx_user:rwX "$domain_path"
    setfacl -R -d -m u:$ngx_user:rwX "$domain_path"
    if [ -f "$domain_path/wp-config.php" ]; then 
      setfacl -m u:$ngx_user:r "$domain_path/wp-config.php"
      [ -d "$domain_path/wp-content/mu-plugins" ] && mkdir -p "$domain_path/wp-content/mu-plugins"
      setfacl -R -m u:$ngx_user:rX "$domain_path/wp-content/mu-plugins"
      setfacl -R -d -m u:$ngx_user:rX "$domain_path/wp-content/mu-plugins"
    fi
  elif ! $selinux_enforcing && [ "$tags" = permissions ]; then
    chown -R $ngx_user:$ngx_user "$domain_path"
    find "$domain_path" -type d -exec chmod 755 {} +
    find "$domain_path" -type f -exec chmod 644 {} +
  fi
}

rhel_selinux_cleanup_permissions() {
  local domain_path="$1"
  if $selinux_enforcing; then
    semanage fcontext -d "$domain_path(/.*)?" 2>/dev/null
    if [ -d "$domain_path" ]; then
      restorecon -Rv "$domain_path" >/dev/null
    fi
  fi
}

set_site_permissions() {
  local mode="$1"
  local dest_dir="$2"
  local u_id=$(id -u)
  local ngx_user=$(get_web_run_user)
  
  if $selinux_enforcing; then
    chown -R $u_id:$u_id "$dest_dir"
    chmod -R 700 "$dest_dir"
    setfacl -R -m u:$ngx_user:rwX "$dest_dir"
    setfacl -R -d -m u:$ngx_user:rwX "$dest_dir"
    if [ -f "$dest_dir/wp-config.php" ]; then 
      setfacl -m u:$ngx_user:r "$dest_dir/wp-config.php"
      [ -d "$dest_dir/wp-content/mu-plugins" ] && mkdir -p "$dest_dir/wp-content/mu-plugins"
      setfacl -R -m u:$ngx_user:rX "$dest_dir/wp-content/mu-plugins"
      setfacl -R -d -m u:$ngx_user:rX "$dest_dir/wp-content/mu-plugins"
    fi
  else
    chown -R $ngx_user:$ngx_user "$dest_dir"
    find "$dest_dir" -type d -exec chmod 755 {} +
    find "$dest_dir" -type f -exec chmod 644 {} +
  fi
  
  if $selinux_enforcing; then
    semanage fcontext -d "$dest_dir(/.*)?" 2>/dev/null
    semanage fcontext -a -t httpd_sys_rw_content_t "$dest_dir(/.*)?"
    restorecon -Rv $dest_dir >/dev/null
  fi

  case "$mode" in
    wp)
      mkdir -p "$dest_dir/wp-content/uploads" "$dest_dir/wp-content/cache"
      chown -R $ngx_user:$ngx_user "$dest_dir/wp-content"
      find "$dest_dir/wp-content" -type d -exec chmod 775 {} +
      find "$dest_dir/wp-content" -type d -exec chmod g+s {} +
      [ -f "$dest_dir/wp-config.php" ] && chown root:$ngx_user $dest_dir/wp-config.php && chmod 740 "$dest_dir/wp-config.php"
      ;;
    flarum)
      mkdir -p "$dest_dir/storage" "$dest_dir/public/assets"
      chown -R $ngx_user:$ngx_user "$dest_dir/storage" "$dest_dir/public/assets"
      find "$dest_dir/storage" "$dest_dir/public/assets" -type d -exec chmod 775 {} +
      find "$dest_dir/storage" "$dest_dir/public/assets" -type d -exec chmod g+s {} +
      ;;
  esac
}



setup_site_http2(){
  local domain=$1
  local http3=$(check_http3_support) # 這裡會呼叫上面修好的函數
  
  local conf_file=$(detect_conf_path)/$domain.conf 
  
  if [[ "$http3" != "true" ]]; then
    local ngx_ver=""
    
    # --- 獲取版本號 (Docker 兼容) ---
    if [ -n "$docker_name" ]; then
      if [ "$openresty" -eq 1 ]; then
        ngx_ver=$(docker exec "$docker_name" openresty -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      elif [ "$nginx" -eq 1 ]; then
        ngx_ver=$(docker exec "$docker_name" nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      fi
    else
      # Host 模式
      if command -v nginx >/dev/null 2>&1; then
        ngx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      elif command -v openresty >/dev/null 2>&1; then
        ngx_ver=$(openresty -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      fi
    fi
    if [ "$(printf '%s\n' "$ngx_ver" "1.25.1" | sort -V | head -n1)" != "1.25.1" ]; then
      # 如果檔案存在才修改
      if [ -f "$conf_file" ]; then
        sed -i -e '/http2 on/d' "$conf_file"
        # 把 listen 443 ssl; 變成 listen 443 ssl http2;
        sed -i -E 's/(listen\s+443\s+ssl)(;)/\1 http2\2/' "$conf_file"
        sed -i -E 's/(listen\s+\[::\]:443\s+ssl)(;)/\1 http2\2/' "$conf_file"
      else
        echo "警告: 找不到配置文件 $conf_file，跳過 HTTP/2 修改"
      fi
    fi

    # 刪除 HTTP/3 相關配置
    if [ -f "$conf_file" ]; then
      sed -i \
        -e '/listen.*quic/d' \
        -e '/http3 on/d' \
        -e '/http2 on/d' \
        -e '/Alt-Svc/d' \
        -e '/QUIC-Status/d' \
        "$conf_file"
      
      # 這裡需要引入你的顏色變量 GREEN 和 RESET，或者直接 echo
      echo "已刪除 $conf_file 中所有 HTTP/3 / QUIC 相關配置，並啟用 HTTP/2"
    fi
  fi
}


setup_site() {
  local domain=$1
  local type=$2
  local domain_cert=$(check_cert "$domain" | tail -n 1 | tr -d '\r\n')
  local escaped_cert=$(printf '%s' "$domain_cert" | sed 's/[&/\]/\\&/g') # 取得主域名或泛域名作為憑證目錄
  local conf_file=$(detect_conf_path)/$domain.conf
  clean_ssl_session_cache
  
  if [ $caddy -eq 1 ]; then
    case $system in
    1|2)
      case $type in
      html|php|flarum)
        local conf_url="https://gitlab.com/gebu8f/sh/-/raw/main/nginx/caddy/domain_${type}.conf"
        wget -qO "$conf_file" "$conf_url"
        sed -i -e "s|domain|$domain|g" "$conf_file"
        restart_webserver
        ;;
      proxy)
        local target_url=$3
        local target_protocol=$4
        local target_port=$5
        wget -O "$conf_file" https://gitlab.com/gebu8f/sh/-/raw/main/nginx/caddy/domain_proxy.conf
        sed -i "s|reverse_proxy host:port|reverse_proxy $target_protocol://$target_url:$target_port|g" "$conf_file"
        sed -i -e "s|domain|$domain|g" "$conf_file"
        restart_webserver
        ;;
      *)
        echo "不支援的類型: $type"; return 1;;
      esac
      ;;
    esac
    return $?
  fi
  case $system in
    1|2|3)
      case $type in
        html|php|flarum|phpmyadmin)
          local conf_url="https://gitlab.com/gebu8f/sh/-/raw/main/nginx/domain_${type}.conf"
          wget -O "$conf_file" "$conf_url"
          sed -i -e "s|domain|$domain|g" \
            -e "s|main|$escaped_cert|g" \
            "$conf_file"
          setup_site_http2 "$domain"
          restart_webserver
          ;;
        proxy)
          local target_url=$3
          local target_protocol=$4
          local target_port=$5
          wget -O "$conf_file" https://gitlab.com/gebu8f/sh/-/raw/main/nginx/domain_proxy.conf
          sed -i "s|proxy_pass host:port;|proxy_pass $target_protocol://$target_url:$target_port;|g" "$conf_file"
          sed -i -e "s|domain|$domain|g" \
            -e "s|main|$escaped_cert|g" \
            "$conf_file"
          setup_site_http2 "$domain"
          restart_webserver
          ;;
        *)
          echo "不支援的類型: $type"; return 1;;
      esac
      ;;
  esac
}
get_input_or_nav() {
  local input_buffer=""
    
  stty -echo 

  while true; do
    read -rsn1 key # 讀取一個字元
    if [[ "$key" == $'\e' ]]; then
      read -rsn2 -t 0.01 key_rest
      if [[ "$key_rest" == "[C" ]]; then
        stty echo
        echo "NAV_NEXT" # 這是給變數抓的結果
        return
      elif [[ "$key_rest" == "[D" ]]; then
        stty echo
        echo "NAV_PREV" # 這是給變數抓的結果
        return
      fi
        
      # 2. 處理 Enter 鍵
      elif [[ "$key" == "" ]]; then 
        stty echo
        echo "" >&2         # [關鍵修改] 換行顯示給眼睛看 (>&2)
        echo "$input_buffer" # 這是給變數抓的結果 (stdout)
        return
      # 3. 處理 Backspace (刪除鍵)
      elif [[ "$key" == $'\x7f' || "$key" == $'\b' ]]; then
        if [ ${#input_buffer} -gt 0 ]; then
          input_buffer="${input_buffer::-1}"
          echo -ne "\b \b" >&2 # [關鍵修改] 視覺刪除給眼睛看 (>&2)
        fi
      else
        input_buffer+="$key"
        echo -ne "$key" >&2 # [關鍵修改] 打字顯示給眼睛看 (>&2)
      fi
  done
  stty echo
}

show_cert_status() {
  local target_page="$1"
  [ -z "$target_page" ] && target_page=1

  local GREEN='\033[0;32m'
  local BLUE='\033[0;34m'


  # 環境檢查
  check_web_environment
  if [[ $use_my_app != true ]]; then
    echo -e "===== 站點憑證狀態 ====="
    echo -e "${RED}您好,您現在使用其他 web server 無法使用站點憑證狀態之功能${RESET}"
    TOTAL_PAGES_NGINX=1
    return 0
  fi

  display_width() {
    local str="$1"; local width=0; local i=0; local len=${#str}
    while [ $i -lt $len ]; do
      local char="${str:$i:1}"
      if [[ $(printf "%d" "'$char") -gt 127 ]] 2>/dev/null; then width=$((width + 2)); else width=$((width + 1)); fi
            i=$((i + 1))
    done
    echo $width
  }
  pad_str() {
    local text="$1"; local max="$2"; local align="$3"
    local w=$(display_width "$text")
    local pad=$((max - w)); [[ $pad -lt 0 ]] && pad=0
    local spaces; printf -v spaces "%*s" $pad ""
    if [[ "$align" == "right" ]]; then echo "${spaces}${text}"; else echo "${text}${spaces}"; fi
  }

  truncate_domain() {
    local d="$1"
    local max_len=28
    if [ ${#d} -gt $max_len ]; then
      local head="${d:0:5}"
      local tail=".${d##*.}"
      echo "${head}...${tail}"
    else
      echo "$d"
    fi
  }
  local CACHE_DIR="/tmp/site_manager_cert_cache"
  [ ! -d "$CACHE_DIR" ] && mkdir -p "$CACHE_DIR"
  local NGINX_MAP_CACHE="$CACHE_DIR/nginx_domain_map.cache"
  local SSL_DATE_CACHE="$CACHE_DIR/ssl_date_info.cache"
  local SSL_CACHE_TTL=259200
  local nginx_conf_paths=$(detect_conf_path)
  local current_ts=$(date +%s)
    
  # 1. 讀取域名映射
  declare -A domain_map
  local nginx_mod_time=0; [[ -d "$nginx_conf_paths" ]] && nginx_mod_time=$(stat -c %Y "$nginx_conf_paths")
  local map_mod_time=0; [[ -f "$NGINX_MAP_CACHE" ]] && map_mod_time=$(stat -c %Y "$NGINX_MAP_CACHE")

  if (( map_mod_time >= nginx_mod_time )); then
    while IFS='|' read -r dom path; do [[ -n "$dom" ]] && domain_map["$dom"]="$path"; done < "$NGINX_MAP_CACHE"
  else
    > "$NGINX_MAP_CACHE"
    local raw_configs
    if raw_configs=$(grep -rE "server_name|ssl_certificate " "$nginx_conf_paths"/*.conf 2>/dev/null); then
      local cur_domains=""
      while read -r line; do
        if [[ "$line" == *"server_name"* ]]; then
          local tmp=${line#*server_name}; tmp=${tmp%;*}; cur_domains=$(echo "$tmp" | xargs)
        elif [[ "$line" == *"ssl_certificate "* && -n "$cur_domains" ]]; then
          local c_path=${line#*ssl_certificate}; c_path=${c_path%;*}; c_path=$(echo "$c_path" | xargs)
          if [[ "$c_path" == /etc/letsencrypt/live/* ]]; then
            for d in $cur_domains; do [[ -n "$d" ]] && domain_map["$d"]="$c_path" && echo "$d|$c_path" >> "$NGINX_MAP_CACHE"; done
          fi
          cur_domains=""
        fi
      done <<< "$raw_configs"
    fi
  fi

  if [ ${#domain_map[@]} -eq 0 ]; then
    echo -e "${GREEN}目前沒有偵測到任何使用 Let's Encrypt 的域名。${RESET}"
    TOTAL_PAGES_NGINX=1; return 0
  fi

  # 2. 讀取 SSL 快取
  declare -A ssl_cache_data
  local cache_dirty=false
  if [[ -f "$SSL_DATE_CACHE" ]]; then
    while IFS='|' read -r p d n t; do ssl_cache_data["$p"]="$d|$n|$t"; done < "$SSL_DATE_CACHE"
  fi

  declare -A unique_paths
  for d in "${!domain_map[@]}"; do unique_paths["${domain_map[$d]}"]=1; done

  for path in "${!unique_paths[@]}"; do
    if [[ ! -f "$path" ]]; then ssl_cache_data["$path"]="檔案遺失|需檢查|$current_ts"; continue; fi
    local cached_info="${ssl_cache_data[$path]}"
    local need_update=true
    if [[ -n "$cached_info" ]]; then
      IFS='|' read -r _ _ last_ts <<< "$cached_info"
      (( (current_ts - last_ts) < SSL_CACHE_TTL )) && need_update=false
    fi
    if [[ "$need_update" == true ]]; then
      local end_date="讀取失敗"; local note=""
      local cert_out=$(openssl x509 -in "$path" -noout -enddate -issuer 2>/dev/null)
      if [[ -n "$cert_out" ]]; then
        local raw_date=$(echo "$cert_out" | grep 'notAfter' | cut -d= -f2)
        [[ -n "$raw_date" ]] && end_date=$(date -d "$raw_date" +"%Y-%m-%d")
        [[ "$cert_out" == *"CloudFlare"* ]] && note="CF 原始憑證"
      fi
      ssl_cache_data["$path"]="$end_date|$note|$current_ts"
      cache_dirty=true
    fi
  done
  if [[ "$cache_dirty" == true ]]; then
    > "$SSL_DATE_CACHE"
    for p in "${!ssl_cache_data[@]}"; do echo "$p|${ssl_cache_data[$p]}" >> "$SSL_DATE_CACHE"; done
  fi

  # 3. 準備渲染資料
  local -a render_rows=()
  local -a sorted_domains
  IFS=$'\n' sorted_domains=($(sort <<<"${!domain_map[@]}"))
  unset IFS

  for domain in "${sorted_domains[@]}"; do
    [[ -z "$domain" ]] && continue
    local path="${domain_map[$domain]}"
    local cert_name=$(basename "$(dirname "$path")")
    local info="${ssl_cache_data[$path]}"
    IFS='|' read -r e_date note _ <<< "$info"
    local display_date="$e_date"
    if [[ -z "$e_date" ]]; then display_date="${RED}未知${RESET}"; 
    elif [[ "$e_date" == "檔案遺失" ]]; then display_date="${RED}檔案遺失${RESET}"; 
    elif [[ "$e_date" == "讀取失敗" ]]; then display_date="${RED}讀取失敗${RESET}"; fi
    render_rows+=("$domain|$display_date|$cert_name|$note")
  done

    # 4. 分頁計算
    local total_rows=${#render_rows[@]}
    local page_size=10
    TOTAL_PAGES_NGINX=$(( (total_rows + page_size - 1) / page_size ))
    [[ $TOTAL_PAGES_NGINX -eq 0 ]] && TOTAL_PAGES_NGINX=1
    
    if [ "$target_page" -gt "$TOTAL_PAGES_NGINX" ]; then target_page=$TOTAL_PAGES_NGINX; fi
    if [ "$target_page" -lt 1 ]; then target_page=1; fi
    CURRENT_PAGE_NGINX=$target_page

    local start_index=$(( (target_page - 1) * page_size ))
    local end_index=$(( start_index + page_size - 1 ))
    if [ $end_index -ge $total_rows ]; then end_index=$(( total_rows - 1 )); fi

    # 5. 渲染輸出
    local headers=("域名" "到期日" "憑證資料夾" "備註")
    local -a col_widths=(0 0 0 0)
    for i in "${!headers[@]}"; do col_widths[$i]=$(display_width "${headers[$i]}"); done

    local -a page_data=()
    for ((i=start_index; i<=end_index; i++)); do
        IFS='|' read -r d date c n <<< "${render_rows[$i]}"
        
        # 套用新的縮略邏輯
        local display_d=$(truncate_domain "$d")
        
        local clean_date=$(echo -e "$date" | sed "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        local w_d=${#display_d}
        local w_date=$(display_width "$clean_date")
        local w_c=$(display_width "$c")
        local w_n=$(display_width "$n")

        [ $w_d -gt ${col_widths[0]} ] && col_widths[0]=$w_d
        [ $w_date -gt ${col_widths[1]} ] && col_widths[1]=$w_date
        [ $w_c -gt ${col_widths[2]} ] && col_widths[2]=$w_c
        [ $w_n -gt ${col_widths[3]} ] && col_widths[3]=$w_n
        
        page_data+=("$display_d|$date|$c|$n")
    done

    echo -e "===== 站點憑證狀態 ====="
    local header_line=""
    for i in {0..3}; do
        header_line+=$(pad_str "${headers[$i]}" "${col_widths[$i]}" "left")
        [[ $i -lt 3 ]] && header_line+=" | "
    done
    echo -e "${BLUE}${header_line}${RESET}"

    for row in "${page_data[@]}"; do
        IFS='|' read -r d date c n <<< "$row"
        local line=""
        line+=$(pad_str "$d" "${col_widths[0]}" "left") && line+=" | "
        
        local clean_date=$(echo -e "$date" | sed "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        local pad_len=$(( ${col_widths[1]} - $(display_width "$clean_date") ))
        line+="$date"; printf -v sp "%*s" $pad_len ""; line+="$sp | "
        
        line+=$(pad_str "$c" "${col_widths[2]}" "left") && line+=" | "
        line+=$(pad_str "$n" "${col_widths[3]}" "left")
        echo -e "$line"
    done
    
    echo -e "${GRAY}頁碼: $CURRENT_PAGE_NGINX / $TOTAL_PAGES_NGINX${RESET}"
}

show_domain_status_caddy() (
  echo "===== Caddy 站點域名列表 ====="

  local CADDY_CONF_MAIN="/etc/caddy/Caddyfile"
  local CADDY_CONF_DIR=$(detect_conf_path)

  if [[ ! -f "$CADDY_CONF_MAIN" ]]; then
      echo "未找到 Caddy 主配置：$CADDY_CONF_MAIN"
      return 1
  fi

  declare -A domain_set

  # --- 解析 domain {...} 格式 ---
  parse_domains() {
    local file="$1"
    while IFS= read -r line; do
      # 僅匹配：
      #   example.com {
      #   sub.domain.net {
      if [[ "$line" =~ ^([A-Za-z0-9._-]+)\ \{$ ]]; then
        domain_set["${BASH_REMATCH[1]}"]=1
      fi
    done < "$file"
  }

  # 主 Caddyfile
  parse_domains "$CADDY_CONF_MAIN"

  # import conf.d/*.caddy
  if [[ -d "$CADDY_CONF_DIR" ]]; then
    while IFS= read -r f; do
      parse_domains "$f"
    done < <(find "$CADDY_CONF_DIR" -maxdepth 1 -type f -name "*.conf")
  fi

  # --- 輸出 ---
  
  if [[ ${#domain_set[@]} -eq 0 ]]; then
    echo "找不到任何域名。"
    return 0
  fi

  echo "域名"
  echo "----"

  for domain in "${!domain_set[@]}"; do
    echo "$domain"
  done | sort
)


show_httpguard_status(){

  get_module_state() {
  # 自動偵測 config.lua 路徑
  if [ -f "/usr/local/openresty/nginx/conf/HttpGuard/config.lua" ]; then
    config_file="/usr/local/openresty/nginx/conf/HttpGuard/config.lua"
  elif [ -f "/etc/nginx/HttpGuard/config.lua" ]; then
    config_file="/etc/nginx/HttpGuard/config.lua"
  else
    echo "錯誤：HttpGuard/config.lua 未找到。請確認安裝目錄或文件路徑。"
    return 1
  fi
    local module_name=$1
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    grep -E "^\s*${module_name}\s*=" "$config_file" | \
    grep -oE 'state\s*=\s*["'\''][^"'\'']*["'\'']' | \
    sed -E 's/.*state\s*=\s*["'\''](.*)["'\'']/\1/' | \
    head -n 1
  }

  echo "--- HttpGuard 主動防禦與自動開啟狀態 ---"

  redirect_state=$(get_module_state "redirectModules")
  jsjump_state=$(get_module_state "JsJumpModules")
  cookie_state=$(get_module_state "cookieModules")
  auto_enable_state=$(get_module_state "autoEnable")
  
  echo -e "${CYAN}主動防禦 (302 Redirect Modules) 狀態: ${redirect_state:-未找到} ${RESET}"
  echo -e "${CYAN}主動防禦 (JS Jump Modules) 狀態: ${jsjump_state:-未找到} ${RESET}"
  echo -e "${CYAN}主動防禦 (Cookie Modules) 狀態: ${cookie_state:-未找到} ${RESET}"
  echo -e "${CYAN}自動開啟主動防禦 狀態: ${auto_enable_state:-未找到} ${RESET}"
  echo "-------------------------------------"
}


show_php() {
  local wp_root="/var/www"

  echo "===== 已安裝 PHP 網站列表 ====="
  printf "%-20s | %-10s\n" "網址" "備註"
  echo "-------------------------------------------"

  [[ -d "$wp_root" ]] || return 0

  find "$wp_root" -mindepth 1 -maxdepth 1 -type d -name '*.*' -print0 | \
  while IFS= read -r -d '' site_dir; do

    [[ -f "$site_dir/index.php" ]] || continue

    local site_name
    site_name=$(basename "$site_dir")

    local remark="PHP網站"

    if [[ -f "$site_dir/wp-config.php" ]]; then
      remark="WordPress"
    elif [[ -f "$site_dir/public/assets/forum.js" ]] || \
         grep -qi "flarum" "$site_dir/index.php" 2>/dev/null; then
      remark="Flarum"
    elif [[ -f "$site_dir/usr/index.php" ]] || \
         grep -qi "Typecho" "$site_dir/index.php" 2>/dev/null; then
      remark="Typecho"
    fi

    printf "%-20s | %-10s\n" "$site_name" "$remark"
  done
}

ssl_apply() {
  check_acme
  # --- 1. 處理域名與路徑 ---
  local domains="$1"
  if [ -z "$domains" ]; then
    read -p "請輸入您的域名（只能用空白鍵分隔）：" domains
  fi
  
  # 陣列轉換 (處理逗號或空格)
  IFS=$' ,\n' read -ra domain_array <<< "$domains"
  
  # 找出主域名 (非泛域名優先)
  local main_domain=""
  local non_wildcard_found=0
  for d in "${domain_array[@]}"; do
    if [[ "$d" != "*."* ]]; then
      main_domain="$d"
      non_wildcard_found=1
      break
    fi
  done
  # 如果全是泛域名，取第一個
  [ $non_wildcard_found -eq 0 ] && main_domain="${domain_array[0]}"
  
  # 準備目標目錄
  local cert_dir_name=""
  if [[ "$main_domain" == "*."* ]]; then
    cert_dir_name="${main_domain#*.}"
  else
    cert_dir_name="$main_domain"
  fi
  
  local target_dir="/etc/letsencrypt/live/$cert_dir_name"

  # 準備 acme.sh 參數 (-d domain1 -d domain2 ...)
  local -a domain_args=()
  for d in "${domain_array[@]}"; do
    domain_args+=("-d" "$d")
  done

  # --- 2. 選擇驗證方式 ---
  echo "選擇驗證方式："
  echo "1) DNS API (Cloudflare、DNSPod、Aliyun)"
  echo "2) DNS Manual (手動添加 TXT)"
  echo "3) HTTP (網站目錄驗證)"
  read -p "選擇 [1-3]（預設 3）:" auth_method
  auth_method="${auth_method:-3}"

  case "$auth_method" in
  1) # DNS API
    ACME_CONF="$HOME/.acme.sh/account.conf"
    
    echo "請選擇 DNS 服務商："
    echo "  1) Cloudflare"
    echo "  2) DNSPod.cn"
    echo "  3) Aliyun"
    read -p "請選擇 [1-3]：" dns_num

    local dns_plugin=""
    local check_key=""
    local extra_tip=""
    local -a input_vars=()
    local -a input_prompts=()
    
    case $dns_num in
    1)
      dns_plugin="dns_cf"
      check_key="SAVED_CF_Token"
      input_vars=("CF_Token" "CF_Account_ID")
      input_prompts=("請輸入 Cloudflare API Token" "請輸入 Cloudflare Account ID")
      ;;
    2)
      dns_plugin="dns_dp"
      check_key="SAVED_DP_Id"
      input_vars=("DP_Id" "DP_Key")
      input_prompts=("請輸入 DNSPod ID" "請輸入 DNSPod Key")
      ;;
    3)
      dns_plugin="dns_ali"
      check_key="SAVED_Ali_Key"
      extra_tip="提示：請至 RAM 控制台獲取 AccessKey (https://ram.console.aliyun.com/users)"
      input_vars=("Ali_Key" "Ali_Secret")
      input_prompts=("請輸入 Aliyun AccessKey ID" "請輸入 Aliyun AccessKey Secret")
      ;;
    *) echo -e "${RED}無效選擇${RESET}"; return 1 ;;
    esac

    # 通用檢查與輸入邏輯
    if [ ! -f "$ACME_CONF" ] || ! grep -q "$check_key" "$ACME_CONF"; then
      echo
      [ -n "$extra_tip" ] && echo -e "${YELLOW}${extra_tip}${RESET}"
      echo -e "${YELLOW}未檢測到 $dns_plugin 的憑證，請輸入：${RESET}"
      for ((i=0; i<${#input_vars[@]}; i++)); do
        echo
        read -s -p "${input_prompts[$i]}： " user_input
        echo
        export "${input_vars[$i]}=$user_input"
      done
    fi
    acme.sh --issue --dns "$dns_plugin" "${domain_args[@]}" || return 1
    ;;

  2) # DNS Manual
    read -p "此方式不支援自動續訂，是否繼續? (y/n) " continue_choice
    [[ ! "$continue_choice" =~ ^[Yy]$ ]] && { echo "已取消。"; return 0; }
    
    # 第一步：獲取 TXT 記錄
    acme.sh --issue --dns "${domain_args[@]}" --yes-I-know-dns-manual-mode-enough-go-ahead-please
    
    echo -e "\n${YELLOW}請去 DNS 後台添加上述 TXT 記錄。${RESET}"
    read -p "添加完成後，請按任意鍵繼續驗證..." -n1
    
    # 第二步：驗證
    acme.sh --renew "${domain_args[@]}" --yes-I-know-dns-manual-mode-enough-go-ahead-please || return 1
    ;;

  3) # HTTP
    [[ "$domains" =~ \*\. ]] && echo "HTTP驗證不支援萬用字元域名。" >&2 && return 1
    
    local detect_conf_path=$(detect_conf_path)
    mkdir -p /var/www/acme
    
    # 下載模板
    wget -O "$detect_conf_path/acme.conf" https://gitlab.com/gebu8f/sh/-/raw/main/nginx/domain_http.conf || { echo "下載模板失敗"; return 1; }
    
    # 轉換陣列為空格分隔字串，確保 Nginx 語法正確
    local nginx_domains="${domain_array[*]}"
    sed -i "s|domain|$nginx_domains|g" "$detect_conf_path/acme.conf"
    
    restart_webserver
    
    # 執行驗證
    acme.sh --issue "${domain_args[@]}" -w /var/www/acme
    local ret=$? # 記錄結果
    
    # 清理並恢復
    rm -f "$detect_conf_path/acme.conf"
    restart_webserver
    
    # 如果驗證失敗，中斷流程
    [ $ret -ne 0 ] && return 1
    ;;
    
  *) echo "無效的選擇。" >&2; return 1 ;;
  esac

  mkdir -p "$target_dir"
  local reload_cmd=""
  if [ -n "$docker_name" ]; then
    reload_cmd="docker restart $docker_name"
  else
    # 根據 system 判斷
    case "$system" in
    1|2) reload_cmd="systemctl reload nginx || systemctl reload openresty" ;;
    3) reload_cmd="rc-service nginx reload" ;;
    esac
  fi
  acme.sh --install-cert -d "$main_domain" \
    --fullchain-file "$target_dir/fullchain.pem" \
    --key-file       "$target_dir/privkey.pem" \
    --reloadcmd      "$reload_cmd"

  echo -e "${GREEN}證書申請與安裝完成！${RESET}"
}

toggle_httpguard_module() {
  local module_name=$1
  local current_state=$2
  local config_file
  
  if [ -f /usr/local/openresty/nginx/conf/HttpGuard/config.lua ]; then
    config_file="/usr/local/openresty/nginx/conf/HttpGuard/config.lua"
  elif [ -f /etc/nginx/HttpGuard/config.lua ]; then
    config_file="/etc/nginx/HttpGuard/config.lua"
  fi

  local new_state=""
  if [ "$current_state" = "On" ]; then
    new_state="Off"
  elif [ "$current_state" = "Off" ]; then
    new_state="On"
  else
    echo "錯誤：無法識別的當前狀態 '$current_state'。"
    return 1
  fi
  sed -i "/^\s*${module_name}\s*=/ s/state\s*=\s*\"[^\"]*\"/state = \"$new_state\"/" "$config_file"

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}模組 [$module_name] 狀態已更新為 [$new_state]。${RESET}"
    restart_webserver
    if ! [ $? -eq 0 ]; then
      echo -e "${RED}Nginx/OpenResty 重啟失敗，請手動檢查配置。${RESET}"
    fi
  else
    echo -e "${RED}更新模組 [$module_name] 狀態失敗。${RESET}"
  fi
}

update_script() {
  local download_url="https://gitlab.com/gebu8f/sh/-/raw/main/nginx/ng.sh"
  local temp_path="/tmp/ng.sh"
  local current_script="/usr/local/bin/site"
  local current_path="$0"

  echo "正在檢查更新..."
  wget -q "$download_url" -O "$temp_path"
  if [ $? -ne 0 ]; then
    echo -e "${RED}無法下載最新版本，請檢查網路連線。${RESET}"
    return
  fi

  # 比較檔案差異
  if [ -f "$current_script" ]; then
    if diff "$current_script" "$temp_path" >/dev/null; then
      echo -e "${GREEN}腳本已是最新版本，無需更新。${RESET}"
      rm -f "$temp_path"
      return
    fi
    echo "正在更新..."
    cp "$temp_path" "$current_script" && chmod +x "$current_script"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}更新成功！將自動重新啟動腳本以套用變更...${RESET}"
      sleep 1
      exec "$current_script"
    else
      echo -e "${RED}更新失敗，請確認權限。${RESET}"
    fi
  else
    # 非 /usr/local/bin 執行時 fallback 為當前檔案路徑
    if diff "$current_path" "$temp_path" >/dev/null; then
      echo -e "${GREEN}腳本已是最新版本，無需更新。${RESET}"
      rm -f "$temp_path"
      return
    fi
    echo "檢測到新版本，正在更新..."
    cp "$temp_path" "$current_path" && chmod +x "$current_path"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}更新成功！將自動重新啟動腳本以套用變更...${RESET}"
      sleep 1
      exec "$current_path"
    else
      echo -e "${RED}更新失敗，請確認權限。${RESET}"
    fi
  fi

  rm -f "$temp_path"
}

uninstall_webserver(){
  check_web_server # 獲取當前環境狀態與 docker_name
  
  if [ -n "$docker_name" ]; then
    docker stop "$docker_name" >/dev/null 2>&1
    docker rm -f "$docker_name" >/dev/null 2>&1
  fi

  if [ "$openresty" -eq 1 ]; then
    case $system in
    1|2) systemctl disable openresty >/dev/null 2>&1 ;;
    3) rc-update del openresty default >/dev/null 2>&1 ;;
    esac
    service openresty stop >/dev/null 2>&1
    
    case $system in
    1) apt purge -y openresty ;;
    2) dnf remove -y openresty ;;
    3) apk del openresty ;;
    esac
    pkill -f openresty >/dev/null 2>&1
    pkill -f nginx >/dev/null 2>&1
    
    # 清理符號連結與目錄
    unlink /etc/nginx >/dev/null 2>&1
    unlink /usr/sbin/nginx >/dev/null 2>&1
    rm -rf /usr/local/openresty

  elif [ "$nginx" -eq 1 ]; then
    case $system in
    1|2) systemctl disable nginx >/dev/null 2>&1 ;;
    3) rc-update del nginx default >/dev/null 2>&1 ;;
    esac
    service nginx stop >/dev/null 2>&1
    
    case $system in
    1) apt purge -y nginx* ;;
    2) dnf remove -y nginx ;;
    3) 
      apk del nginx
      rm -rf /etc/init.d/nginx
    ;;
    esac
    
    local nginx_path=$(command -v nginx)
    [ -n "$nginx_path" ] && rm -rf "$nginx_path"
    pkill -f nginx >/dev/null 2>&1

  elif [ "$caddy" -eq 1 ]; then
    case $system in
    1) apt purge -y caddy ;;
    2) dnf remove -y caddy ;;
    esac
    rm -rf /etc/caddy
  fi
  if [[ $openresty -eq 1 || $nginx -eq 1 ]]; then
    rm -rf /etc/nginx
    rm -rf /home/web
  fi
  
  echo -e "${GREEN}解除安裝完成！所有配置與服務已清除。${RESET}"
  
  exit 0
}



wordpress_site() {
  trap 'rm -f /tmp/wordpress.zip; rm -rf /tmp/wordpress' EXIT
  local MY_IP=$(curl -s https://api64.ipify.org)
  local ngx_user=$(get_web_run_user)

  if ! curl -s --connect-timeout 3 https://wordpress.org >/dev/null; then
    echo "您的IP地址不支持訪問 WordPress。"
    if [[ "$MY_IP" == *:* ]]; then
      echo "您目前是 IPv6，請使用 WARP 等方式將流量轉為 IPv4 以正常訪問 WordPress。"
    fi
    return 1
  fi
  if ! command -v dba >/dev/null 2>&1; then
    bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh) install_script
  fi
  if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
    dba mysql install true
  fi
  read -p "請輸入您的 WordPress 網址（例如 wp.example.com）：" domain

  # 自動申請 SSL（若不存在）
  check_cert "$domain" || {
    echo "未偵測到 Let Encrypt 憑證，嘗試自動申請..."
    if ssl_apply "$domain"; then
      echo "申請成功，重新驗證憑證..."
        check_cert "$domain" || {
          echo "申請成功但仍無法驗證憑證，中止建立站點"
          return 1
        }
    else
      echo "SSL 申請失敗，中止建立站點"
      return 1
    fi
  }

  
  read -p "是否還原現有的wp文件？(Y/N): " restore_file
  restore_file=${restore_file,,}
  if [[ $restore_file == "y" || $restore_file == "" ]]; then
    restore_site_files wp "$domain"
  else
    # 下載 WordPress 並部署
    mkdir -p "/var/www/$domain"
    curl -L https://wordpress.org/latest.zip -o /tmp/wordpress.zip
    unzip /tmp/wordpress.zip -d /tmp
    mv /tmp/wordpress/* "/var/www/$domain/"
    local db_name="wp_$(echo $domain | sed 's/\./_/g; s/-//g')"
    local db_user="${db_name}_user"
    local db_pass=$(dba mysql add $db_name $db_user false)

    # 設定 wp-config.php
    cp "/var/www/$domain/wp-config-sample.php" "/var/www/$domain/wp-config.php"
    sed -i "s/database_name_here/$db_name/" "/var/www/$domain/wp-config.php"
    sed -i "s/username_here/$db_user/" "/var/www/$domain/wp-config.php"
    sed -i "s/password_here/$db_pass/" "/var/www/$domain/wp-config.php"
    sed -i "s/localhost/localhost/" "/var/www/$domain/wp-config.php"
    # 安全金鑰
    if command -v wp >/dev/null 2>&1; then
      wp config shuffle-salts --path="/var/www/$domain" --allow-root
    else
      curl -s https://api.wordpress.org/secret-key/1.1/salt/ > /tmp/wp_salts.txt
      sed -i "/define.*'AUTH_KEY'/i WP_SALTS" "/var/www/$domain/wp-config.php"
      sed -i "/put your unique phrase here/d" "/var/www/$domain/wp-config.php"
      sed -i "/WP_SALTS/r /tmp/wp_salts.txt" "/var/www/$domain/wp-config.php"
      sed -i "/WP_SALTS/d" "/var/www/$domain/wp-config.php"
      rm -f /tmp/wp_salts.txt
    fi
    # 設定權限
    rhel_selinux_enforcing_permissions "/var/www/$domain" label
    rhel_selinux_enforcing_permissions "/var/www/$domain" permissions
  fi
  setup_site "$domain" php
  if ! is_db_done; then
    read -p "是否要導入現有 SQL 資料？(Y/N): " import_sql
    import_sql=${import_sql,,}
    if [[ $import_sql == "y" || $import_sql == "" ]]; then
      restore_site_db wp $domain
      return 0
    fi
  else
    unset is_db_done
  fi
  echo "WordPress 網站 $domain 建立完成！請瀏覽 https://$domain。"
}


self_signed_certificate()(
  read -p "請輸入您的域名或 IP 地址 (Common Name)：" domain
  

  mkdir -p /etc/letsencrypt/live/$domain
  
  # 設置憑證和金鑰的完整路徑
  CERT_DIR="/etc/letsencrypt/live/$domain"
  KEY_FILE="$CERT_DIR/privkey.pem"
  CERT_FILE="$CERT_DIR/fullchain.pem"
  
  # 3. 檢查目錄是否已存在憑證，避免覆蓋
  if [ -f "$KEY_FILE" ] && [ -f "$CERT_FILE" ]; then
    read -p "警告：憑證已存在於 $domain，是否要覆蓋？(y/N)[預設:n] " response
    response=${response,,}
    if ! [[ "$response" =~ ^(y|yes)$ ]]; then
      echo "操作已取消。"
      return 0
    fi
  fi
  
  
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/C=GB/ST=Globe/L=Globe/O=gebu8f7/OU=IT/CN=$domain" 
    
  # --- 5. 完成與提示 ---
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}自簽名憑證生成成功！${RESET}"
    echo "   域名/IP (CN): $domain"
    echo "   私鑰路徑: $KEY_FILE"
    echo "   憑證路徑: $CERT_FILE"
    
    chmod 700 "$KEY_FILE"
  fi
)


# 菜單

menu_reset_dns_token() {
  local ACME_CONF="$HOME/.acme.sh/account.conf"
  
  if [ ! -f "$ACME_CONF" ]; then
    echo -e "${RED}尚未有任何 acme.sh 設定檔。${RESET}"
    return 1
  fi

  echo "請選擇要重置（清除）的 DNS 憑證："
  echo "  1) Cloudflare"
  echo "  2) DNSPod.cn"
  echo "  3) Aliyun"
  read -p "請選擇：" choice

  case $choice in
    1)
      # 使用 sed 刪除包含特定關鍵字的行
      # SAVED_CF_Token 和 SAVED_CF_Account_ID
      sed -i "/SAVED_CF_/d" "$ACME_CONF"
      echo -e "${GREEN}Cloudflare 憑證已清除。${RESET}"
      echo "下次申請證書時，系統將會提示您輸入新的 Token。"
      ;;
    2)
      sed -i "/SAVED_DP_/d" "$ACME_CONF"
      echo -e "${GREEN}DNSPod 憑證已清除。${RESET}"
      echo "下次申請證書時，系統將會提示您輸入新的 ID/Key。"
      ;;
    3)
      sed -i "/SAVED_Ali_/d" "$ACME_CONF"
      echo -e "${GREEN}Aliyun 憑證已清除。${RESET}"
      echo "下次申請證書時，系統將會提示您輸入新的 AccessKey。"
      ;;
    *)
      echo -e "${RED}無效選擇${RESET}"
      ;;
  esac
}

menu_httpguard(){
  clear
  echo "HttpGuard管理"
  echo "-------------------"
  show_httpguard_status
  echo "-------------------"
  echo "1. 開啟/關閉 302 重定向 (redirectModules)"
  echo "2. 開啟/關閉 JS 跳轉 (JsJumpModules)"
  echo "3. 開啟/關閉 Cookie 認證 (cookieModules)"
  echo "4. 開啟/關閉 自動開啟主動防禦 (autoEnable)"
  echo "5. 卸載 HttpGuard"
  echo "0. 退出"
  echo -n -e "\033[1;33m請選擇操作 [0-5]: \033[0m"
  read -r choice
  case $choice in
    1)
      local current_state=$(get_module_state "redirectModules")
      toggle_httpguard_module "redirectModules" "$current_state"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    2)
      local current_state=$(get_module_state "JsJumpModules")
      toggle_httpguard_module "JsJumpModules" "$current_state"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    3)
      local current_state=$(get_module_state "cookieModules")
      toggle_httpguard_module "cookieModules" "$current_state"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    4)
      local current_state=$(get_module_state "autoEnable")
      toggle_httpguard_module "autoEnable" "$current_state"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    5)
    sed -i '/HttpGuard\/init.lua\|HttpGuard\/runtime.lua\|lua_package_path\|lua_package_cpath\|lua_shared_dict guard_dict\|lua_shared_dict dict_captcha\|lua_max_running_timers/d' "$ngx_conf"
    rm -rf "/etc/nginx/HttpGuard"
    restart_webserver
    echo "HttpGuard 卸載完成。"
    read -p "操作完成，請按任意鍵繼續..." -n1
    ;;
    0)
      return 0
      ;;
    *)
      echo "無效的選擇，請重新輸入。"
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
  esac
}

menu_add_sites(){
  clear
  echo "新增站點"
  echo "-------------------"
  echo "1. 添加站點（HTML）"
  echo ""
  echo "2. 反向代理"
  echo "-------------------"
  echo "0. 退出"
  echo -n -e "\033[1;33m請選擇操作 [0-2]: \033[0m"
  read -r choice
  case $choice in
    1)
      html_sites
      ;;
    2)
      reverse_proxy
      ;;
    0)
      return 0
      ;;
    *)
      echo "無效選擇。"
  esac
}

menu_del_sites() {
  local conf_dir=$(detect_conf_path)

  # 取得所有 .conf
  local raw_files=("$conf_dir"/*.conf)
  local site_files=()

  # 過濾掉 basename 不含 "." 的
  for f in "${raw_files[@]}"; do
    local name=$(basename "$f" .conf)
    if [[ "$name" == *.* ]]; then
      site_files+=("$f")
    fi
  done

  if [ ${#site_files[@]} -eq 0 ]; then
    echo "目前沒有任何可刪除的站點。"
    return 1
  fi

  echo "請選擇要刪除的站點："
  local idx=1
  for f in "${site_files[@]}"; do
    local name=$(basename "$f" .conf)
    echo "  $idx) $name"
    idx=$((idx + 1))
  done

  echo
  read -p "請輸入數字：" choice

  # 非數字
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "無效的選擇。"
    return 1
  fi

  local max=${#site_files[@]}
  if (( choice < 1 || choice > max )); then
    echo "選擇超出範圍。"
    return 1
  fi

  local conf_file="${site_files[$((choice - 1))]}"
  local domain=$(basename "$conf_file" .conf)

  read -p "確定要刪除站點 [$domain] 嗎？(Y/n) " confirm
  confirm=${confirm,,}

  if [[ "$confirm" != "y" && "$confirm" != "" ]]; then
    return 0
  fi
  
  local site_type=$(detect_site_type "/var/www/$domain")
  
  # SSL 吊銷
  menu_ssl_revoke "$domain" || {
    echo "吊銷 SSL 失敗，停止操作。"
    return 1
  }

  # 刪除配置與網站資料夾
  rm -rf "$conf_file"
  rhel_selinux_cleanup_permissions "/var/www/$domain"

  # 刪除資料庫
  if [ $site_type = wp ]; then
    db_name=$(awk -F"'" '/DB_NAME/{print $4}' "/var/www/$domain/wp-config.php")
  elif [ $site_type = flarum ]; then
    db_name=$(php -r "\$c = include "/var/www/$domain/config.php"; echo \$c['database']['database'] ?? '';")
  fi
  
  rm -rf "/var/www/$domain"
  
  if [ $site_type != "unknown" ]; then
    if ! command -v dba >/dev/null 2>&1; then
      bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh) install_script
    fi
    dba mysql del "$db_name" --force
  fi

  restart_webserver
  echo -e "${GREEN}已刪除站點：$domain${RESET}"
}

menu_ssl_apply() {
  [ $caddy -eq 1 ] && return 0
  echo "SSL 申請"
  echo "-------------------"
  echo "1. acme(Let's Encrypt) 憑證"
  echo ""
  echo "2. Cloudflare 原始憑證"
  echo ""
  echo "3. 自簽名"
  echo "-------------------"
  echo "0. 返回"
  read -p "請選擇: " ssl_choice
  case "$ssl_choice" in
    1) 
      ssl_apply
      ;;
    2) 
      cf_cert_autogen
      ;;
    3)
      self_signed_certificate
      ;;
    0) return ;;
  esac
}

menu_ssl_revoke() {
  local cert_dir="/etc/letsencrypt/live"
  local domain_to_check="$1"

  if [ -z "$domain_to_check" ]; then
    if [ ! -d "$cert_dir" ] || [ -z "$(find "$cert_dir" -mindepth 1 -maxdepth 1 -type d)" ]; then
      echo -e "${RED}錯誤：找不到任何已安裝的證書。${RESET}"
      return 1
    fi
    
    local domain_list=()
    for dir in "$cert_dir"/*; do
      [ -d "$dir" ] && domain_list+=("$(basename "$dir")")
    done

    echo "請選擇要操作的證書 (Certificate Name)："
    local idx=1
    for d in "${domain_list[@]}"; do
      echo "  $idx) $d"
      ((idx++))
    done

    echo
    read -p "請輸入數字：" choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#domain_list[@]} )); then
      echo -e "${RED}無效的選擇。${RESET}"
      return 1
    fi
    domain_to_check="${domain_list[$((choice - 1))]}"
  fi

  local cert_info
  if ! cert_info=$(check_cert "$domain_to_check"); then
    echo -e "${RED}錯誤：無法在系統中找到與 '$domain_to_check' 相關的有效證書。${RESET}"
    return 1
  fi
  
  local cert_path="/etc/letsencrypt/live/$cert_info/fullchain.pem"
  if [ ! -f "$cert_path" ]; then
    echo -e "${RED}錯誤：找不到證書檔案: $cert_path${RESET}"
    return 1
  fi

  # --- 3. 顯示資訊並確認操作 ---
  echo -e "\n${CYAN}--- 證書資訊 ---${RESET}"
  openssl x509 -in "$cert_path" -noout -text | grep -A1 "Subject Alternative Name"
  echo -e "${YELLOW}你將要操作的證書是: ${RESET}${GREEN}${cert_info}${RESET}"
  echo
  read -p "確定要停止自動續訂此證書嗎？[y/n]: " confirm
  [[ "$confirm" != "y" ]] && echo "操作已取消。" && return 0

  # --- 4. 處理特殊 Cloudflare Origin Cert (保持你原本的邏輯) ---
  if openssl x509 -in "$cert_path" -noout -subject | grep -i -q "CloudFlare Origin Certificate"; then
    cf_cert_revoke "$cert_info" || return 1
    return 0
  fi

  local managed_by_acme=0
  
  # 優先嘗試 acme.sh
  if [ -f "$HOME/.acme.sh/acme.sh" ]; then
    # 載入環境，防止找不到指令
    [ -f "$HOME/.acme.sh/acme.sh.env" ] && . "$HOME/.acme.sh/acme.sh.env"
    
    # acme.sh 會自動判斷 ECC/RSA
    if acme.sh --remove -d "$cert_info" --yes &>/dev/null; then
       echo -e "${GREEN}acme.sh: 已成功從續期列表中移除 '$cert_info'。${RESET}"
       managed_by_acme=1
    fi
  fi
  
  # 如果 acme.sh 沒管理此證書，或者沒裝，則嘗試 Certbot
  if [ $managed_by_acme -eq 0 ] && command -v certbot &>/dev/null; then
    if certbot certificates 2>/dev/null | grep -q "Certificate Name: $cert_info"; then
       # certbot delete 會同時停止續期並刪除檔案
      certbot delete --cert-name "$cert_info" --non-interactive
      echo -e "${GREEN}Certbot: 已刪除證書 '$cert_info'。${RESET}"
    fi
  fi

  echo
  read -p "是否徹底刪除磁碟上的所有相關檔案？(這將刪除 /etc/letsencrypt/ 下的檔案) [y/N，預設:N]: " confirm_delete
  confirm_delete=${confirm_delete,,}
  confirm_delete=${confirm_delete:-n}
  
  if [ "$confirm_delete" == "y" ]; then
    echo "正在刪除檔案..."
    rm -rf "/etc/letsencrypt/live/$cert_info"
    rm -rf "/etc/letsencrypt/archive/$cert_info"
    rm -f "/etc/letsencrypt/renewal/$cert_info.conf"
    
    if [ $managed_by_acme -eq 1 ]; then
        rm -rf "$HOME/.acme.sh/${cert_info}_ecc"
        rm -rf "$HOME/.acme.sh/${cert_info}"
    fi
    echo -e "${GREEN}檔案刪除完成。${RESET}"
  fi
}

menu_wp(){
  while true; do
  clear
  echo "WordPress站點"
  echo "-------------------"
  detect_sites WordPress
  echo "-------------------"
  echo "WordPress管理"
  echo -e "${YELLOW}1. 部署WordPress站點${RESET}"
  echo ""
  echo "2. 安裝插件         3. 移除插件"
  echo ""
  echo "4. 部署主題         5. 移除主題"
  echo ""
  echo "6. 修改管理員帳號   7. 修改管理員密碼"
  echo ""
  echo -e "${YELLOW}8. 修復網站崩潰（禁用所有插件和恢復預設主題，慎用）${RESET}"
  echo ""
  echo "0. 返回"
  echo -n -e "\033[1;33m請選擇操作 [0-10]: \033[0m"
    read -r choice
    case $choice in
    0)
      break
      ;;
    1)
      wordpress_site
      ;;
    2)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      install_wp_plugin_with_search_or_url $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    3)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      remove_wp_plugin_with_menu $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    4)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      deploy_or_remove_theme  install $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    5)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      deploy_or_remove_theme  remove $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    6)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      change_wp_admin_username $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    7)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      change_wp_admin_password $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    8)
      install_wpcli_if_needed
      local domain=$(detect_sites_menu WordPress)
      reset_wp_site $domain
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    esac
done
}

menu_restore_site() {
  local domain site_type choice

  echo "--- 網站還原工具 ---"
  
  # === 步驟 1: 從 Nginx 設定檔選擇域名 (邏輯內聯) ===
  local conf_dir
  conf_dir=$(detect_conf_path)
  if [ $? -ne 0 ]; then # 假設 detect_conf_path 失敗會回傳非 0
      echo -e "${RED}無法偵測到 Nginx 設定檔目錄。${RESET}" >&2
      sleep 1
      return 1
  fi

  # 使用 mapfile 結合 find 來安全地處理檔名和過濾
  mapfile -t site_files < <(find "$conf_dir" -maxdepth 1 -type f -name "*.conf" -exec bash -c 'name=$(basename "$0" .conf); [[ "$name" == *.* ]]' {} \; -print)

  if [ ${#site_files[@]} -eq 0 ]; then
    echo -e "${YELLOW}目前 Nginx 設定中沒有任何可還原的站點。${RESET}" >&2
    sleep 1
    return 1
  fi

  echo "請選擇要還原的站點："
  local idx=1
  for f in "${site_files[@]}"; do
    local name
    name=$(basename "$f" .conf)
    printf "%3d) %s\n" "$idx" "$name"
    idx=$((idx + 1))
  done

  read -p "請輸入數字：" choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#site_files[@]} )); then
    echo -e "${RED}無效的選擇。${RESET}" >&2
    sleep 1
    return 1
  fi
  domain=$(basename "${site_files[$((choice - 1))]}" .conf)
  echo -e "${CYAN}您選擇了站點: $domain${RESET}"
  echo

  # === 步驟 2: 選擇網站類型 (邏輯內聯) ===
  echo "請選擇 '$domain' 的網站類型："
  echo "  1) WordPress"
  echo "  2) Flarum"
  read -p "請輸入數字：" choice
  
  case "$choice" in
    1) site_type="wp" ;;
    2) site_type="flarum" ;;
    *)
      echo -e "${RED}無效的選擇。${RESET}" >&2
      sleep 1
      return 1
      ;;
  esac
  echo -e "${CYAN}您選擇了類型: $site_type${RESET}"
  echo

  # === 步驟 3: 選擇要執行的操作 ===
  echo "請選擇要對 '$domain' ($site_type) 執行的操作："
  echo "  1) 還原文件 (包含資料庫)"
  echo "  2) 僅還原資料庫"
  echo "  0) 返回"
  read -p "請輸入數字 [0-2]: " choice

  case "$choice" in
    1)
      restore_site_files "$site_type" "$domain"
      ;;
    2)
      restore_site_db "$site_type" "$domain"
      ;;
    0)
      # 返回
      return 0
      ;;
    *)
      echo -e "${RED}無效的選擇。${RESET}" >&2
      sleep 1
      return 1
      ;;
  esac
}

menu_php() {
  while true; do
    clear
    show_php
    echo "-------------------"
    echo "PHP管理"
    echo ""
    echo "1. 安裝php              2. 升級/降級php"
    echo ""
    echo "3. 新增普通PHP站點      4. WordPress管理"
    echo ""
    echo "5. 部署flarum站點"
    echo ""
    echo "6. 設定php上傳大小值     7. 安裝php擴展"
    echo ""
    echo "8. 安裝Flarum擴展       9. 管理HttpGuard"
    echo
    echo "10. 備份網站            11. 還原網站 "
    echo ""
    echo "r. PHP一鍵配置（設定www配置文件至我腳本可用之狀態）"
    echo "-------------------"
    echo "0. 返回"
    echo -n -e "\033[1;33m請選擇操作 [0-11]: \033[0m"
    read -r choice
    case $choice in
      1)
        if ! command -v php >/dev/null 2>&1; then
          clear
          php_install
          sleep 5
          php_fix
          read -p "操作完成，請按任意鍵繼續..." -n1
        fi
        ;;
      2) 
        clear
        check_php
        php_switch_version
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      3)
        clear
        check_php
        local ngx_user=$(get_web_run_user)
        read -p "請輸入您的域名：" domain
        check_cert "$domain" || {
          echo "未偵測到 Let's Encrypt 憑證，嘗試自動申請..."
          if ssl_apply "$domain"; then
            echo "申請成功，重新驗證憑證..."
              check_cert "$domain" || {
                echo "申請成功但仍無法驗證憑證，中止建立站點"
                return 1
              }
          else
            echo "SSL 申請失敗，中止建立站點"
            return 1
          fi
        }
        mkdir -p /var/www/$domain
        read -p "是否自訂index.php文件(Y/n)?" confirm
        confirm=${confirm,,}
        if [[ "$confirm" == "y" || "$confirm" == "" ]]; then
          nano /var/www/$domain/index.php
        else
          echo "<?php echo 'Hello from your PHP site!'; ?>" > "/var/www/$domain/index.php"
        fi
        rhel_selinux_enforcing_permissions "/var/www/$domain" label
        rhel_selinux_enforcing_permissions "/var/www/$domain" permissions
        setup_site "$domain" php
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      4)
        clear
        check_php
        menu_wp
        ;;
      5)
        clear
        check_php
        flarum_setup
        read -p "按任意鍵繼續..." -n1
        ;;
      6)
        clear
        check_php
        php_tune_upload_limit
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      7)
        check_php
        php_install_extensions
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      8)
        check_php
        flarum_extensions
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      9)
        httpguard_setup
        ;;
      10)
        backup_site
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      11)
        menu_restore_site
        read -p "操作完成，請按任意鍵繼續..." -n1
        ;;
      r)
        php_fix
        ;;
      0)
        break
        ;;
      *)
        echo "無效的選擇，請重新輸入。"
        ;;
    esac
  done
}

#主菜單
show_menu_caddy(){
  while true; do
    conf_file=""
    domain=""
    clear
    show_domain_status_caddy
    echo "-------------------"
    echo "站點管理器"
    echo ""
    echo -e "${YELLOW}r. 解除安裝 Caddy${RESET}"
    echo ""
    echo "1. 新增站點           2. 刪除站點"
    echo ""
    echo "3. PHP 管理           4. MYSQL安裝及管理"
    echo ""
    echo "5. Docker安裝及管理"
    echo ""
    echo "u. 更新腳本           0. 離開"
    echo "-------------------"
    echo -n -e "\033[1;33m請選擇操作 [1-5 / i u 0]: \033[0m"
    read -r choice
    case $choice in
    1)
      check_no_ngx || continue
      menu_add_sites
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    2)
      check_no_ngx || continue
      menu_del_sites 
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    3)
      check_no_ngx || continue
      menu_php
      ;;
    4)
      if ! command -v dba >/dev/null 2>&1; then
        bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh) install_script
      fi
      if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
        dba mysql install
      else
        dba mysql
      fi
      ;;
    5)
      if ! command -v d >/dev/null 2>&1; then
        bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/docker/install.sh)
      else
        d
      fi
      ;;
    0)
      exit 0
      ;;
    u)
      clear
      echo "更新腳本"
      echo "------------------------"
      update_script
      ;;
    r)
      uninstall_webserver
      ;;
    *)
      echo "無效選擇。"
    esac
  done
}

show_menu_nginx(){
  while true; do
    # 確保終端機回顯正常
    stty echo
    
    clear
    # 1. 顯示憑證狀態 (傳入全域頁碼)
    show_cert_status "$CURRENT_PAGE_NGINX"
    
    # 2. 顯示選單
    echo "-------------------"
    echo "站點管理器"
    echo ""
    echo -e "${YELLOW}i. 安裝 Nginx / OpenResty          r. 解除安裝 Nginx / OpenResty${RESET}"
    echo ""
    echo -e "${GREEN}1.${RESET} 新增站點           ${GREEN}2.${RESET} 刪除站點"
    echo ""
    echo -e "${GREEN}3.${RESET} 申請 SSL 證書      ${GREEN}4.${RESET} 刪除 SSL 證書"
    echo ""
    echo -e "${GREEN}5.${RESET} 重置 DNS 憑證      ${GREEN}6.${RESET} PHP 管理"
    echo ""
    echo -e "${GREEN}7.${RESET} 修復Cloudflare 525錯誤    ${GREEN}8.${RESET} MYSQL安裝及管理"
    echo ""
    echo -e "${GREEN}9.${RESET} Docker安裝及管理"
    echo ""
    echo -e "${BLUE}u.${RESET} 更新腳本           ${RED}0.${RESET} 離開"
    echo "-------------------"
    echo -e "${GRAY}[←/→] 翻頁  [數字] 選擇選單${RESET}"
    echo -n -e "${YELLOW}請選擇操作 [1-9 / i u 0]: ${RESET}"
    
    # 3. 獲取輸入 (異步)
    # 這邊 stdout 會拿到純淨的結果，視覺回顯走 stderr
    choice=$(get_input_or_nav)
    
    # 4. 處理導航
    if [[ "$choice" == "NAV_NEXT" ]]; then
        if [ "$CURRENT_PAGE_NGINX" -lt "$TOTAL_PAGES_NGINX" ]; then 
            CURRENT_PAGE_NGINX=$((CURRENT_PAGE_NGINX + 1))
        fi
        continue
    elif [[ "$choice" == "NAV_PREV" ]]; then
        if [ "$CURRENT_PAGE_NGINX" -gt 1 ]; then 
            CURRENT_PAGE_NGINX=$((CURRENT_PAGE_NGINX - 1))
        fi
        continue
    fi
    
    # 5. 處理業務邏輯
    case $choice in
    i)
      check_web_environment; check_nginx; check_web_server;
      read -p "請按任意鍵繼續..." -n1
      ;;
    1)
      check_no_ngx || continue
      menu_add_sites
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    2)
      check_no_ngx || continue
      menu_del_sites 
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    3)
      menu_ssl_apply
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    4)
      menu_ssl_revoke
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    5)
      menu_reset_dns_token
      sleep 5
      ;;
    6)
      check_no_ngx || continue
      menu_php
      ;;
    7)
      clean_nginx_ssl_config
      read -p "操作完成，請按任意鍵繼續..." -n1
      ;;
    8)
      if ! command -v dba >/dev/null 2>&1; then
        bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh) install_script
      fi
      if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then dba mysql install; else dba mysql; fi
      ;;
    9)
      if ! command -v d >/dev/null 2>&1; then
        bash <(curl -sL https://gitlab.com/gebu8f/sh/-/raw/main/docker/install.sh)
      else d; fi
      ;;
    0)
      exit 0
      ;;
    u)
      clear; echo "更新腳本"; echo "------------------------"; update_script
      ;;
    r)
      uninstall_webserver
      ;;
    *)
      if [[ -n "$choice" ]]; then echo "無效選擇: $choice"; sleep 0.5; fi
      ;;
    esac
  done
}

case "$1" in
  --version|-V)
    echo "站點管理器版本 $version"
    exit 0
    ;;
esac

# 只有不是 --version 或 -V 才會執行以下初始化
check_system
check_app
check_web_environment
check_webserver_install
check_and_start_service
check_web_server


if [ $# -ne 0 ]; then
  case "$1" in
  setup)
    domain="$2"
    site_type="$3"

    if [[ -z "$domain" || -z "$site_type" ]]; then
      exit 1
    fi
    case "$site_type" in
      html|flarum|php)
        setup_site "$domain" $site_type
        ;;
      proxy)
        target_url="$4"
        target_proto="$5"
        target_port="$6"

        if [[ -z "$target_url" || -z "$target_proto" || -z "$target_port" ]]; then
          echo "proxy 類型需要提供 target_url protocol port"
          exit 1
        fi
        
        # 自動申請 SSL（若不存在）
        check_cert "$domain" || {
          echo "未偵測到 Let Encrypt 憑證，嘗試自動申請..."
          if ssl_apply "$domain"; then
            echo "申請成功，重新驗證憑證..."
            check_cert "$domain" || {
              echo "申請成功但仍無法驗證憑證，中止建立站點"
              return 1
            }
          else
              echo "SSL 申請失敗，中止建立站點"
              return 1
          fi
        }

        setup_site "$domain" proxy "$target_url" "$target_proto" "$target_port"
        exit 0
        ;;
    esac
    ;;
  del)
    domain="$2"
    menu_del_sites "$domain"
    exit 0
    ;;
  api)
    if [[ "$2" == "search" && "$3" == "proxy_domain" ]]; then
      target="$4"
      conf_dir=$(detect_conf_path)/
      for file in "${conf_dir}"*.conf; do
        [ -e "$file" ] || continue
        if [ $caddy -eq 1 ]; then
          awk -v tgt="$target" '
            /^[^ \t\n#]/ { sub(/ \{$/, ""); current_domain = $1; }
            $0 ~ "reverse_proxy.*" tgt { if (current_domain != "") print current_domain; }
          ' "$file"
        else
          awk -v tgt="$target" '
            $0 ~ "server_name" { 
                # 暫存最近一個 server_name
                for(i=2; i<=NF; i++) {
                    d=$i; sub(/;$/, "", d); last_domains[i]=d;
                    count=i;
                }
            }
            $0 ~ "proxy_pass.*" tgt {
                for(j=2; j<=count; j++) print last_domains[j];
            }
          ' "$file"
        fi
      done | sort -u  # 只有最後這裡用一個 sort
    fi
    exit 0
    ;;
  esac
fi
if [ $caddy -eq 1 ]; then
  show_menu_caddy
else
  trap 'stty echo; exit' INT TERM
  show_menu_nginx
fi