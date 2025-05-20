#!/bin/bash
# Country Block Management Script for Anti-DDoS Agent
# This script enables or disables country blocking in the Nginx configuration

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Configuration
NGINX_CONF="/etc/nginx/nginx.conf"
CONF_DIR="/etc/nginx/conf.d"

# Function to display usage
usage() {
  echo "Usage: $0 [OPTION]"
  echo "Manage country blocking in the Anti-DDoS agent"
  echo ""
  echo "Options:"
  echo "  --list                 List all countries with their current block status"
  echo "  --enable-all           Enable blocking for all countries"
  echo "  --disable-all          Disable blocking for all countries"
  echo "  --enable COUNTRY_CODE  Enable blocking for specific country (e.g., --enable cn)"
  echo "  --disable COUNTRY_CODE Disable blocking for specific country (e.g., --disable cn)"
  echo "  --block-list           Show a list of currently blocked countries"
  echo "  --help                 Display this help and exit"
  echo ""
  echo "Examples:"
  echo "  $0 --enable cn         # Block traffic from China"
  echo "  $0 --disable ru        # Allow traffic from Russia"
  echo "  $0 --enable-all        # Block traffic from all countries"
  echo "  $0 --list              # List all countries and their block status"
}

# Function to check if country code exists
check_country_code() {
  local code=$1
  if [ ! -f "$CONF_DIR/${code}_geo.conf" ]; then
    echo "Error: Country code '$code' does not exist"
    exit 1
  fi
}

# Function to list all countries with their block status
list_countries() {
  echo "Country Block Status:"
  echo "====================="
  for file in "$CONF_DIR"/*_geo.conf; do
    code=$(basename "$file" | cut -d'_' -f1)
    comment_status=$(grep -c "^[[:space:]]*include $file;" "$NGINX_CONF" || true)
    uncomment_status=$(grep -c "^[[:space:]]*# include $file;" "$NGINX_CONF" || true)
    
    if [ "$comment_status" -eq 1 ]; then
      status="BLOCKED"
    elif [ "$uncomment_status" -eq 1 ]; then
      status="ALLOWED"
    else
      status="UNKNOWN"
    fi
    
    # Get country name from the first line of the file
    country_name=$(head -n1 "$file" | sed 's/# Auto-generated: block country //')
    printf "%-5s %-40s %s\n" "$code" "$country_name" "$status"
  done
}

# Function to show currently blocked countries
show_block_list() {
  echo "Currently Blocked Countries:"
  echo "==========================="
  blocked_count=0
  
  for file in "$CONF_DIR"/*_geo.conf; do
    code=$(basename "$file" | cut -d'_' -f1)
    comment_status=$(grep -c "^[[:space:]]*include $file;" "$NGINX_CONF" || true)
    
    if [ "$comment_status" -eq 1 ]; then
      country_name=$(head -n1 "$file" | sed 's/# Auto-generated: block country //')
      printf "%-5s %-40s\n" "$code" "$country_name"
      ((blocked_count++))
    fi
  done
  
  if [ "$blocked_count" -eq 0 ]; then
    echo "No countries are currently blocked."
  fi
  
  echo ""
  echo "Total: $blocked_count countries blocked"
}

# Function to enable country blocking
enable_country() {
  local code=$1
  check_country_code "$code"
  
  # Check if already enabled
  if grep -q "^[[:space:]]*include $CONF_DIR/${code}_geo.conf;" "$NGINX_CONF"; then
    echo "Country $code is already blocked"
    return
  fi
  
  # Enable by uncommenting the line
  sed -i "s|^[[:space:]]*# include $CONF_DIR/${code}_geo.conf;|        include $CONF_DIR/${code}_geo.conf;|" "$NGINX_CONF"
  echo "Enabled blocking for country: $code"
}

# Function to disable country blocking
disable_country() {
  local code=$1
  check_country_code "$code"
  
  # Check if already disabled
  if grep -q "^[[:space:]]*# include $CONF_DIR/${code}_geo.conf;" "$NGINX_CONF"; then
    echo "Country $code is already allowed"
    return
  fi
  
  # Disable by commenting the line
  sed -i "s|^[[:space:]]*include $CONF_DIR/${code}_geo.conf;|        # include $CONF_DIR/${code}_geo.conf;|" "$NGINX_CONF"
  echo "Disabled blocking for country: $code"
}

# Function to enable all country blocking
enable_all_countries() {
  echo "Enabling blocking for all countries..."
  sed -i 's|^[[:space:]]*# include \(/etc/nginx/conf.d/.*_geo.conf\);|        include \1;|' "$NGINX_CONF"
  echo "All countries are now blocked"
}

# Function to disable all country blocking
disable_all_countries() {
  echo "Disabling blocking for all countries..."
  sed -i 's|^[[:space:]]*include \(/etc/nginx/conf.d/.*_geo.conf\);|        # include \1;|' "$NGINX_CONF"
  echo "All countries are now allowed"
}

# Function to reload nginx if needed
reload_nginx() {
  echo "Testing Nginx configuration..."
  nginx -t
  
  if [ $? -eq 0 ]; then
    echo "Reloading Nginx to apply changes..."
    systemctl reload nginx
    echo "Done!"
  else
    echo "Error in Nginx configuration. Changes not applied."
    exit 1
  fi
}

# Main execution
if [ $# -lt 1 ]; then
  usage
  exit 1
fi

case "$1" in
  --list)
    list_countries
    ;;
  --block-list)
    show_block_list
    ;;
  --enable-all)
    enable_all_countries
    reload_nginx
    ;;
  --disable-all)
    disable_all_countries
    reload_nginx
    ;;
  --enable)
    if [ -z "$2" ]; then
      echo "Error: Country code required"
      usage
      exit 1
    fi
    enable_country "$2"
    reload_nginx
    ;;
  --disable)
    if [ -z "$2" ]; then
      echo "Error: Country code required"
      usage
      exit 1
    fi
    disable_country "$2"
    reload_nginx
    ;;
  --help)
    usage
    ;;
  *)
    echo "Unknown option: $1"
    usage
    exit 1
    ;;
esac

exit 0