#!/bin/bash
#

WPS_FLAG=/usr/local/rtkbase/WPS.flg
HOTSPOT_FLAG=/usr/local/rtkbase/HOTSPOT.flg
RESET_INTERNET_LED_FLAG=/usr/local/rtkbase/reset_intenet_led.flg
FLAG=/usr/local/rtkbase/NetworkChange.flg
FLAG_INITED=/usr/local/rtkbase/MosaicInited.flg
rm -f ${HOTSPOT_FLAG}
rm -f ${WPS_FLAG}
rm -f ${RESET_INTERNET_LED_FLAG}
rm -f ${FLAG}
rm -f ${FLAG_INITED}

