#!/bin/bash
version=0.5

# PBC.sh is a bash script that acts like an emulator of WPS button, usimg wpa_supplicant to perform a WPS PBC (Push button Configuration) connexion.
# Copyright (C) 2017 kcdtv @ www.wifi-libre.com
# This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with this program; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
# Contact author: kcdtv@wifi-libre.com

# Global variables:
# - Colours
nocolour="\033[0;37m"
orange="\033[38;5;202m"
purpple="\033[1;35m"
red="\033[1;31m"
yellow="\033[1;33m"
white="\033[1;37m"
green="\033[1;32m"   
blue="\033[1;36m"
# - ugly walk around for some issues i had with $? value in trap function
error=1

# Functions
# - Cleaning to do on exit state 1 
function ciao {
if [ "$error" == 1 ] ; 
  then
    echo -e "
$orange▐█   Killing remaining process$nocolour"
    killall wpa_supplicant dhclient &>/dev/null
    echo -e "$orange▐█   Restarting Network Manager$nocolour"
    systemctl restart NetworkManager.service
    echo -e "$orange▐█   Cleaning up$nocolour"
    rm -r /tmp/interfaces.txt /tmp/PBC.conf &>/dev/null
elif [ "$error" == 2 ] ;
  then  
    rm -r /tmp/interfaces.txt
fi
echo -e "$nocolour
 To launch the script again just press [up] than [ENTER] ;)

Copyright (C) 2017 kcdtv @ www.wifi-libre.com (see the GPLv3 license provided)"
} 

# Script
trap ciao EXIT
echo -e "$white
                              ▄▄▄·▄▄▄▄·  ▄▄· 
                            ▐█ ▄█▐█ ▀█▪▐█ ▌▪
                             ██▀·▐█▀▀█▄██ ▄▄
                            ▐█▪·•██▄▪▐█▐███▌ $nocolour.sh$white
                            .▀   ·▀▀▀▀ ·▀▀▀ $nocolour version: $version

                    Virtual$purpple WPS PBC$white button for$purpple GNU-Linux$nocolour

Copyright (C) 2017 kcdtv @ www.wifi-libre.com (see the GPLv3 license provided)
"



