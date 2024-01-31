#!/bin/bash
# created by Jeff Cassell <jeffrey.cassell@utsa.edu> or <jeffscassell@protonmail.com>
# SEP2023
# v1.0



###############################
########## VARIABLES ##########
###############################

warning="    [WARNING]"
error="    [ERROR]"

internetInterface=""
apInterface=""

apIpAddress="10.0.0.1"

dhcpRangeStart="10.0.0.10"
dhcpRangeEnd="10.0.0.20"
dhcpNetmask="255.255.255.0"
dhcpLeaseTime="12h"

hostapdConfigName="hostapd.conf"

###############################
########## FUNCTIONS ##########
###############################
#
# Functions are read, but not executed, until they are called.
#
# Commands will return an exit status of 0 if they run successfully (can successfully ping google,
# grep finds a match for a pattern, etc.). Functions will return the exit status of the last command they ran.
# If a 0 is returned into an <if> statement, it will execute the code within.
#
# If a function accepts arguments, they are in the form of $1, $2, ... for argument 1, argument 2, ...,
# similar to how scripts accept arguments.
#

printUsage(){
	echo "[USAGE]"
	echo "    captureAP.sh [OPTIONS] <internet-interface> <AP-interface>"
	echo ""
	echo ""
	echo "[DESCRIPTION]"
	echo ""
	echo "This script creates a local Wi-Fi AP (access point) using hostapd and connects it to the"\
		"internet via an existing network connection, confirmed working with either ethernet or"\
		"Wi-Fi, but should be compatible with any network interface. The interfaces will be things such"\
		"as found in the ifconfig command: wlan0, eth0, etc."
	echo ""
	echo "The interface used for the AP is disallowed from being managed by the NetworkManager service."\
		"A hostapd configuration file (hostapd.conf) and dnsmasq configuration file (dnsmasq.conf) are"\
		"always required for the AP. If the required AP and dnsmasq configuration files are missing they"\
		"will be generated with default settings."
	echo ""
	echo "Routing is enabled during AP usage, as well as IP masquerading (NAT) using iptables. These are"\
		"both disabled again after the AP is taken down using the -r flag."
	echo ""
	echo "Any settings changed from their defaults using flags (DHCP start address: -s <IP-address>; DHCP"\
		"end address: -e <IP-address>; etc.) persist between script runs."
	echo ""
	echo "[OPTIONS]"
	echo "    [-h | --help]"
	echo "        Displays this help screen and exits."
	echo ""
	echo "    [-a | --ap-address] <ip-address>"
	echo "        Set the access point IP address."
	echo "        Default: 10.0.0.1"
	echo ""
	echo "    [-s | --dhcp-start] <ip-address>"
	echo "        Set the DHCP range start IP address."
	echo "        Default: 10.0.0.10"
	echo ""
	echo "    [-e | --dhcp-end] <ip-address>"
	echo "        Set the DHCP range end IP address."
	echo "        Default: 10.0.0.20"
	echo ""
	echo "    [-n | --netmask] <netmask>"
	echo "        Set the DHCP netmask."
	echo "        Default: 255.255.255.0"
	echo ""
	echo "    [-l | --dhcp-lease] <lease-time>"
	echo "        Set the DHCP lease time."
	echo "        Default: 12h"
	echo ""
	echo "    [-r | --remove-ap]"
	echo "       Remove the AP if it is running, disable routing, and disable IP masquerading."
	echo ""
	echo "[EXAMPLES]"
	echo "    captureAP.sh wlan0 wlan1"
	echo "    captureAP.sh eth0 wlan0"
	echo "    captureAP.sh -e 10.0.0.50 wlan0 wlan1"
	echo "    captureAP.sh -r"
}

# uses regex to determine if a passed argument is a valid IP address
# $1=ip-address
isIpAddress(){
echo "$1" | grep -q -E "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
}

# tries to ping google once to see if internet is working
# redirects stdout to /dev/null, and stderr to stdout
# the normal stdout/stderr &> redirect doesn't work as normal within scripts for some reason
internetIsUp(){ ping -c 1 google.com > /dev/null 2>&1; }

# $1=process-to-find
processIsRunning(){ pgrep $1 > /dev/null; }

