#!/bin/bash
# created by Jeff Cassell <jeffrey.cassell@utsa.edu> or <jeffscassell@protonmail.com>
# SEP2023
# v1.1



###############################
########## VARIABLES ##########
###############################

warning="    [WARNING]"
error="    [ERROR]"

internetInterface=""
apInterface=""

apIpAddress="10.0.0.1"
networkSsid="2.4GHz_Capture_Network"

dhcpRangeStart="10.0.0.10"
dhcpRangeEnd="10.0.0.20"
dhcpNetmask="255.255.255.0"
dhcpLeaseTime="12h"

#scriptDirectory=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
hostapdConfig="hostapd.conf"
dnsmasqConfigName="dnsmasq.conf"

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
	echo "This script creates a local Wi-Fi AP (access point) and connects it to the"\
		"internet via an existing network connection, confirmed working with either ethernet or"\
		"Wi-Fi, but should be compatible with any network interface. The interfaces will be things such"\
		"as found in the ifconfig command (depending on Linux distribution): wlan0, eth0, etc."
	echo ""
	echo "Depends on <iptables> for IP masquerading, <NetworkManager> for handling interfaces, <hostapd> for"\
		"creating the AP, and <dnsmasq> for assigning IP addresses (DHCP)."
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
	echo "    [-a | --apaddress] <ip-address>"
	echo "        Set the access point IP address."
	echo "        Default: 10.0.0.1"
	echo ""
	echo "    [-s | --dhcpstart] <ip-address>"
	echo "        Set the DHCP range start IP address."
	echo "        Default: 10.0.0.10"
	echo ""
	echo "    [-e | --dhcpend] <ip-address>"
	echo "        Set the DHCP range end IP address."
	echo "        Default: 10.0.0.20"
	echo ""
	echo "    [-n | --netmask] <netmask>"
	echo "        Set the DHCP netmask."
	echo "        Default: 255.255.255.0"
	echo ""
	echo "    [-l | --dhcplease] <lease-time>"
	echo "        Set the DHCP lease time."
	echo "        Default: 12h"
	echo ""
	echo "    [-r | --remove]"
	echo "       Remove the AP if it is running, disable routing, and disable IP masquerading."
	echo ""
	echo "[EXAMPLES]"
	echo "    captureAP.sh wlan0 wlan1"
	echo "    captureAP.sh eth0 wlan0"
	echo "    captureAP.sh -e 10.0.0.50 wlan0 wlan1"
	echo "    captureAP.sh -r"
}

printPass(){ echo "[OK]"; }
printFail(){ echo "<!>"; }

# part of automated reporting for missing arguments when script is run
printMissingValueFor(){ echo "$error No value supplied for: <$1>"; }
printInvalidValueFor(){ echo "$error Invalid value supplied for <$1>: $2"; }

# uses regex to determine if a passed argument is a valid IP address
# $1=ip-address
isIpAddress(){
echo "$1" | grep -q -E "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
}

# tries to ping google once to see if internet is working
# redirects stdout to /dev/null, and stderr to stdout
# the normal stdout/stderr &> redirect doesn't work as normal within scripts for some reason (sometimes)
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

