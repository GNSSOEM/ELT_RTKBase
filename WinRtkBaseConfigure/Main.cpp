//---------------------------------------------------------------------------

#include <vcl.h>
#include <stdio.h>
#include <sys/stat.h>
#include "iso3166.h"
#pragma hdrstop

#include "Main.h"
//---------------------------------------------------------------------------
#ifndef FILE_READ_ONLY_VOLUME
#define FILE_READ_ONLY_VOLUME 0x00080000
#endif //FILE_READ_ONLY_VOLUME
//---------------------------------------------------------------------------
#pragma package(smart_init)
#pragma resource "*.dfm"
#pragma resource "iso3166.res"
TfmMain *fmMain = NULL;
//---------------------------------------------------------------------------
__fastcall TfmMain::TfmMain(TComponent* Owner)
        : TForm(Owner)
{
   *sshkey = 0;
}
//---------------------------------------------------------------------------
#define COUNTRY_POS 3
void TfmMain::AddCountryLine(const char *str)
{
   if (*str == '#')
      return;
   int code = (*str << 8) | str[1];
   const char *country = &str[COUNTRY_POS];
   cbxCountry->Items->AddObject(country,(TObject *)code);
};
//---------------------------------------------------------------------------
void TfmMain::FillCountryList(TCustomComboBox *cbxCountry)
{
   cbxCountry->Items->Clear();
   TResourceStream *ResStream = new TResourceStream((int)GetModuleHandle(NULL),IDD_RCDATA_ISO3166, RT_RCDATA);
   try {
      char *source = new char[ResStream->Size+1];
      try {
          source[ResStream->Size] = 0;
          ResStream->Read(source,  ResStream->Size);
          #define STR_LEN 80
          char str[STR_LEN+1];
          int ind = 0;
          char *p = source;
          while (*p) {
             char c = *p++;
             if ((c == '\n') || (c == '\r')) {
                str[ind] = 0;
                if (ind > COUNTRY_POS)
                   AddCountryLine(str);
                ind = 0;
             } else {
               str[ind++] = c;
               if (ind >= STR_LEN) {
                  str[ind] = 0;
                  AddCountryLine(str);
                  ind = 0;
               }
             }
          } // while (*p)
      } __finally {
          delete [] source;
      }
   } __finally {
     delete ResStream;
   }
}
//---------------------------------------------------------------------------
bool DirExists(const char *DirName)
{
   struct stat st;
   bool Res = bool(stat(DirName,&st) == 0);
   if (Res)
      Res = (st.st_mode & S_IFDIR) != 0;
   return Res;
};
//---------------------------------------------------------------------------
bool checkLogin(const char *str)
{
   int len = strlen(str);
   bool good = false;
   for (int i=0; i < len; i++) {
      char c = str[i];
      if (islower(c))
         good = true;
      else if ((i > 0) && (isdigit(c) || (c == '-') || (c == '_')))
        good = true;
      else if ((i == (len-1)) && (c == '$'))
        good = true;
      else {
        good = false;
        break;
      }
   }
   return good;
}
//---------------------------------------------------------------------------
void TfmMain::FillUserInfo(void)
{
   const char *userprofile = getenv("USERPROFILE");
   if (userprofile) {
      char sshpath[MAX_PATH];
      snprintf(sshpath, MAX_PATH, "%s\\.ssh", userprofile);
      sshpath[MAX_PATH-1] = 0;
      bool sshExist = DirExists(sshpath);
      if (sshExist) {
         OpenDialog->InitialDir = sshpath;
         char id_rsa_pub[MAX_PATH];
         snprintf(id_rsa_pub, MAX_PATH, "%s\\id_rsa.pub", sshpath);
         id_rsa_pub[MAX_PATH-1] = 0;
         bool pubExists = FileExists(id_rsa_pub);
         if (pubExists) {
            OpenDialog->FileName = id_rsa_pub;
         }
      }; // if (sshExist)
   }; // if (userprofile)

   const char *username = getenv("USERNAME");
   if (username) {
      #define MAX_LOGIN 80
      char login[MAX_LOGIN+1];
      int len = strlen(username);
      if (len > MAX_LOGIN)
         len = MAX_LOGIN;
      strncpy(login, username, len);
      login[len] = 0;
      for (int i=0; i< len; i++)
          login[i] = (char)tolower(login[i]);
      if (checkLogin(login))
         edLogin->Text = login;
   }
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::FormCreate(TObject *)
{
   FillCountryList(cbxCountry);
   FillUserInfo();
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::cbWifiClick(TObject *)
{
   bool enabled = cbWifi->Checked;
   gbWifi->Enabled = enabled;
   lbSSID->Enabled = enabled;
   edSSID->Enabled = enabled;
   lbKey->Enabled = enabled;
   edKey->Enabled = enabled;
   cbHidden->Enabled = enabled;
   gbWifi->Font->Color = enabled ? clWindowText : clGrayText;
   SaveChange(NULL);
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::cbCountryClick(TObject *)
{
   bool enabled = cbCountry->Checked;
   gbCountry->Enabled = enabled;
   cbxCountry->Enabled = enabled;
   gbCountry->Font->Color = enabled ? clWindowText : clGrayText;
   SaveChange(NULL);
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::cbUserClick(TObject *)
{
   bool enabled = cbUser->Checked;
   gbUser->Enabled = enabled;
   lbLogin->Enabled = enabled;
   edLogin->Enabled = enabled;
   lbPwd->Enabled = enabled;
   edPwd->Enabled = enabled;
   btnSSH->Enabled = enabled;
   gbUser->Font->Color = enabled ? clWindowText : clGrayText;
   SaveChange(NULL);
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::cbIPethClick(TObject *)
{
   bool enabled1 = cbIPeth->Checked;
   gbEthIP->Enabled = enabled1;
   rbEthStatic->Enabled = enabled1;
   rbEthDHCP->Enabled = enabled1;
   gbEthIP->Font->Color = enabled1 ? clWindowText : clGrayText;

   bool enabled2 = enabled1 && rbEthStatic->Checked;
   gbIPeth->Enabled = enabled2;
   lbETH_IP->Enabled = enabled2;
   edETH_IP->Enabled = enabled2;
   lbETH_Prefix->Enabled = enabled2;
   edETH_Prefix->Enabled = enabled2;
   lbETH_Gate->Enabled = enabled2;
   edETH_Gate->Enabled = enabled2;
   lbETH_DNS->Enabled = enabled2;
   edETH_DNS->Enabled = enabled2;
   gbIPeth->Font->Color = enabled2 ? clWindowText : clGrayText;

   SaveChange(NULL);
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::cbIPwifiClick(TObject *)
{
   bool enabled1 = cbIPwifi->Checked;
   gbWifiIP->Enabled = enabled1;
   rbWifiStatic->Enabled = enabled1;
   rbWifiDHCP->Enabled = enabled1;
   gbWifiIP->Font->Color = enabled1 ? clWindowText : clGrayText;

   bool enabled2 = enabled1 && rbWifiStatic->Checked;
   gbIPwifi->Enabled = enabled2;
   lbWIFI_IP->Enabled = enabled2;
   edWIFI_IP->Enabled = enabled2;
   lbWIFI_Prefix->Enabled = enabled2;
   edWIFI_Prefix->Enabled = enabled2;
   lbWIFI_Gate->Enabled = enabled2;
   edWIFI_Gate->Enabled = enabled2;
   lbWIFI_DNS->Enabled = enabled2;
   edWIFI_DNS->Enabled = enabled2;
   gbIPwifi->Font->Color = enabled2 ? clWindowText : clGrayText;

   SaveChange(NULL);
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::SaveChange(TObject *)
{
   bool wifiOK = cbWifi->Checked && (edSSID->Text.Length() > 0);
   bool countryOK = cbCountry->Checked && (cbxCountry->ItemIndex >= 0);
   bool userOK = cbUser->Checked && (edLogin->Text.Length() > 0) &&
                 ((edPwd->Text.Length() > 0) || *sshkey);
   bool IPethOK = cbIPeth->Checked;
   bool IPwifiOK = cbIPwifi->Checked;
   bool enabled = wifiOK || countryOK || userOK || IPethOK || IPwifiOK;
   btnSave->Enabled = enabled;
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::btnSSHClick(TObject *)
{
   if (OpenDialog->Execute()) {
      FILE *sshFile = fopen(OpenDialog->FileName.c_str(), "rt");
      if (sshFile) {
         const char *str = fgets(sshkey, MAX_SSH, sshFile);
         if (!str) {
            *sshkey = 0;
            MessageDlg("Selected SSH pulic key read error", mtError, TMsgDlgButtons() << mbCancel, 0);
         }
         fclose(sshFile);
         int len=strlen(sshkey);
         while (len > 0) {
            len--;
            if (sshkey[len] <= ' ')
               sshkey[len] = 0;
            else
               break;
         }
      } else {
         MessageDlg("Selected SSH pulic key not open", mtError, TMsgDlgButtons() << mbCancel, 0);
      }
      SaveChange(NULL);
   }
}
//---------------------------------------------------------------------------
int TfmMain::FindRtkbaseDevice(void)
{
   int Result = -1;
   SetErrorMode(SEM_FAILCRITICALERRORS);
   DWORD devMask = GetLogicalDrives();
   for (int i=0; i < 32; i++) {
       if ((1 << i) & devMask) {
          char c = char('A'+i);
          char DevName[10];
          sprintf(DevName, "%c:", c);
          char  DeviceName[MAX_PATH];
          DWORD CharCount = QueryDosDeviceA(DevName, DeviceName, ARRAYSIZE(DeviceName));
          if (CharCount) {
             char RootName[10];
             sprintf(RootName, "%c:\\", c);
             int DriveType = GetDriveTypeA(RootName);
             if (DriveType == DRIVE_REMOVABLE) {
                char  VolumeName[MAX_PATH];
                DWORD VolumeSerialNumber;
                DWORD MaximumComponentLength;
                DWORD FileSystemFlags;
                char  FileSystemName[MAX_PATH];
                bool OK = GetVolumeInformationA(RootName, VolumeName, ARRAYSIZE(VolumeName),
                                                &VolumeSerialNumber, &MaximumComponentLength,
                                                &FileSystemFlags,
                                                FileSystemName, ARRAYSIZE(FileSystemName));

                if (OK && ((FileSystemFlags & FILE_READ_ONLY_VOLUME) == 0)) {
                   if (strcmp(FileSystemName, "FAT32") == 0) {
                      if (strcmp(VolumeName, "bootfs") == 0) {
                         char filename[MAX_PATH];
                         sprintf(filename, "%c:\config.txt", c);
                         bool haveConfig = FileExists(filename);
                         sprintf(filename, "%c:\cmdline.txt", c);
                         bool haveCmdline = FileExists(filename);
                         sprintf(filename, "%c:\BOOTCODE.BIN", c);
                         bool haveBootcode = FileExists(filename);
                         if (haveConfig && haveCmdline && haveBootcode) {
                            Result = c;
                            break;
                         }
                      }
                   }
                }
             }
          }
       }; // if ((1 << i) & devMask)
   }; // for (int i=0; i < 32; i++)
   return Result;
}
//---------------------------------------------------------------------------
AnsiString quoted(const AnsiString &str)
{
   AnsiString Res = "$'";
   const char *p=str.c_str();
   while (*p) {
      unsigned char c=*p++;
      switch(c) {
         case '\\': Res += "\\\\"; break;
         case '\'': Res += "\\\'"; break;
         case '\"': Res += "\\\""; break;
         default:   if ((c >= ' ') && (c < 127))
                        Res += AnsiString(c);
                    else if (c < 128)
                        Res += "\\x" + IntToHex(c,2);
                    else {
                       int cc=c;
                       wchar_t u[10];
                       int n = MultiByteToWideChar(CP_THREAD_ACP, MB_PRECOMPOSED, (char *)&cc, 1, u, 4);
                       for (int i=0; i<n; i++) {
                           Res += "\\u" + IntToHex(u[i],4);
                       }
                    };
      }; // switch(c)
   }; // while (*p)
   Res += "'";
   return Res;
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::btnSaveClick(TObject *)
{
   if (cbUser->Checked && !checkLogin(edLogin->Text.c_str())) {
      MessageDlg("Login not valid, please use small latin letter, digit, minus and underline", mtWarning, TMsgDlgButtons() << mbCancel, 0);
      return;
   }

   if ((cbCountry->Checked) && (cbxCountry->ItemIndex < 0)) {
      MessageDlg("Country not selected", mtWarning, TMsgDlgButtons() << mbCancel, 0);
      return;
   }

   int disk = FindRtkbaseDevice();
   if (disk < 0) {
      MessageDlg("SD card for Raspberri not found", mtWarning, TMsgDlgButtons() << mbCancel, 0);
      return;
   }

   char filename[MAX_PATH];
   sprintf(filename, "%c:\system.txt", disk);
   FILE *file = fopen(filename,"wt");
   if (file) {
      if (cbWifi->Checked) {
         fprintf(file,"SSID=%s\n",quoted(edSSID->Text).c_str());
         AnsiString key = edKey->Text;
         if (key.Length() > 0)
            fprintf(file,"KEY=%s\n", quoted(key).c_str());
         if (cbHidden->Checked)
            fprintf(file,"HIDDEN=Y\n");
      }
      if (cbCountry->Checked) {
         int code = (int)(cbxCountry->Items->Objects[cbxCountry->ItemIndex]);
         fprintf(file,"COUNTRY=%c%c\n",code >> 8, code & 0xFF);
      }
      if (cbUser->Checked) {
         fprintf(file,"LOGIN=%s\n",quoted(edLogin->Text).c_str());
         AnsiString pwd = edPwd->Text;
         if (pwd.Length() > 0)
            fprintf(file,"PWD=%s\n", quoted(pwd).c_str());
         if (*sshkey)
            fprintf(file,"SSH=\"%s\"\n", sshkey);
      }
      if (cbIPeth->Checked) {
         if (rbEthStatic->Checked) {
            AnsiString ip = edETH_IP->Text;
            AnsiString prefix = edETH_Prefix->Text;
            if ((ip.Length() > 0) && (prefix.Length() > 0))
               fprintf(file,"ETH_IP=\"%s/%s\"\n",ip.c_str(),prefix.c_str());
            AnsiString gate = edETH_Gate->Text;
            if (gate.Length() > 0)
               fprintf(file,"ETH_GATE=\"%s\"\n", gate.c_str());
            AnsiString dns = edETH_DNS->Text;
            if (dns.Length() > 0)
               fprintf(file,"ETH_DNS=\"%s\"\n", dns.c_str());
         } else
            fprintf(file,"ETH_IP=DHCP\n");
      }
      if (cbIPwifi->Checked) {
         if (rbWifiStatic->Checked) {
            AnsiString ip = edWIFI_IP->Text;
            AnsiString prefix = edWIFI_Prefix->Text;
            if ((ip.Length() > 0) && (prefix.Length() > 0))
               fprintf(file,"WIFI_IP=\"%s/%s\"\n",ip.c_str(),prefix.c_str());
            AnsiString gate = edWIFI_Gate->Text;
            if (gate.Length() > 0)
               fprintf(file,"WIFI_GATE=\"%s\"\n", gate.c_str());
            AnsiString dns = edWIFI_DNS->Text;
            if (dns.Length() > 0)
               fprintf(file,"WIFI_DNS=\"%s\"\n", dns.c_str());
         } else
            fprintf(file,"WIFI_IP=DHCP\n");
      }

      fclose(file);
      MessageDlg("RtkBase config save succesfully", mtConfirmation, TMsgDlgButtons() << mbOK, 0);
      this->Close();
   } else {
      MessageDlg("Save file not create", mtError, TMsgDlgButtons() << mbCancel, 0);
   }
}
//---------------------------------------------------------------------------
void __fastcall TfmMain::btntQuitClick(TObject *)
{
   this->Close();
}
//---------------------------------------------------------------------------

