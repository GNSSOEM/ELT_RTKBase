# ELT_RTKBase

### Raspberry Pi OS compatible RtkBase software for Unicore UM98x, Bynav M2x, Septentrio Mosaic X5 and u-blox ZED-X20P

Based on [RtkBase](https://github.com/Stefal/rtkbase) by Stefal


## Easy installation:
+ Connect your Unicore, Bynav, Septentrio or u-blox receiver to your raspberry pi/orange pi/....

+ Open a terminal and:

  ```bash
  wget https://github.com/GNSSOEM/ELT_RTKBase/raw/main/install.sh
  chmod +x install.sh
  ./install.sh
  ```
+ RTFM

## Two phase installation:
+ ./install.sh -1 for part of installation without receiver
+ Connect the GNSS receiver to the Raspberry Pi
+ ./install.sh -2 for part of installation with receiver

## Main features, added to RTKBase

+ Use Unicore, Bynav, Septentrio or Ublox receiver
+ Full configure for receiver and Raspberry Pi
+ If mount and password are both TCP, use TCP-client instead of NTRIP-server
+ Setup base position to receiver
+ Timeout for PPP-solution is extended to 36 hours
+ Default settings is adopted to Unicore, Bynav, Septentrio or u-blox receiver, onocoy.com and rtkdirect.com
+ Windows RTK & HAS utilities for precise resolving RTK base position
+ Zeroconf configuration as rtkbase.local in the local network
+ When speed changed in main settings, speed of receiver will be changing too
+ Configuring WiFi via an Windows application  (not only on first boot)
+ Adding users via an Windows application  (not only on first boot)
+ Complete [documentation](./Doc/ELT_RTKBase_v1.8.1_EN.pdf) with lots of pictures
+ Zeroconfig VPN by [Tailscale](https://tailscale.com)
+ System update & upgrade by button in the web-interface
+ Indication of disconnections with the NTRIP server in the web interface.
+ Support for static IP addresses
+ WPS PBC for WiFi
+ Internet access via 4G/5G USB modems such as Huawei HiLink.
+ Data Transmission via Radio Modem.
+ NTRIP 2.0
+ 5 NTRIP servers

## The next version is expected to include:
+ Host mode

## ready-made base stations:
You can buy ready-made base stations at [gnss.store](https://gnss.store/78-cors-fanless-stations). To choose stations, read [our blog](https://gnss.store/blog/category/-choosing-a-base-station-for-onocoy.html).

## License:
ELT_RTKBase is licensed under AGPL 3 (see [LICENSE](./LICENSE) file).

ELT_RTKBase uses [RtkBase](https://github.com/Stefal/rtkbase) (AGPL v3) by Stefal

ELT_RTKBase uses [PBC](https://github.com/kcdtv/PBC) (GPL v3) by kcdtv

ELT_RTKBase uses [ntripserver](https://github.com/simeononsecurity/ntripserver) (GPL v2) by German Federal Agency for Cartography and Geodesy (BKG)

ELT_RTKBase uses [GPSD](https://gitlab.com/gpsd/gpsd) ([BSD](https://gitlab.com/gpsd/gpsd/-/blob/master/COPYING)) by [authors](https://gitlab.com/gpsd/gpsd/-/blob/master/AUTHORS)
