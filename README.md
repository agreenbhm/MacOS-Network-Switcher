# MacOS-Network-Switcher
Script to prioritize network interfaces based on availability.

Usage: ./MacOS-Network-Switcher.sh -w <wired_interface> -f <wifi_interface> [-v]

Options:
  -w  Specify the name of the wired interface (e.g., 'USB 10/100/1000 LAN')
  -f  Specify the name of the Wi-Fi interface (e.g., 'Wi-Fi')
  -v  Enable verbose mode (outputs all messages immediately)
  -h  Display this help message

This script monitors the network interfaces and dynamically switches between
a wired and wireless interface depending on their status and availability.
It attempts to prioritize the wired connection if available and active.
If both interfaces are on the same subnet, it will ping the router and
decide which interface should take priority.
