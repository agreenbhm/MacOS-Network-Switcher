#!/bin/bash

WIRED_INTERFACE=""
WIFI_INTERFACE=""
VERBOSE=0
CHECK_INTERVAL=60

# Help message
show_help() {
    echo "Usage: $0 -w <wired_interface> -f <wifi_interface> [-t <check_interval] [-v]"
    echo
    echo "Options:"
    echo "  -w  Specify the name of the wired interface (e.g., 'USB 10/100/1000 LAN')"
    echo "  -f  Specify the name of the Wi-Fi interface (e.g., 'Wi-Fi')"
    echo "  -t  Specify the number of seconds between checks (default is 60)"
    echo "  -v  Enable verbose mode (outputs all messages immediately)"
    echo "  -h  Display this help message"
    echo
    echo "This script monitors the network interfaces and dynamically switches between"
    echo "a wired and wireless interface depending on their status and availability."
    echo "It attempts to prioritize the wired connection if available and active."
    echo "If both interfaces are on the same subnet, it will ping the router to ensure"
    echo "connectivity and then decide which interface should take priority."
    exit 0
}

# Function to validate if an interface exists
validate_interface() {
    local interface_name="$1"
    if ! networksetup -listallnetworkservices | grep -q "^$interface_name$"; then
        echo "Error: Network service '$interface_name' does not exist on this system."
        exit 1
    fi
}

# Function to check if an interface is active
check_interface_active() {
    local interface_name="$1"
    networksetup -getnetworkserviceenabled "$interface_name" | grep -q "Enabled"
    return $?  # Returns 0 if active, 1 if inactive
}

# Parse command-line arguments
while getopts "w:f:vh" opt; do
    case $opt in
        w) WIRED_INTERFACE="$OPTARG" ;;
        f) WIFI_INTERFACE="$OPTARG" ;;
        v) CHECK_INTERVAL=5 ;;
        v) VERBOSE=1 ;;
        h) show_help ;;
        *) show_help ;;
    esac
done

# Ensure both interfaces are provided
if [ -z "$WIRED_INTERFACE" ] || [ -z "$WIFI_INTERFACE" ]; then
    echo "Error: Both wired (-w) and Wi-Fi (-f) interfaces must be specified."
    show_help
fi

# Validate the interfaces
validate_interface "$WIRED_INTERFACE"
validate_interface "$WIFI_INTERFACE"

log_cache=""

# Log function to cache or print messages based on verbosity, with timestamps
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    if [ "$VERBOSE" -eq 1 ]; then
        echo "[$timestamp] $message"
    else
        log_cache+="[$timestamp] $message"$'\n'
    fi
}

# Function to calculate the network address using bitwise AND of IP and subnet mask
ip_to_network() {
    local ip="$1"
    local mask="$2"
    IFS=. read -r i1 i2 i3 i4 <<<"$ip"
    IFS=. read -r m1 m2 m3 m4 <<<"$mask"
    printf "%d.%d.%d.%d" "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))"
}

# Function to check if an IP is in the APIPA range (169.254.x.x)
is_apipa() {
    local ip="$1"
    if [[ "$ip" =~ ^169\.254\..* ]]; then
        return 0  # True (APIPA address)
    else
        return 1  # False (Not APIPA)
    fi
}

# Function to get the hardware device name (e.g., en0, en1) for a given network service name
get_hardware_device() {
    local service_name="$1"
    networksetup -listallhardwareports | \
    awk -v service="$service_name" '{
        if ($0 ~ service) {getline; print $NF}
    }'
}

# Function to deactivate and reactivate the interface
reset_interface() {
    local service="$1"
    log "Deactivating and reactivating interface: $service"
    networksetup -setnetworkserviceenabled "$service" off
    sleep 3
    networksetup -setnetworkserviceenabled "$service" on
    sleep 5  # Wait for the interface to come back online
}

# Function to reorder services, checking the current order before making changes
reorder_services() {
    new_services=()

    # Check if Wi-Fi should be first or second
    if [ "$1" == "wifi_first" ]; then
        new_services+=("$WIFI_INTERFACE")
        new_services+=("$WIRED_INTERFACE")
    else
        new_services+=("$WIRED_INTERFACE")
        new_services+=("$WIFI_INTERFACE")
    fi

    # Get the list of current network services dynamically
    current_services=$(networksetup -listnetworkserviceorder | grep -E '^\(\d+\)' | cut -d' ' -f2-)

    # Convert the list of services into an array
    IFS=$'\n' read -r -d '' -a services <<< "$current_services"

    # Add all other services, excluding Wi-Fi and USB 10/100/1000 LAN
    for service in "${services[@]}"; do
        if [[ "$service" != "$WIRED_INTERFACE" && "$service" != "$WIFI_INTERFACE" ]]; then
            new_services+=("$service")
        fi
    done

    # Compare current order with new order
    if [ "${new_services[*]}" == "${services[*]}" ]; then
        log "Network order is already correct. No changes needed."
    else
        # Reorder services and print cached output
        log "Changing network order: ${new_services[*]}"
        networksetup -ordernetworkservices "${new_services[@]}"
        echo "$log_cache"
    fi
    log_cache=""  # Clear log cache after each iteration
}

