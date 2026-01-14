#!/bin/bash
set -euo pipefail

BM_DIR="$(dirname "$(readlink -f "$0")")"
source "$BM_DIR/config/setup_config.env"

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root"
    exit 1
fi

WEB_USER="www-data"
BM_WEB_GROUP="www-data"
BM_READ_PERMISSIONS=750
BM_WRITE_PERMISSIONS=770

APACHE_LOG_DIR="/var/log/apache2"
BM_APACHE_LOG_PATH="$APACHE_LOG_DIR/error.log"
SERVER_LOG_DIR="/var/log/babymonitor"
BM_SERVER_LOG_PATH="$SERVER_LOG_DIR/error.log"

BM_ENV_DIR="$BM_DIR/env"
BM_ENV_EXPORTS_PATH="$BM_ENV_DIR/envvar_exports"
BM_ENV_PATH="$BM_ENV_DIR/envvars"
BM_SITE_DIR="/var/www/babymonitor"
BM_LINKED_SITE_DIR="$BM_DIR/site/public"
BM_SHAREDMEM_DIR="/run/shm"
BM_LINKED_STREAM_DIR="$BM_LINKED_SITE_DIR/streaming"

BM_VENV="$BM_DIR/venv"

# ----------------------------------------
# Python virtual environment
# ----------------------------------------
if [[ ! -d "$BM_VENV" ]]; then
    python3 -m venv "$BM_VENV"
fi
"$BM_VENV/bin/pip3" install --upgrade pip
"$BM_VENV/bin/pip3" install --no-cache-dir -r "$BM_DIR/requirements.txt"

# ----------------------------------------
# Audio setup
# ----------------------------------------
BM_CONTROL_MIC_DIR="$BM_DIR/control/.mic"
mkdir -p "$BM_CONTROL_MIC_DIR"
"$BM_DIR/control/mic.py" --select-mic || true
usermod -aG audio "$BM_USER" || true
ln -sfn "$BM_SHAREDMEM_DIR" "$BM_LINKED_STREAM_DIR"

# ----------------------------------------
# Install required packages
# ----------------------------------------
apt_packages=(
    unzip inotify-tools python3 python3-pip
    apache2 mariadb-server php php-dev php-pear php-mysql libapache2-mod-php
    libzip-dev libharfbuzz0b libfontconfig1
    alsa-utils ffmpeg lame
    pandoc libopenblas-dev libopenexr-dev
)
apt -y install "${apt_packages[@]}" || true

# PECL extensions
pecl channel-update pecl.php.net || true
pecl install inotify zip || true

# ----------------------------------------
# Environment variables
# ----------------------------------------
mkdir -p "$BM_ENV_DIR"
touch "$BM_ENV_EXPORTS_PATH"
declare -A ENV_VARS=(
    ["BM_TIMEZONE"]="$BM_TIMEZONE"
    ["BM_USER"]="$BM_USER"
    ["WEB_USER"]="$WEB_USER"
    ["BM_WEB_GROUP"]="$BM_WEB_GROUP"
    ["BM_READ_PERMISSIONS"]="$BM_READ_PERMISSIONS"
    ["BM_WRITE_PERMISSIONS"]="$BM_WRITE_PERMISSIONS"
    ["BM_DIR"]="$BM_DIR"
)
for var in "${!ENV_VARS[@]}"; do
    echo "export $var=${ENV_VARS[$var]}" >> "$BM_ENV_EXPORTS_PATH"
done
sed 's/export //g' "$BM_ENV_EXPORTS_PATH" > "$BM_ENV_PATH"

