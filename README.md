    Usage:    captureAP.sh [OPTIONS] <internet-interface> <AP-interface>
	
	
	This script creates a local AP (access point) using hostapd and connects it to the internet
	via an existing network connection, either ethernet or Wi-Fi. The interfaces will be things
	such as found in the ifconfig command: wlan0, eth0, etc.
	
	The interface used for the AP is disallowed from being managed by the NetworkManager service.
	An AP configuration file and dnsmasq configuration file are always required for the AP.
	
	If the required AP and dnsmasq configuration files are missing they will be generated with
	default settings.
	
	Any settings changed from their defaults using flags (DHCP start/end address, lease time,
	etc.) persist between script runs.
	
	Options:
	    [-h | --help]
	        Displays this help screen and exits.
	
	    [-a | --ap-address] <ip-address>
	        Set the access point IP address.
	        Default: 10.0.0.1
	
	    [-s | --dhcp-start] <ip-address>
	        Set the DHCP range start IP address.
	        Default: 10.0.0.10
	
	    [-e | --dhcp-end] <ip-address>
	        Set the DHCP range end IP address.
	        Default: 10.0.0.20
	
	    [-n | --netmask] <netmask>
	        Set the DHCP netmask.
	        Default: 255.255.255.0
	
	    [-l | --dhcp-lease] <lease-time>
	        Set the DHCP lease time.
	        Default: 12h
	
	    [-r | --remove-ap]
	       Remove the AP if it is running and revert all settings back to normal.
	
	Examples:
	    captureAP.sh wlan0 wlan1
	    captureAP.sh eth0 wlan0
	    captureAP.sh -e 10.0.0.50 wlan0 wlan1
	    captureAP.sh -r


######################
##### KNOWN BUGS #####
######################

Sometimes when launching the AP it will not indicate any errors, but the AP will not be visible. Simply running the script once or twice more fixes it.
