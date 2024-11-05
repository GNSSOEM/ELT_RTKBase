//---------------------------------------------------------------------------

#ifndef MainH
#define MainH
//---------------------------------------------------------------------------
#include <Classes.hpp>
#include <Controls.hpp>
#include <StdCtrls.hpp>
#include <Forms.hpp>
#include <Dialogs.hpp>
//---------------------------------------------------------------------------
#define MAX_SSH 8192
//---------------------------------------------------------------------------
class TfmMain : public TForm
{
__published:	// IDE-managed Components
        TGroupBox *gbWifi;
        TEdit *edSSID;
        TEdit *edKey;
        TLabel *lbKey;
        TLabel *lbSSID;
        TCheckBox *cbHidden;
        TGroupBox *gbSet;
        TCheckBox *cbWifi;
        TCheckBox *cbCountry;
        TCheckBox *cbUser;
        TGroupBox *gbCountry;
        TComboBox *cbxCountry;
        TGroupBox *gbUser;
        TLabel *lbLogin;
        TLabel *lbPwd;
        TButton *btnSave;
        TButton *btntQuit;
        TEdit *edLogin;
        TEdit *edPwd;
        TButton *btnSSH;
        TOpenDialog *OpenDialog;
        TGroupBox *gbIPeth;
        TLabel *lbETH_Prefix;
        TLabel *lbETH_IP;
        TEdit *edETH_IP;
        TEdit *edETH_Prefix;
        TLabel *lbETH_Gate;
        TEdit *edETH_Gate;
        TLabel *lbETH_DNS;
        TEdit *edETH_DNS;
        TGroupBox *gbIPwifi;
        TLabel *lbWIFI_Prefix;
        TLabel *lbWIFI_IP;
        TLabel *lbWIFI_Gate;
        TLabel *lbWIFI_DNS;
        TEdit *edWIFI_IP;
        TEdit *edWIFI_Prefix;
        TEdit *edWIFI_Gate;
        TEdit *edWIFI_DNS;
        TCheckBox *cbIPeth;
        TCheckBox *cbIPwifi;
        TGroupBox *gbEthIP;
        TRadioButton *rbEthStatic;
        TRadioButton *rbEthDHCP;
        TGroupBox *gbWifiIP;
        TRadioButton *rbWifiStatic;
        TRadioButton *rbWifiDHCP;
        void __fastcall cbWifiClick(TObject *Sender);
        void __fastcall cbCountryClick(TObject *Sender);
        void __fastcall cbUserClick(TObject *Sender);
        void __fastcall btnSaveClick(TObject *Sender);
        void __fastcall btntQuitClick(TObject *Sender);
        void __fastcall SaveChange(TObject *Sender);
        void __fastcall btnSSHClick(TObject *Sender);
        void __fastcall FormCreate(TObject *Sender);
        void __fastcall cbIPethClick(TObject *Sender);
        void __fastcall cbIPwifiClick(TObject *Sender);
private:	// User declarations
        char sshkey[MAX_SSH];
        void AddCountryLine(const char *str);
        void FillCountryList(TCustomComboBox *cbxCountry);
        void FillUserInfo(void);
        int FindRtkbaseDevice(void);
public:		// User declarations
        __fastcall TfmMain(TComponent* Owner);
};
//---------------------------------------------------------------------------
extern PACKAGE TfmMain *fmMain;
//---------------------------------------------------------------------------
#endif