# ----------------------------------------
# MySQL root password
# ----------------------------------------
mysql <<_EOF_
DELETE FROM mysql.user WHERE User='' OR (User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'));
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db IN ('test','test\_%');
FLUSH PRIVILEGES;

CREATE DATABASE IF NOT EXISTS babymonitor;
CREATE USER IF NOT EXISTS 'babymonitor'@'localhost' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON babymonitor.* TO 'babymonitor'@'localhost';
FLUSH PRIVILEGES;
_EOF_

# ----------------------------------------
# Apache & PHP configuration
# ----------------------------------------
PHP_INI_CLI_PATH=$(php -i | grep /.+/php.ini -oE)
PHP_DIR=$(dirname "$(dirname "$PHP_INI_CLI_PATH")")

echo 'extension=inotify.so' | tee "$PHP_DIR/mods-available/inotify.ini"
phpenmod inotify
echo 'extension=zip.so' | tee "$PHP_DIR/mods-available/zip.ini"
phpenmod zip

# Timezone
"$BM_DIR/site/servercontrol/set_php_timezone.sh" "$BM_TIMEZONE"

APACHE_CONF_PATH="/etc/apache2/apache2.conf"
echo -e "\nDirectoryIndex index.php" | tee -a "$APACHE_CONF_PATH"
sed -i 's/^LogLevel .*$/LogLevel error/g' "$APACHE_CONF_PATH"
adduser "$BM_USER" "$BM_WEB_GROUP"

# ----------------------------------------
# Folders & permissions
# ----------------------------------------
mkdir -p "$SERVER_LOG_DIR" "$BM_CONTROL_MIC_DIR" "$BM_LINKED_STREAM_DIR"
touch "$BM_SERVER_LOG_PATH" "$BM_APACHE_LOG_PATH"
chown -R "$BM_USER:$BM_WEB_GROUP" "$BM_DIR" "$BM_SERVER_LOG_PATH" "$BM_APACHE_LOG_PATH"
chmod -R 0"$BM_READ_PERMISSIONS" "$BM_DIR"
chmod "$BM_WRITE_PERMISSIONS" "$BM_SERVER_LOG_PATH" "$BM_APACHE_LOG_PATH"

# ----------------------------------------
# Download JS libraries and Bootstrap
# ----------------------------------------
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

download_and_unzip() {
    local url=$1
    local dest=$2
    local subdir=${3:-.}
    wget -q "$url" -O temp.zip
    mkdir -p "$dest"
    unzip -q temp.zip -d "$dest"
    rm temp.zip
}

# ---- Bootstrap ----
BOOTSTRAP_VERSION=5.0.2
BOOTSTRAP_DIR="$BM_LINKED_SITE_DIR/library/bootstrap"
mkdir -p "$BOOTSTRAP_DIR"

# unzip into temp, then move contents up one level
TMP_BOOTSTRAP_DIR=$(mktemp -d)
download_and_unzip "https://github.com/twbs/bootstrap/releases/download/v${BOOTSTRAP_VERSION}/bootstrap-${BOOTSTRAP_VERSION}-dist.zip" "$TMP_BOOTSTRAP_DIR"
mv "$TMP_BOOTSTRAP_DIR/bootstrap-${BOOTSTRAP_VERSION}-dist/"* "$BOOTSTRAP_DIR/"
rm -rf "$TMP_BOOTSTRAP_DIR"

# Add dark theme CSS
mkdir -p "$BOOTSTRAP_DIR/css"
wget -q -O "$BOOTSTRAP_DIR/css/bootstrap-dark.min.css" "https://cdn.jsdelivr.net/npm/bootstrap-dark-5@1.1.2/dist/css/bootstrap-dark.min.css"

# Add Bootstrap icons
mkdir -p "$BM_LINKED_SITE_DIR/media"
wget -q -O "$BM_LINKED_SITE_DIR/media/bootstrap-icons.svg" "https://raw.githubusercontent.com/twbs/icons/main/bootstrap-icons.svg"

# ---- HLS.js ----
HLS_JS_VERSION=1.0.11
HLS_DIR="$BM_LINKED_SITE_DIR/library/hls-js/dist"
mkdir -p "$HLS_DIR"
download_and_unzip "https://github.com/video-dev/hls.js/releases/download/v${HLS_JS_VERSION}/release.zip" "$HLS_DIR"

# ---- Anime.js ----
ANIME_VERSION=3.2.1
ANIME_DIR="$BM_LINKED_SITE_DIR/library/anime"
mkdir -p "$ANIME_DIR"
download_and_unzip "https://github.com/juliangarnier/anime/archive/refs/tags/v${ANIME_VERSION}.zip" "$ANIME_DIR" "anime-${ANIME_VERSION}/lib"

# ---- NoSleep.js ----
NOSLEEP_JS_VERSION=0.12.0
NOSLEEP_DIR="$BM_LINKED_SITE_DIR/library/nosleep-js/dist"
mkdir -p "$NOSLEEP_DIR"
download_and_unzip "https://github.com/richtr/NoSleep.js/archive/refs/tags/v${NOSLEEP_JS_VERSION}.zip" "$NOSLEEP_DIR"

# ---- Video.js ----
VIDEOJS_VERSION=7.13.3
VIDEOJS_DIR="$BM_LINKED_SITE_DIR/library/video-js"
mkdir -p "$VIDEOJS_DIR"
download_and_unzip "https://github.com/videojs/video.js/releases/download/v${VIDEOJS_VERSION}/video-js-${VIDEOJS_VERSION}.zip" "$VIDEOJS_DIR"

# ---- jQuery ----
mkdir -p "$BM_LINKED_SITE_DIR/library"
JQUERY_VERSION=3.6.0
wget -q -O "$BM_LINKED_SITE_DIR/library/jquery.min.js" "https://code.jquery.com/jquery-${JQUERY_VERSION}.min.js"

# ---- JS-Cookie ----
JS_COOKIE_VERSION=3.0.1
JS_COOKIE_DIR="$BM_LINKED_SITE_DIR/library/js-cookie/js"
mkdir -p "$JS_COOKIE_DIR"
wget -q -O "$JS_COOKIE_DIR/js.cookie.min.js" "https://github.com/js-cookie/js-cookie/releases/download/v${JS_COOKIE_VERSION}/js.cookie.min.js"

cd -
rm -rf "$TMP_DIR"

# ----------------------------------------
# Final: restart Apache
# ----------------------------------------
ln -sfn "$BM_LINKED_SITE_DIR" "$BM_SITE_DIR"
a2dissite 000-default || true
rm -rf /var/www/html
a2enmod ssl
systemctl restart apache2

echo "setup_server.sh completed successfully"
