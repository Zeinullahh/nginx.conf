# Create Traffic Reporter Script
# Let's create the Python script that will collect traffic information and send it to the CMC


#!/usr/bin/env python3
"""
Anti-DDoS Traffic Reporter Script

This script monitors Nginx access logs, extracts IP addresses and country codes
of filtered traffic, and sends them to the centralized management console (CMC)
via WebSocket connection.
"""

import os
import json
import time
import re
import socket
import logging
import signal
import sys
from datetime import datetime
import geoip2.database
import websocket
import schedule
from collections import defaultdict

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("/var/log/ddos-reporter.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("ddos-reporter")

# Environment variables
AGENT_IP = os.environ.get("AGENT_IP", "34.56.95.96")
CMC_IP = os.environ.get("CMC_IP", "35.209.181.193")
TARGET_SERVER = os.environ.get("TARGET_SERVER", "10.128.0.6")
CMC_PORT = os.environ.get("CMC_PORT", "4444")

# File paths
ACCESS_LOG_PATH = "/var/log/nginx/ddos_access.log"
GEOIP_DB_PATH = "/etc/nginx/geoip/GeoLiteCity.dat"

# Global variables
ip_counter = defaultdict(int)
country_codes = {}
last_position = 0
ws = None

def setup_geoip():
    """Initialize the GeoIP database reader"""
    try:
        # Try to use GeoIP2 database if available
        return geoip2.database.Reader('/usr/share/GeoIP/GeoLite2-Country.mmdb')
    except:
        logger.warning("Could not load GeoIP2 database, falling back to log parsing")
        return None

def get_country_code(ip, reader):
    """Get country code for an IP address"""
    try:
        if ip in country_codes:
            return country_codes[ip]
        
        if reader:
            # Use GeoIP2 database
            response = reader.country(ip)
            country_code = response.country.iso_code
        else:
            # If no GeoIP database available, extract from log
            # This assumes the X-Country-Code header was properly set by Nginx
            return "XX"  # Unknown country code
            
        country_codes[ip] = country_code
        return country_code
    except Exception as e:
        logger.error(f"Error getting country code for IP {ip}: {e}")
        return "XX"  # Unknown country code

def parse_logs():
    """Parse Nginx access logs to extract IP addresses and country codes"""
    global last_position
    
    try:
        # Check if log file exists
        if not os.path.exists(ACCESS_LOG_PATH):
            logger.warning(f"Log file not found: {ACCESS_LOG_PATH}")
            return
            
        # Open the log file and seek to the last read position
        with open(ACCESS_LOG_PATH, 'r') as f:
            f.seek(last_position)
            
            # Read new lines
            for line in f:
                try:
                    # Extract IP address
                    match = re.search(r'^(\d+\.\d+\.\d+\.\d+)', line)
                    if match:
                        ip = match.group(1)
                        
                        # Extract country code from the log if available
                        country_match = re.search(r'"([A-Z]{2})"$', line)
                        if country_match:
                            country_code = country_match.group(1)
                            country_codes[ip] = country_code
                        
                        # Check if request was successful (status code 200-299)
                        status_match = re.search(r'" (\d{3}) ', line)
                        if status_match and 200 <= int(status_match.group(1)) < 300:
                            # This IP passed all filters and was successfully forwarded
                            ip_counter[ip] += 1
                except Exception as e:
                    logger.error(f"Error parsing log line: {e}")
            
            # Update the last position in the file
            last_position = f.tell()
    except Exception as e:
        logger.error(f"Error parsing logs: {e}")

def connect_to_cmc():
    """Connect to the Centralized Management Console via WebSocket"""
    global ws
    
    ws_url = f"ws://{CMC_IP}:{CMC_PORT}"
    
    try:
        logger.info(f"Connecting to CMC at {ws_url}")
        ws = websocket.create_connection(ws_url)
        
        # Send initial connection message with agent information
        initial_message = {
            "type": "agent_connect",
            "agent_ip": AGENT_IP,
            "target_server": TARGET_SERVER,
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        }
        ws.send(json.dumps(initial_message))
        logger.info("Connected to CMC successfully")
        return True
    except Exception as e:
        logger.error(f"Failed to connect to CMC: {e}")
        ws = None
        return False

def send_traffic_data():
    """Send collected traffic data to the CMC"""
    global ip_counter, country_codes, ws
    
    # Skip if no data to send
    if not ip_counter:
        logger.debug("No traffic data to send")
        return
    
    # Prepare data
    data = {}
    reader = setup_geoip()
    
    for ip, count in ip_counter.items():
        country_code = country_codes.get(ip) or get_country_code(ip, reader)
        data[ip] = country_code
    
    # Clear counters after collecting data
    ip_counter.clear()
    
    # Send data to CMC
    if ws is None:
        connected = connect_to_cmc()
        if not connected:
            logger.warning("Could not connect to CMC, will retry next cycle")
            return
    
    try:
        ws.send(json.dumps(data))
        logger.info(f"Sent traffic data with {len(data)} IP addresses to CMC")
    except Exception as e:
        logger.error(f"Failed to send data to CMC: {e}")
        ws = None  # Reset connection to retry next time

def main():
    """Main function"""
    # Handle graceful shutdown
    def signal_handler(sig, frame):
        logger.info("Shutting down...")
        if ws:
            try:
                ws.close()
            except:
                pass
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Initial connection to CMC
    connect_to_cmc()
    
    # Schedule tasks
    schedule.every(1).seconds.do(parse_logs)
    schedule.every(1).seconds.do(send_traffic_data)
    
    logger.info("Anti-DDoS Traffic Reporter started")
    
    # Main loop
    while True:
        schedule.run_pending()
        time.sleep(0.1)

if __name__ == "__main__":
    main()