@Rem RTK for Unicore
@Echo On
@Title RTK for Unicore
@SetLocal ENABLEEXTENSIONS
@Set IniFile=Ini.cmd

@Set RecvIP=rtkbase.local
@Set RecvPort=5016
@Set RtcmIP=igs-ip.net
@Set RtcmPort=2101
@Set RtcmMount=RIGA00LVA0
@Set RtcmUser=abc
@Set RtcmPwd=123
@Set Period=86400

@If EXIST %IniFile% @Call %IniFile%
@Echo Enter parametries...
@Set /P RecvIP=Receiver IP addr (%RecvIP%):
@Set /P RecvPort=Receiver port (%RecvPort%):
@Set /P RtcmIP=RTCM3 server IP (%RtcmIP%):
@Set /P RtcmPort=RTCM3 server port (%RtcmPort%):
@Set /P RtcmMount=RTCM3 server mountpoint (%RtcmMount%):
@Set /P RtcmUser=RTCM3 server user (%RtcmUser%):
@Set /P RtcmPwd=RTCM3 server password (%RtcmPwd%):
@Set /P Period=Period in sec (%Period%):

@Rem Echo RecvIP=%RecvIP%
@Rem Echo RecvPort=%RecvPort%
@Rem echo RtcmIP=%RtcmIP%
@Rem echo RtcmPort=%RtcmPort%
@Rem echo RtcmMount=%RtcmMount%
@Rem echo RtcmUser=%RtcmUser%
@Rem echo RtcmPwd=%RtcmPwd%
@Rem echo Period=%Period%

@echo @Set RecvIP=%RecvIP%>%IniFile%
@echo @Set RecvPort=%RecvPort%>>%IniFile%
@echo @Set RtcmIP=%RtcmIP%>>%IniFile%
@echo @Set RtcmPort=%RtcmPort%>>%IniFile%
@echo @Set RtcmMount=%RtcmMount%>>%IniFile%
@echo @Set RtcmUser=%RtcmUser%>>%IniFile%
@echo @Set RtcmPwd=%RtcmPwd%>>%IniFile%
@echo @Set Period=%Period%>>%IniFile%

@Set Recv=%RecvIP%:%RecvPort%
@Echo Check Receiver on %Recv%...
@Set VerFile=versionRTK.tmp
@NmeaConf.exe +%Recv% UBX-MON-VER QUIET >%VerFile%
@If ERRORLEVEL 1 @(
    @Rem @Echo NmeaConf ErrorLevel=%ErrorLevel%
    @NmeaConf.exe +%Recv% Version QUIET >%VerFile%
    @If ERRORLEVEL 1 @(
        @Rem @Echo NmeaConf ErrorLevel=%ErrorLevel%
        @NmeaConf.exe +%Recv% "Log Version" QUIET >%VerFile%
        @If ERRORLEVEL 1 @(
            @Rem @Echo NmeaConf ErrorLevel=%ErrorLevel%
            @NmeaConf.exe +%Recv% SEPTENTRIO_TEST.txt QUIET >%VerFile%
            @If ERRORLEVEL 1 @(
               @Echo NOT connected to %Recv%
               @Pause
               @Exit
            ) Else @(
                 find "mosaic" %VerFile% >NUL
                 @If NOT ERRORLEVEL 1 @(
                     @Set Receiver=Septentrio
                     @Set Prefix=Septentrio
                 ) Else (
                     @Echo Receiver on %Recv% is Unknown
                     @Pause
                     @Exit
                )
            )
        ) Else @(
            @find "BDVER" %VerFile% >NUL
            @If NOT ERRORLEVEL 1 @(
                @Set Receiver=Bynav
                @Set Prefix=Bynav
            ) else (
                @Echo Receiver on %Recv% is Unknown
                @Pause
                @Exit
           )
        )
    ) Else @(
        @find "UM982"  %VerFile% >NUL
        @If NOT ERRORLEVEL 1 @(
            @Set Receiver=UM982
            @Set Prefix=UM
        ) else @(
            find "UM980"  %VerFile% >NUL
            @If NOT ERRORLEVEL 1 @(
                @Set Receiver=UM980
                @Set Prefix=UM
            ) else (
                @Echo Receiver on %Recv% is Unknown
                @Pause
                @Exit
           )
        )
    )
) Else (
  @find "ZED" %VerFile% >NUL
  @If NOT ERRORLEVEL 1 @(
      @Set Receiver=U-Blox
      @Set Prefix=Ublox
  ) else (
      @Echo Receiver on %Recv% is Unknown
      @Pause
      @Exit
  )
)
@Echo Receiver is %Receiver%

@Set Rtcm3=%RtcmIP%:%RtcmPort%/%RtcmMount%@%RtcmUser%:%RtcmPwd%
@Echo Check RTCM3 server on %Rtcm3%...
@NmeaConf.exe +%Rtcm3% - NOINFO
@If ERRORLEVEL 1 @(
    @Rem @Echo NmeaConf ErrorLevel=%ErrorLevel%
    @Echo NOT connected to %Rtcm3%
    @Pause
    @Exit
)

@Echo Configure %Receiver% on %Recv% as RTK...
@Set CoordFile=coordRTK.tmp
@NmeaConf.exe +%Recv% %Prefix%_RTK.txt NOMSG
@If ERRORLEVEL 1 @(
    @Rem @Echo NmeaConf ErrorLevel=%ErrorLevel%
    @Echo %Receiver% NOT configured as RTK on %Recv%
) else @(
    @Echo Counting base coordinates at %Period% seconds...
    @Rem Echo CoordFile=%CoordFile%
    @Rtcm3Save.exe +%Recv% +%Rtcm3% - %Period% 2>%CoordFile%
    @If ERRORLEVEL 1 @(
        @Rem @Echo Rtcm3Save ErrorLevel=%ErrorLevel%
        @Echo base coordinates NOT counting because ERROR
    ) else @(
        @Echo Base coordinates:
        @Copy %CoordFile% CON >NUL
        @Echo !
        @Clip <%CoordFile%
    )
)

@Echo Restore BASE configuration %Receiver% on %Recv%
@NmeaConf.exe +%Recv% %Prefix%_RESET.txt NOMSG
@If ERRORLEVEL 1 @(
    @Rem @Echo NmeaConf ErrorLevel=%ErrorLevel%
    @Echo %Receiver% NOT configured as base on %Recv%
    @Pause
    @Exit
)

@EndLocal
@Pause