# checks iptables to see if the passed interface is already being masqueraded
# $1=network-interface
masqueradeRuleExists(){ iptables -t nat -C POSTROUTING -o $1 -j MASQUERADE > /dev/null 2>&1; }
deleteMasqueradeRule(){ iptables -t nat -D POSTROUTING -o $1 -j MASQUERADE > /dev/null 2>&1; }
appendMasqueradeRule(){ iptables -t nat -A POSTROUTING -o $1 -j MASQUERADE > /dev/null 2>&1; }

isValidInterface(){ ifconfig $1 > /dev/null 2>&1; }
isWirelessInterface(){ iwconfig $1 > /dev/null 2>&1; }

checkInterfaces(){
	internetInterface=$1
	apInterface=$2

	# make sure passed-in arguments are valid interfaces
	if [ -z "$internetInterface" ]; then
		printMissingValueFor "internet-interface"
		exit 1
	elif [ -z "$apInterface" ]; then
		printMissingValueFor "AP-interface"
		exit 1
	elif ! isValidInterface $internetInterface || ! isValidInterface $apInterface; then
		echo "$error One or more passed arguments is not a valid network interface"
		exit 1
	elif [ "$internetInterface" = "$apInterface" ]; then
		echo "$error Must use 2 different network interfaces."
		exit 1
	elif ! isWirelessInterface $apInterface; then
		echo "$error The AP interface must be wireless."
		exit 1
	fi
}

# part of automated reporting for missing arguments when script is run
printMissingValueFor(){ echo "$error No value supplied for: <$1>"; }
printInvalidValueFor(){ echo "$error Invalid value supplied for <$1>: $2"; }

printPass(){ echo "[OK]"; }
printFail(){ echo "<!>"; }

# uses pass-by-reference (sort of) to update passed variables with passed values
# expects the variable value ($3) to be an IP address
# $1=variable-to-update, $2=message-to-report, $3=IP-address-variable-value
setAddress(){
	if [ -z "$3" ]; then
		printMissingValueFor "$2"
		exit 1
	elif isIpAddress "$3"; then
		eval "$1=$3"
	else
		printInvalidValueFor "$2" "$3"
		exit 1
	fi
}

# expects 1-3 numbers with an h or H on the end, e.g., 12h
# $1=dhcp-lease-time
setDhcpLeaseTime(){
	if [ -z "$1" ]; then
		printMissingValueFor "DHCP-lease"
		exit 1
	elif echo $1 | grep -q -E "^[0-9]{1,3}[hH]$"; then
		dhcpLeaseTime="$1"
	else
		printInvalidValueFor "DHCP-lease" "$1"
		exit 1
	fi
}

apConfigExists(){
	[ -e "hostapd.conf" ] || return
	grep -q "interface=wlan." hostapd.conf || return
	grep -q "channel=." hostapd.conf || return
	grep -q "ssid=." hostapd.conf || return
}

makeApConfig(){
	touch hostapd.conf
	echo "########## GENERAL SETTINGS ##########" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "# interface to use for the AP" >> hostapd.conf
	echo "interface=$apInterface" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "# simplified: g=2.4GHz, a=5GHz" >> hostapd.conf
	echo "hw_mode=g" >> hostapd.conf
	echo "channel=2" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "# a limited version of QoS" >> hostapd.conf
	echo "# apparently necessary for full speed on 802.11n/ac/ax connections" >> hostapd.conf
	echo "wmm_enabled=1" >> hostapd.conf
	echo "country_code=US" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "# limit frequencies to those permitted by the country code" >> hostapd.conf
	echo "#ieee80211d=1" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "# 802.11n support" >> hostapd.conf
	echo "ieee80211n=1" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "# 802.11ac support" >> hostapd.conf
	echo "ieee80211ac=1" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "########## SSID SETTINGS ##########" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "ssid=2.4GHz_Capture_Network" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "# 1=WPA, 2=WEP, 3=both" >> hostapd.conf
	echo "#auth_algs=1" >> hostapd.conf
	echo "" >> hostapd.conf
	echo "# WPA2 only" >> hostapd.conf
	echo "#wpa=2" >> hostapd.conf
	echo "#wpa_key_mgmt=WPA-PSK" >> hostapd.conf
	echo "#rsn_pairwise=CCMP" >> hostapd.conf
	echo "#wpa_passphrase=ChAnGeMe" >> hostapd.conf
}

