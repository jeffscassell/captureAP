    [USAGE]
	    captureAP.sh [OPTIONS] <internet-interface> <AP-interface>
	

	[DESCRIPTION]

	This script creates a local Wi-Fi AP (access point) and connects it to the
	internet via an existing network connection. Confirmed working with either ethernet or	Wi-Fi,
	but should be compatible with any network interface. The interfaces will be things such as
	found in the ifconfig or ip commands: wlan0, eth0, etc.

	Depends on <iptables> for IP masquerading, <NetworkManager> for handling interfaces, <hostapd> for
	creating the AP, and <dnsmasq> for assigning IP addresses (DHCP).
	
	The interface used for the AP is disallowed from being managed by the NetworkManager service.
	A hostapd configuration file (hostapd.conf) and dnsmasq configuration file (dnsmasq.conf) are
	always required for the AP. If the required AP and dnsmasq configuration files are missing they
	will be generated with default settings.

	Routing is enabled during AP usage, as well as IP masquerading (NAT) using iptables. These are
	both disabled again after the AP is taken down using the -r flag.
	
	Any settings changed from their defaults using flags (DHCP start address: -s <IP-address>; DHCP
	end address: -e <IP-address>; etc.) persist between script runs.
	
	[OPTIONS]
	    [-h | --help]
	        Displays this help screen and exits.
	
	    [-a | --apaddress] <ip-address>
	        Set the access point IP address.
	        Default: 10.0.0.1
	
	    [-s | --dhcpstart] <ip-address>
	        Set the DHCP range start IP address.
	        Default: 10.0.0.10
	
	    [-e | --dhcpend] <ip-address>
	        Set the DHCP range end IP address.
	        Default: 10.0.0.20
	
	    [-n | --netmask] <netmask>
	        Set the DHCP netmask.
	        Default: 255.255.255.0
	
	    [-l | --dhcplease] <lease-time>
	        Set the DHCP lease time.
	        Default: 12h
	
	    [-r | --removeap]
	       Remove the AP if it is running, disable routing, and disable IP masquerading.
	
	[EXAMPLES]
	    captureAP.sh wlan0 wlan1
	    captureAP.sh eth0 wlan0
	    captureAP.sh -e 10.0.0.50 wlan0 wlan1
	    captureAP.sh -r


######################
##### KNOWN BUGS #####
######################


Sometimes when launching the AP it will not indicate any errors, but the AP will not be visible. Simply running the script once or twice more fixes it.