# Script
echo -e "$white▐█$purpple   Privileges check...$nocolour"  
whoami | grep root || { echo -e "$red▐█   Error$nocolour - You need root privileges. Run the script again with$white sudo$nocolour or$white su$nocolour. 
$red▐█   Exit.$nocolour" 1>&2; error=0;  exit 1; }
echo -e "$white▐█$purpple   Interface(s) check...$nocolour" 
iwconfig 2>/dev/null | tee /tmp/interfaces.txt
    if [ "$(wc -w < /tmp/interfaces.txt)" == 0 ]; 
      then
        echo -e "$red▐█   Error$nocolour - No wireless interface detected.
$red▐█   Exit.$nocolour"
        error=2
        exit 1   
    elif [ "$(grep -c IEEE /tmp/interfaces.txt)" == 1 ];
      then
interface=$(head -n 1 /tmp/interfaces.txt | awk '{ print $1 }')  
        echo -e "$white▐█$purpple   One wifi interface has been detected and automaticaly selected: $green$interface$nocolour"
    else
        while [ -z "$interface" ]; 
          do
            echo -e "$white▐█$purpple   Several interfaces are available. Make your choice: $nocolour"
            echo -e "   num Interface $blue"
            grep IEEE /tmp/interfaces.txt | awk '{ print $1 }' | nl
            echo -e "$white▐█$purpple   Your choice:$yellow"
            read -r -n 1 -ep "     " num
            interface=$(grep IEEE /tmp/interfaces.txt | awk '{ print $1 }' | sed "$num!d" 2>/dev/null )   
                if [ -z "$interface" ]; 
                  then
                    echo -e "$red▐█   Error$nocolour - There is no interface associated with the entered number ($num).

$orange▐█   Back to the interface selection...$nocolour
" 1>&2
                else
                    echo -e "
$green▐█$purpple   Selected interface is $green$interface$nocolour
" 
                fi
        done
    fi
echo -e "$white▐█$purpple   Shutting down network manager$nocolour (wifi connexion will be lost)"
systemctl stop NetworkManager.service
echo -e "$white▐█$purpple   Killing conflictual process$nocolour"
killall wpa_supplicant dhclient 2>/dev/null
echo -e "$white▐█$purpple   Soft block control$nocolour"
rfkill unblock wifi
echo -e "$white▐█$purpple   Managed mode control$nocolour"
ip link set "$interface" down
iwconfig "$interface" mode managed
ip link set "$interface" up
echo -e "$white▐█$purpple   Creation of wpa_supplicant configuration file$nocolour" 
echo "ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=root
update_config=1" > /tmp/PBC.conf
echo -e "$white▐█$purpple   Launching wpa-supplicant$nocolour"
wpa_supplicant -c /tmp/PBC.conf -i "$interface" -B 
echo -e "$white   
                              ▄▄▄·▄▄▄▄·  ▄▄· 
                            ▐█ ▄█▐█ ▀█▪▐█ ▌▪
                             ██▀·▐█▀▀█▄██ ▄▄
                            ▐█▪·•██▄▪▐█▐███▌ 
$green             Pushing virtual$white.▀   ·▀▀▀▀ ·▀▀▀$green button !!!$nocolour  
"
wpa_cli -i "$interface" wps_pbc any
krono=120
    while [ $krono -gt 0 ]; 
      do
        krono=$((krono - 1))
        echo -ne "$green▐█$purpple   You have $yellow$krono$white seconds left to push the button on your acess point$nocolour\033[0K\r"
            if ( grep -q "network=" /tmp/PBC.conf ) ;
              then
                echo -e "

$green▐█   Key negociation completed!$nocolour"
                wpakey=$( grep "psk=" /tmp/PBC.conf | cut -d = -f 2 | cut  -c 2- | rev | cut -c 2- | rev )
                echo -e "
$white▐█$purpple   WPA Key:$yellow $wpakey$nocolour"
                essid=$( grep "ssid=" /tmp/PBC.conf | cut -d = -f 2 | tr -d '"' )
                echo -e "$white▐█$purpple   Killing conflictual process$nocolour"
                killall wpa_supplicant dhclient 2>/dev/null
                echo -e "$white▐█$purpple   Restarting Newtork Manager$nocolour"
                systemctl restart NetworkManager.service
                echo -e "$white▐█$purpple   Exporting profile for$yellow $essid$purpple to Network Manager$nocolour"
                already=$(sudo nmcli --get-values NAME connection show | grep "$essid")
                [[ "$already" != "" ]] && nmcli connection delete id "$essid"
                nmcli con add con-name "$essid" ifname "*" type wifi ssid "$essid"
                nmcli con modify "$essid" wifi-sec.key-mgmt wpa-psk 
                nmcli con modify "$essid" wifi-sec.psk "$wpakey" 
                echo -e "$white▐█$purpple   Cleaning temporary files"
                rm -r /tmp/interfaces.txt /tmp/PBC.conf  
                echo -e "$white▐█$purpple   Connecting to the network with Network Manager$nocolour"
                nmcli connection up "$essid" || { echo -e "

$red▐█   Error$nocolour -$yellow Conexion failure.$red Exit.$nocolour
   
 Sorry... :(
    
     Maybe Check your AP configuration and try again? 
    You can Scrwoll back in the shell to copy the WPA key
    and use it in network manager" 1>&2; exit 1; }
                echo -e "
    
$green▐█        You are now connected!!

$white Have a good time on the Internet! Cya! ;) 
" 1>&2
                error=0                
                exit 0 
            fi   
    sleep 1       
done
echo -e "

$red▐█   Error$nocolour -$yellow Conexion failure.$red Exit.$nocolour

$white   Sorry! It was impossible to connect to the PA...$nocolour
"  1>&2
exit 1