dnsmasqConfigExists(){
	[ -e /etc/dnsmasq.conf ] || return
	grep -q "interface=wlan." /etc/dnsmasq.conf || return
	grep -q "dhcp-range=.." /etc/dnsmasq.conf || return
	grep -q "dhcp-option=3,." /etc/dnsmasq.conf || return
	grep -q "dhcp-option=6,." /etc/dnsmasq.conf || return
}

makeDnsmasqConfig(){
	touch dnsmasq.conf
	echo "# listening interface" >> dnsmasq.conf
	echo "interface=$apInterface" >> dnsmasq.conf
	echo "" >> dnsmasq.conf
	echo "dhcp-range=$dhcpRangeStart,$dhcpRangeEnd,$dhcpNetmask,$dhcpLeaseTime" >> dnsmasq.conf
	echo "# client default gateway" >> dnsmasq.conf
	echo "dhcp-option=3,$apIpAddress" >> dnsmasq.conf
	echo "# client DNS server" >> dnsmasq.conf
	echo "dhcp-option=6,$apIpAddress" >> dnsmasq.conf
	mv dnsmasq.conf /etc/
}

updateConfigs(){
	# if dnsmasq.conf file doesn't exit, exit with error
	[ ! -e /etc/dnsmasq.conf ] && echo "$error <dnsmasq.conf> could not be found for updating" && exit 1
	
	# update dnsmasq config
	sed -i "s/interface=.*/interface=$apInterface/" /etc/dnsmasq.conf
	sed -i "s/dhcp-range=.*/dhcp-range=$dhcpRangeStart,$dhcpRangeEnd,$dhcpNetmask,$dhcpLeaseTime/"\
		/etc/dnsmasq.conf
	sed -i "s/dhcp-option=3,.*/dhcp-option=3,$apIpAddress/" /etc/dnsmasq.conf
	sed -i "s/dhcp-option=6,.*/dhcp-option=6,$apIpAddress/" /etc/dnsmasq.conf

	# exit with error if hostapd.conf isn't found
	[ ! -e hostapd.conf ] && echo "$error <hostapd.conf> could not be found for updating" && exit 1

	# update ap config
	sed -i "s/interface=.*/interface=$apInterface/" hostapd.conf
}

validateConfigs(){
	echo -n "Checking /etc/<dnsmasq.conf>... "
	if ! dnsmasqConfigExists; then
		echo ""
		echo "$warning Missing or misconfigured file: /etc/<dnsmasq.conf>"
		echo "Creating file with default settings. Check for accuracy."
		makeDnsmasqConfig
	else
		printPass
	fi

	echo -n "Checking <hostapd.conf>... "
	if ! apConfigExists; then
		echo ""
		echo "$warning Missing or misconfigured file: <hostapd.conf>"
		echo "Creating file with default settings. Check for accuracy."
		makeApConfig
	else
		printPass
	fi
}

# ensures persistent settings between runs. e.g., if the AP was launched with the DHCP range ending
# at 10.0.0.50, it uses those settings again
readApVariablesFromDnsmasqConfig(){
	[ -e /etc/dnsmasq.conf ] || return  # only execute the rest if the file exists

	# extract the dhcp-range variable's value from dnsmasq.conf
	existingRangeValues=$(cat /etc/dnsmasq.conf | grep "dhcp-range=" | sed "s/.*=//")

	# parse the extracted value using sed capture groups
	dhcpRangeStart=$(echo $existingRangeValues | sed -E "s/(.*),(.*),(.*),(.*)/\1/")
	dhcpRangeEnd=$(echo $existingRangeValues | sed -E  "s/(.*),(.*),(.*),(.*)/\2/")
	dhcpNetmask=$(echo $existingRangeValues | sed -E  "s/(.*),(.*),(.*),(.*)/\3/")
	dhcpLeaseTime=$(echo $existingRangeValues | sed -E  "s/(.*),(.*),(.*),(.*)/\4/")

	# extract the AP's IP address from the first dhcp-option variable's value
	# (could also do it with the second option variable, the first was chosen arbitrarily)
	apIpAddress=$(cat /etc/dnsmasq.conf | grep "dhcp-option=3" | sed "s/.*,//")
}

