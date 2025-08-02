#!/bin/bash
#Tar command to create a release, excluding unuseful folders and files.

ARCHIVE_NAME='ELT_RTKBase.tar.xz'
BUNDLE_NAME='../install.sh'
TAR_ARG='-cJf'

tar --exclude-vcs \
    $TAR_ARG $ARCHIVE_NAME \
    NmeaConf UM980_RTCM3_OUT.txt UM982_RTCM3_OUT.txt \
    run_cast_sh.patch UnicoreSetBasePos.sh \
    uninstall.sh rtkbase_install.sh UnicoreConfigure.sh \
    RtkbaseSystemConfigure.sh RtkbaseSystemConfigure.service \
    server_py.patch settings_conf_default.patch \
    status_js.patch tune_power.sh config.txt rtklib/*.patch \
    settings_js.patch base_html.patch RTKBaseConfigManager_py.patch \
    Bynav_RTCM3_OUT.txt Septentrio_TEST.txt rtklib/aarch64/* \
    Septentrio_RTCM3_OUT.txt settings_html.patch \
    ppp_conf.patch config.original tailscale_get_href.sh \
    system_upgrade.sh exec_update.sh rtkbase_network_event.sh \
    rtkbase_check_internet.sh rtkbase_check_internet.service \
    rtkbase_septentrio_NAT.sh rtkbase_septentrio_NAT.service \
    rtkbase_DHCP.conf rtkbase_DHCP.service str2str_ntrip_C.service \
    str2str_ntrip_D.service str2str_ntrip_E.service favicon.ico \
    99-ELT0x33.rules startELT0x33.sh onoffELT0x33.sh \
    str2str_rtcm_svr.patch str2str_tcp.patch ntrip_led.sh \
    str2str_ntrip_A.patch  Rtcm3Led rtkbase_check_satelites.sh \
    rtkbase_check_satelites.service PBC.sh reboot.sh \
    70-usb-net-septentrio.link 77-mm-septentio-port-types.rules \
    reset_receiver.sh autoconnect-retries-forever.conf \
    70-usb-net-mobile.link gnss_rproxy_server_py.patch \
    rtkbase_modem_web_proxy.service opizero_temp_offset.patch \
    X20P_RTCM3_OUT.txt config.original2

rm -f $BUNDLE_NAME
cat install_script.sh $ARCHIVE_NAME > $BUNDLE_NAME
chmod +x $BUNDLE_NAME
rm -f $ARCHIVE_NAME
echo '========================================================'
echo 'Bundled script ' $BUNDLE_NAME ' created inside' $(pwd)
echo '========================================================'
