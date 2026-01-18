#!/bin/bash

for service_name in str2str_ntrip_A.service \
                    str2str_ntrip_B.service \
                    str2str_local_ntrip_caster \
                    str2str_rtcm_svr.service \
                    str2str_rtcm_client.service \
                    str2str_rtcm_udp_svr.service \
                    str2str_rtcm_udp_client.service \
                    str2str_rtcm_serial.service \
                    str2str_file.service \
                    str2str_tcp.service \
                    rtkrcv_raw2nmea.service \
                    rtkbase_web.service \
                    rtkbase_archive.service \
                    rtkbase_archive.timer \
                    modem_check.service \
                    modem_check.timer \
                    rtkbase_gnss_web_proxy.service \
                    rtkbase_modem_web_proxy.service \
                    RtkbaseSystemConfigure.service \
                    rtkbase_system_configure.service \
                    rtkbase_check_internet.service \
                    rtkbase_check_satelites.service \
                    rtkbase_septentrio_NAT.service \
                    rtkbase_DHCP.service
do
    service_active=$(systemctl is-active "${service_name}")
    if [ "${service_active}" != "inactive" ]; then
       echo ${service_name} is ${service_active}
    fi
done