readApVariablesFromHostapdConfig(){
	[ -e hostapd.conf ] || return

}

# $1=interface
disallowManagingInterface(){ nmcli dev set $1 managed no; }
allowManagingInterface(){ nmcli dev set $1 managed yes; }

killRunningAp(){
	# kill any existing AP currently running
	if processIsRunning "hostapd"; then
		echo "$warning Killing still-running AP..."
		pkill hostapd
	fi
}

# make sure script is run as root
checkForRoot(){
	if [ ! $(id -u) = 0 ]; then
		echo "$error Script must be run with super user privileges (root). Exiting."
		exit 1
	fi
}

main(){
	#
	# these functions are only called from within main()
	#
	
	# the final message printed after finished running
	##################### TODO update to include network name and channel
	printFinished(){
		echo "Finished."
		echo ""
		echo "NOTE: If the AP is not visible, run the script again. It's a known bug."
		echo ""
		echo "AP:"
		#echo "       Network Name: $networkSsid"
		#echo "    Network Channel: $networkChannel"
		echo "         IP Address: $apIpAddress"
		echo "            Netmask: $dhcpNetmask"
		echo ""
		echo "         DHCP Start: $dhcpRangeStart"
		echo "           DHCP End: $dhcpRangeEnd"
		echo "    DHCP Lease Time: $dhcpLeaseTime"
	}

	# check that the <hostapd> command is installed and accessible
	hostapdInstalled(){ command -v hostapd > /dev/null; }

	# start forwarding packets not addressed to us (routing)
	startRouting(){
		echo -n "Enabling routing... "
		#sysctl -n net.ipv4.conf.all.forwaring  # will return just the value (1 if already enabled)
		if sysctl -q net.ipv4.conf.all.forwarding=1; then  # -q suppresses feedback output
			printPass
		else
			echo ""
			echo "$error problem enabling routing"
			exit 1
		fi
	}

	# start NAT functionality (IP masquerading) between AP and internet interfaces
	startMasquerade(){
		# check if iptables was previously configured with the other interface and remove if so
		if masqueradeRuleExists $apInterface; then
			echo "$warning Removing old iptables rule"
			deleteMasqueradeRule "$apInterface"
		fi
		
		# make sure the correct interface rule is not already there before inserting it
		if ! masqueradeRuleExists $internetInterface; then
			echo -n "Enabling IP masquerading... "
			if appendMasqueradeRule "$internetInterface"; then
				printPass
			else
				printFail
				echo "$error could not append IP masquerade rule into <iptables>"
				exit 1
			fi
		else
			echo "IP masquerading already in place."
		fi
	}

	stopManagingApInterface(){
		echo -n "Disallowing AP interface from being managed by <NetworkManager>... "
		if disallowManagingInterface "$apInterface"; then
			printPass
		else
			printFail
			echo "$error could not prevent <NetworkManager> from managing <$apInterface>"
			exit 1
		fi
	}

	launchAp(){
		echo -n "Launching AP... "
		if hostapd -B hostapd.conf > ap.log; then  ############# TODO make a real running log
			printPass
		else
			printFail
			echo "$error could not launch AP. Check <ap.log> for details"
			exit 1
		fi
	}

	# write the interfaces that were used to file so tear down can be performed with -r flag.
	# should update this so that these are output to a separate file to prevent
	# potential problems
	writeInterfacesToFile(){
		sed -i "s/apInterface=\"\"/apInterface=$apInterface/" "$0"
		sed -i "s/internetInterface=\"\"/internetInterface=$internetInterface/" "$0"
	}

	configureApIpAddress(){
		echo -n "Configuring AP's IP address <$apIpAddress>... "
		ip add flush dev $apInterface
		if ifconfig $apInterface $apIpAddress netmask $dhcpNetmask; then
			printPass
		else
			printFail
			echo "$error could not assign IP address to interface <$ipInterface>"
			exit 1
		fi
	}

	startDnsmasq(){
		if ! processIsRunning "dnsmasq"; then
			echo -n "Starting <dnsmasq> service for DHCP and DNS hosting... "
			if systemctl start dnsmasq; then
				printPass
			else
				printFail
				echo "error could not start <dnsmasq> service"
				exit 1
			fi
		else
			echo "$warning <dnsmasq> service already started"
			echo -n "Restarting <dnsmasq> service for DHCP and DNS hosting... "
			if systemctl restart dnsmasq; then
				printPass
			else
				printFail
				echo "$error could not restart <dnsmasq> service"
				exit 1
			fi
		fi
	}

	########## INTERNET CONNECTIVITY SETUP ##########

	if ! hostapdInstalled; then
		echo "$error <hostapd> command/package missing. Exiting."
		exit 1
	fi
	
	startRouting
	startMasquerade
	
	########## AP SETUP ##########

	stopManagingApInterface

	launchAp  ################### contains a bug! occassionally the AP will show as started,
	# but is not visible to stations (even though the process is running successfully).
	# this is likely due to some service trying to manage the interface (and none should be,
	# besides <hostapd>)

	writeInterfacesToFile
	configureApIpAddress
	startDnsmasq
	printFinished
}