# Function to check if Wi-Fi is connected (has a valid IP address)
check_wifi_connection() {
    wifi_ip=$(networksetup -getinfo "$WIFI_INTERFACE" | grep "^IP address:" | awk '{print $3}')
    if [ -z "$wifi_ip" ] || is_apipa "$wifi_ip"; then
        log "Wi-Fi is not connected or has an invalid IP. Skipping this iteration."
        return 1  # Wi-Fi is not connected
    fi
    return 0  # Wi-Fi is connected
}

# Start a loop to continuously check the network
while true; do
    # Reset log cache at the beginning of each iteration
    log_cache=""

    check_interface_active "$WIRED_INTERFACE"
    if [ $? -ne 0 ]; then
        log "$WIRED_INTERFACE is disabled. Skipping this iteration."
        sleep $CHECK_INTERVAL
        continue
    fi

    # Check if Wi-Fi is connected before proceeding
    check_wifi_connection
    if [ $? -ne 0 ]; then
        sleep $CHECK_INTERVAL
        continue
    fi

    # Get the IP address and subnet mask for USB 10/100/1000 LAN
    wired_ip=$(networksetup -getinfo "$WIRED_INTERFACE" | grep "^IP address:" | awk '{print $3}')
    wired_mask=$(networksetup -getinfo "$WIRED_INTERFACE" | grep "^Subnet mask:" | awk '{print $3}')

    # Get the hardware device name for the USB interface
    wired_device=$(get_hardware_device "$WIRED_INTERFACE")

    # If the USB interface has an APIPA address or no IP address, reset the interface
    if [ -z "$wired_ip" ] || is_apipa "$wired_ip"; then
        if [ -z "$wired_ip" ]; then
            log "$WIRED_INTERFACE has no IP address."
        elif is_apipa "$wired_ip"; then
            log "$WIRED_INTERFACE has an APIPA address ($wired_ip)."
        fi
        reset_interface "$WIRED_INTERFACE"

        # Re-check the IP after resetting the interface
        wired_ip=$(networksetup -getinfo "$WIRED_INTERFACE" | grep "^IP address:" | awk '{print $3}')
        wired_mask=$(networksetup -getinfo "$WIRED_INTERFACE" | grep "^Subnet mask:" | awk '{print $3}')
        if [ -z "$wired_ip" ] || is_apipa "$wired_ip"; then
            log "Failed to obtain a valid IP for $WIRED_INTERFACE after resetting. Skipping."
            sleep $CHECK_INTERVAL
            continue
        else
            log "Successfully obtained a valid IP for $WIRED_INTERFACE: $wired_ip"
        fi
    fi

    # Get the IP address and subnet mask for Wi-Fi
    wifi_ip=$(networksetup -getinfo "$WIFI_INTERFACE" | grep "^IP address:" | awk '{print $3}')
    wifi_mask=$(networksetup -getinfo "$WIFI_INTERFACE" | grep "^Subnet mask:" | awk '{print $3}')

    # Ensure we skip unnecessary commands by checking if the interfaces are on the same subnet
    if [ -z "$wired_ip" ] || [ -z "$wifi_ip" ] || [ -z "$wired_mask" ] || [ -z "$wifi_mask" ]; then
        log "One of the interfaces is missing a valid IP or subnet mask. Skipping."
        sleep $CHECK_INTERVAL
        continue
    fi

    wired_network=$(ip_to_network "$wired_ip" "$wired_mask")
    wifi_network=$(ip_to_network "$wifi_ip" "$wifi_mask")

    if [ "$wired_network" == "$wifi_network" ]; then
        log "Wi-Fi and USB 10/100/1000 LAN are on the same subnet. Proceeding."

        # Get the router IP of the wired interface
        router_ip=$(networksetup -getinfo "$WIRED_INTERFACE" | grep "^Router" | awk '{print $2}')

        # Check if the router IP is valid (not empty or null)
        if [ "$router_ip" == "(null)" ] || [ -z "$router_ip" ]; then
            log "No valid router IP found for $WIRED_INTERFACE. Deprioritizing it."
            reorder_services "wifi_first"
        else
            # Ping the router from the specific wired interface IP
            ping -S "$wired_ip" -c 1 "$router_ip" > /dev/null 2>&1

            # Check if the ping was successful
            if [ $? -eq 0 ]; then
                log "Ping to $router_ip successful on $WIRED_INTERFACE ($wired_ip). Prioritizing it."
                reorder_services "wired_first"
            else
                log "Ping to $router_ip failed on $WIRED_INTERFACE. Prioritizing $WIFI_INTERFACE."
                reorder_services "wifi_first"
            fi
        fi
    else
        log "Wi-Fi and USB 10/100/1000 LAN are not on the same subnet. Skipping."
    fi

    # Sleep for a few seconds before rechecking
    sleep $CHECK_INTERVAL
done