validateInterfaces(){
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

checkDependencies(){
	isInstalled(){ dpkg -s "$1" 2> /dev/null | grep -q "install ok installed"; }
	printMissingDependency(){ echo "$error <$1> package missing."; }
	missingDependency=0

	for dependency in hostapd iptables dnsmasq; do
		if ! isInstalled "$dependency"; then
			missingDependency=1
			printMissingDependency "$dependency"
		fi
	done

	if [ "$missingDependency" = 1 ]; then
		exit 1
	fi
}

# uses pass-by-reference (sort of) to update passed variables with passed values
# expects the variable value ($3) to be an IP address
# needs an update for better sanitization
# $1=variable-to-update, $2=message-to-report, $3=IP-address-variable-value
setIpAddress(){
	if [ -z "$3" ]; then  # 
		printMissingValueFor "$2"
		exit 1
	elif isIpAddress "$3"; then
		eval "$1=$3"  # a dangerous command that should be sanitized carefully
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

hostapdConfigIsValid(){
	[ -e "$hostapdConfig" ] || return
	grep -q "interface=wlan." $hostapdConfig || return
	grep -q "channel=." $hostapdConfig || return
	grep -q "ssid=." $hostapdConfig || return
}

makeHostapdConfig(){
	touch $hostapdConfig
	echo "########## GENERAL SETTINGS ##########" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# interface to use for the AP" >> $hostapdConfig
	echo "interface=$apInterface" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# simplified: g=2.4GHz, a=5GHz" >> $hostapdConfig
	echo "hw_mode=g" >> $hostapdConfig
	echo "channel=2" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# a limited version of QoS" >> $hostapdConfig
	echo "# apparently necessary for full speed on 802.11n/ac/ax connections" >> $hostapdConfig
	echo "wmm_enabled=1" >> $hostapdConfig
	echo "country_code=US" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# limit frequencies to those permitted by the country code" >> $hostapdConfig
	echo "#ieee80211d=1" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# 802.11n support" >> $hostapdConfig
	echo "ieee80211n=1" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# 802.11ac support" >> $hostapdConfig
	echo "ieee80211ac=1" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "########## SSID SETTINGS ##########" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "ssid=$networkSsid" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# COMMENT THE BELOW LINES TO DISABLE WPA2 ENCRYPTION" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# 1=WPA, 2=WEP, 3=both" >> $hostapdConfig
	echo "auth_algs=1" >> $hostapdConfig
	echo "" >> $hostapdConfig
	echo "# WPA2 only" >> $hostapdConfig
	echo "wpa=2" >> $hostapdConfig
	echo "wpa_key_mgmt=WPA-PSK" >> $hostapdConfig
	echo "rsn_pairwise=CCMP" >> $hostapdConfig
	echo "wpa_passphrase=changeme" >> $hostapdConfig
}

dnsmasqConfigIsValid(){
	[ -e "$dnsmasqConfigName" ] || return
	grep -q "interface=wlan." $dnsmasqConfigName || return
	grep -q "dhcp-range=.." $dnsmasqConfigName || return
	grep -q "dhcp-option=3,." $dnsmasqConfigName || return
	grep -q "dhcp-option=6,." $dnsmasqConfigName || return
}

makeDnsmasqConfig(){
	touch $dnsmasqConfigName
	echo "# listening interface" >> $dnsmasqConfigName
	echo "interface=$apInterface" >> $dnsmasqConfigName
	echo "" >> $dnsmasqConfigName
	echo "dhcp-range=$dhcpRangeStart,$dhcpRangeEnd,$dhcpNetmask,$dhcpLeaseTime" >> $dnsmasqConfigName
	echo "# client default gateway" >> $dnsmasqConfigName
	echo "dhcp-option=3,$apIpAddress" >> $dnsmasqConfigName
	echo "# client DNS server" >> $dnsmasqConfigName
	echo "dhcp-option=6,$apIpAddress" >> $dnsmasqConfigName
}

updateConfigs(){
	# if dnsmasq.conf file doesn't exist, exit with error
	[ ! -e "$dnsmasqConfigName" ] && echo "$error <dnsmasq.conf> could not be found for updating" && exit 1
	
	# update dnsmasq config
	sed -i "s/interface=.*/interface=$apInterface/" $dnsmasqConfigName
	sed -i "s/dhcp-range=.*/dhcp-range=$dhcpRangeStart,$dhcpRangeEnd,$dhcpNetmask,$dhcpLeaseTime/"\
		$dnsmasqConfigName
	sed -i "s/dhcp-option=3,.*/dhcp-option=3,$apIpAddress/" $dnsmasqConfigName
	sed -i "s/dhcp-option=6,.*/dhcp-option=6,$apIpAddress/" $dnsmasqConfigName

	# exit with error if hostapd.conf isn't found
	[ ! -e "$hostapdConfig" ] && echo "$error <hostapd.conf> could not be found for updating" && exit 1

	# update ap config
	sed -i "s/interface=.*/interface=$apInterface/" $hostapdConfig
}

validateConfigs(){
	echo -n "Checking /etc/<dnsmasq.conf>... "
	if ! dnsmasqConfigIsValid; then
		echo ""
		echo "$warning Missing or misconfigured file: /etc/<dnsmasq.conf>"
		echo "$warning Creating file with default settings. Check for accuracy."
		makeDnsmasqConfig
	else
		printPass
	fi

	echo -n "Checking <hostapd.conf>... "
	if ! hostapdConfigIsValid; then
		echo ""
		echo "$warning Missing or misconfigured file: <hostapd.conf>"
		echo "Creating file with default settings. Check for accuracy."
		makeHostapdConfig
	else
		printPass
	fi
}

# ensures persistent settings between runs. e.g., if the AP was launched with the DHCP range ending
# at 10.0.0.50, it uses those settings again
readApVariablesFromDnsmasqConfig(){
	[ -e "$dnsmasqConfigName" ] || return  # only execute the rest if the file exists

	# extract the dhcp-range variable from dnsmasq.conf
	# will be in the format:
	# dhcp-range=10.0.0.10,10.0.0.20,255.255.255.0,12h
	existingRangeValues=$(cat $dnsmasqConfigName | grep "dhcp-range=" | sed "s/.*=//")

	# parse the extracted variable using sed capture groups
	dhcpRangeStart=$(echo $existingRangeValues | sed -E "s/(.*),(.*),(.*),(.*)/\1/")
	dhcpRangeEnd=$(echo $existingRangeValues | sed -E  "s/(.*),(.*),(.*),(.*)/\2/")
	dhcpNetmask=$(echo $existingRangeValues | sed -E  "s/(.*),(.*),(.*),(.*)/\3/")
	dhcpLeaseTime=$(echo $existingRangeValues | sed -E  "s/(.*),(.*),(.*),(.*)/\4/")

	# extract the AP's IP address from the first dhcp-option variable's value
	# (could also do it with the second option variable, the first was chosen arbitrarily)
	apIpAddress=$(cat $dnsmasqConfigName | grep "dhcp-option=3" | sed "s/.*,//")
}

readApVariablesFromHostapdConfig(){
	[ -e "$hostapdConfig" ] || return
	networkSsid=$(cat $hostapdConfig | grep "ssid=" | sed "s/ssid=//")
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
		printUsage
		echo ""
		echo "#########"
		echo "# ERROR #"
		echo "#########"
		echo ""
		echo "$error Script must be run with super user privileges (root). Exiting."
		echo ""
		exit 1
	fi
}

main(){
	#
	# these functions are only called from within main()
	#
	
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
		# TODO restructure so that this is the last function to call? then on CTRL-C,
		# perform tear-down automatically?
		if hostapd -B $hostapdConfig > /dev/null; then  # TODO make a real running log
			printPass
		else
			printFail
			echo "$error could not launch AP."
			exit 1
		fi
	}

	# write down the interfaces that were used to a file so tear down can be performed with -r flag.
	# should update this so that these are output to a separate file to prevent
	# potential problems with overwrites.
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
			echo "$error could not assign IP address to interface <$apInterface>"
			exit 1
		fi
	}

	startDnsmasq(){
		if ! processIsRunning "dnsmasq"; then
			echo -n "Starting <dnsmasq> service for DHCP and DNS hosting... "
			if dnsmasq --conf-file=$dnsmasqConfigName --interface=$apInterface; then
				printPass
			else
				printFail
				echo "$error could not start <dnsmasq> service"
				exit 1
			fi
		else
			echo "$warning <dnsmasq> service already started"
			echo -n "$warning Restarting <dnsmasq> service for DHCP and DNS hosting... "
			systemctl stop dnsmasq
			pkill dnsmasq
			if dnsmasq --conf-file=$dnsmasqConfigName --interface=$apInterface; then
				printPass
			else
				printFail
				echo "$error could not restart <dnsmasq> service"
				exit 1
			fi
		fi
	}

	printFinished(){
		echo "Finished."
		echo ""
		echo "############"
		echo "# ! NOTE ! #"
		echo "############"
		echo ""
		echo "If the AP is not visible, run the script again. It's a known bug."
		echo "To remove the AP, run the script again with the -r or --remove argument."
		echo ""
		echo "AP:"
		echo "       Network Name: $networkSsid"
		#echo "    Network Channel: $networkChannel"
		echo "         IP Address: $apIpAddress"
		echo "            Netmask: $dhcpNetmask"
		echo ""
		echo "         DHCP Start: $dhcpRangeStart"
		echo "           DHCP End: $dhcpRangeEnd"
		echo "    DHCP Lease Time: $dhcpLeaseTime"
	}

	########## INTERNET CONNECTIVITY SETUP ##########
	
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
			"interface cannot be restored because it is unknown."
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
	pkill dnsmasq
	
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

checkForRoot
checkDependencies
readApVariablesFromDnsmasqConfig
readApVariablesFromHostapdConfig

# parse inputs
while [ "$#" -gt 0 ]; do  # loop while the number of passed script arguments is greater than 0
	case "$1" in
		-h|--help)
			printUsage
			exit 1
			;;
		-s|--dhcpstart)
			setIpAddress "dhcpRangeStart" "DHCP-range-start" "$2"
			shift 2  # remove the first 2 arguments and loop again
			;;
		-e|--dhcpend)
			setIpAddress "dhcpRangeEnd" "DHCP-range-end" "$2"
			shift 2
			;;
		-a|--apaddress)
			setIpAddress "apIpAddress" "AP-IP-address" "$2"
			shift 2
			;;
		-n|--netmask)
			setIpAddress "dhcpNetmask" "DHCP-netmask" "$2"
			shift 2
			;;
		-l|--dhcplease)
			setDhcpLeaseTime "$2"
			shift 2
			;;
		-r|--remove)
			removeAp
			exit 0
			;;
		*)
			# if $3 is non-zero (3rd arg is present), too many args
			[ -n "$3" ] && printUsage && exit 1

			# if $2 is zero (2nd arg is missing), interface args missing
			[ -z "$2" ] && printUsage && exit 1

			killRunningAp
			validateInterfaces "$1" "$2"
			validateConfigs
			updateConfigs
			main
			exit 0
			;;
	esac
done