removeAp(){
	# stop running if either interface variables are empty (assigned values if the AP was launched)
	if [ -z "$apInterface" ] || [ -z "$internetInterface" ]; then
		echo "$error Script was not run previously to create an AP. AP interface and/or internet"\
			"interface cannot be restored because it is unknown"
		exit 1
	fi

	echo "Stopping AP..."
	pkill hostapd
	
	echo "Flushing access point IP address..."
	ip add flush dev $apInterface
	
	echo "Allowing AP interface to be managed..."
	allowManagingInterface $apInterface
	
	echo "Stopping <dnsmasq> service..."
	systemctl stop dnsmasq
	
	# remove iptables IP masquerade rule
	if masqueradeRuleExists "$internetInterface"; then
		echo "Removing <iptables> IP masquerading rule..."
		deleteMasqueradeRule "$internetInterface"
	else
		echo "<iptables> IP masquerading rule already removed."
	fi
	
	echo "Disabling routing..."
	sysctl -q net.ipv4.conf.all.forwarding=0

	# remove interface assignments so next run the variables will be empty
	# only removes the first instance (which is at the top) to avoid damaging rest of script
	# this method only works in GNU sed
	sed -i "0,/apInterface=.*/s/apInterface=.*/apInterface=\"\"/" "$0"
	sed -i "0,/internetInterface=.*/s/internetInterface=.*/internetInterface=\"\"/" "$0"
	
	echo "Finished."
}

###################################
########## PROGRAM START ##########
###################################

# no arguments were passed with the script
if [ "$#" = 0 ]; then
	printUsage
	exit 1
fi

readApVariablesFromDnsmasqConfig

# parse inputs
while [ "$#" -gt 0 ]; do  # loop while the number of passed arguments is greater than 0
	case "$1" in
		-h|--help)
			printUsage
			exit 1
			;;
		-s|--dhcp-start)
			setAddress "dhcpRangeStart" "DHCP-range-start" "$2"
			shift 2  # remove the first 2 arguments and loop again
			;;
		-e|--dhcp-end)
			setAddress "dhcpRangeEnd" "DHCP-range-end" "$2"
			shift 2
			;;
		-a|--ap-address)
			setAddress "apIpAddress" "AP-IP-address" "$2"
			shift 2
			;;
		-n|--netmask)
			setAddress "dhcpNetmask" "DHCP-netmask" "$2"
			shift 2
			;;
		-l|--dhcp-lease)
			setDhcpLeaseTime "$2"
			shift 2
			;;
		-r|--remove-ap)
			checkForRoot
			removeAp
			exit 0
			;;
		*)
			checkForRoot

			# if $3 is non-zero (3rd arg is present), too many args
			[ -n "$3" ] && printUsage && exit 1

			# if $2 is zero (2nd arg is missing), interface args missing
			[ -z "$2" ] && printUsage && exit 1

			killRunningAp
			checkInterfaces "$1" "$2"
			validateConfigs
			updateConfigs
			main
			exit 0
			;;
	esac
done

