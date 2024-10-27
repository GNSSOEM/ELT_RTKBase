object fmMain: TfmMain
  Left = 984
  Top = 89
  BorderStyle = bsToolWindow
  Caption = 'Win RtkBase Configure'
  ClientHeight = 397
  ClientWidth = 392
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'MS Sans Serif'
  Font.Style = []
  OldCreateOrder = False
  Position = poDefaultSizeOnly
  OnCreate = FormCreate
  PixelsPerInch = 96
  TextHeight = 13
  object gbWifi: TGroupBox
    Left = 8
    Top = 104
    Width = 185
    Height = 97
    Caption = 'Wifi'
    Enabled = False
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'MS Sans Serif'
    Font.Style = []
    ParentFont = False
    TabOrder = 0
    object lbKey: TLabel
      Left = 8
      Top = 48
      Width = 18
      Height = 13
      Caption = 'Key'
      Enabled = False
    end
    object lbSSID: TLabel
      Left = 8
      Top = 24
      Width = 28
      Height = 13
      Caption = 'SSID:'
      Enabled = False
    end
    object edSSID: TEdit
      Left = 56
      Top = 24
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 0
      OnChange = SaveChange
    end
    object edKey: TEdit
      Left = 56
      Top = 48
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 1
    end
    object cbHidden: TCheckBox
      Left = 8
      Top = 72
      Width = 97
      Height = 17
      BiDiMode = bdLeftToRight
      Caption = 'Hidden SSID'
      Enabled = False
      ParentBiDiMode = False
      TabOrder = 2
    end
  end
  object gbSet: TGroupBox
    Left = 8
    Top = 8
    Width = 379
    Height = 89
    Anchors = [akLeft, akTop, akRight]
    Caption = 'Using'
    Color = clBtnFace
    ParentColor = False
    TabOrder = 1
    object cbWifi: TCheckBox
      Left = 8
      Top = 16
      Width = 90
      Height = 17
      Caption = 'WiFi'
      TabOrder = 0
      OnClick = cbWifiClick
    end
    object cbCountry: TCheckBox
      Left = 8
      Top = 40
      Width = 90
      Height = 17
      Caption = 'WiFi Country'
      TabOrder = 1
      OnClick = cbCountryClick
    end
    object cbUser: TCheckBox
      Left = 96
      Top = 16
      Width = 90
      Height = 17
      Caption = 'User'
      TabOrder = 2
      OnClick = cbUserClick
    end
    object cbIPeth: TCheckBox
      Left = 96
      Top = 40
      Width = 90
      Height = 17
      Caption = 'Ethernet IP'
      TabOrder = 3
      OnClick = cbIPethClick
    end
    object cbIPwifi: TCheckBox
      Left = 8
      Top = 64
      Width = 90
      Height = 17
      Caption = 'WiFi IP'
      TabOrder = 4
      OnClick = cbIPwifiClick
    end
    object gbEthIP: TGroupBox
      Left = 192
      Top = 8
      Width = 181
      Height = 36
      Anchors = [akLeft, akTop, akRight]
      Caption = 'Ethernet IP'
      Enabled = False
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGrayText
      Font.Height = -11
      Font.Name = 'MS Sans Serif'
      Font.Style = []
      ParentFont = False
      TabOrder = 5
      object rbEthStatic: TRadioButton
        Left = 16
        Top = 16
        Width = 50
        Height = 17
        Caption = 'Static'
        TabOrder = 0
        OnClick = cbIPethClick
      end
      object rbEthDHCP: TRadioButton
        Left = 104
        Top = 16
        Width = 70
        Height = 17
        Caption = 'DHCP'
        Checked = True
        TabOrder = 1
        TabStop = True
        OnClick = cbIPethClick
      end
    end
    object gbWifiIP: TGroupBox
      Left = 192
      Top = 48
      Width = 181
      Height = 36
      Anchors = [akLeft, akTop, akRight]
      Caption = 'WiFi IP'
      Enabled = False
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGrayText
      Font.Height = -11
      Font.Name = 'MS Sans Serif'
      Font.Style = []
      ParentFont = False
      TabOrder = 6
      object rbWifiStatic: TRadioButton
        Left = 16
        Top = 16
        Width = 50
        Height = 17
        Caption = 'Static'
        TabOrder = 0
        OnClick = cbIPwifiClick
      end
      object rbWifiDHCP: TRadioButton
        Left = 96
        Top = 16
        Width = 70
        Height = 17
        Caption = 'DHCP'
        Checked = True
        TabOrder = 1
        TabStop = True
        OnClick = cbIPwifiClick
      end
    end
  end
  object gbCountry: TGroupBox
    Left = 8
    Top = 208
    Width = 185
    Height = 57
    Caption = 'Wifi Country'
    Enabled = False
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'MS Sans Serif'
    Font.Style = []
    ParentFont = False
    TabOrder = 2
    object cbxCountry: TComboBox
      Left = 8
      Top = 24
      Width = 169
      Height = 21
      Style = csDropDownList
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      ItemHeight = 13
      TabOrder = 0
      OnChange = SaveChange
    end
  end
  object gbUser: TGroupBox
    Left = 200
    Top = 104
    Width = 185
    Height = 105
    Caption = 'User'
    Enabled = False
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'MS Sans Serif'
    Font.Style = []
    ParentFont = False
    TabOrder = 3
    object lbLogin: TLabel
      Left = 8
      Top = 24
      Width = 26
      Height = 13
      Caption = 'Login'
      Enabled = False
    end
    object lbPwd: TLabel
      Left = 8
      Top = 48
      Width = 41
      Height = 13
      Caption = 'Pasword'
      Enabled = False
    end
    object edLogin: TEdit
      Left = 56
      Top = 24
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 0
      OnChange = SaveChange
    end
    object edPwd: TEdit
      Left = 56
      Top = 48
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 1
      OnChange = SaveChange
    end
    object btnSSH: TButton
      Left = 8
      Top = 72
      Width = 169
      Height = 25
      Anchors = [akLeft, akTop, akRight]
      Caption = 'Load SSH public key'
      Enabled = False
      TabOrder = 2
      OnClick = btnSSHClick
    end
  end
  object btnSave: TButton
    Left = 200
    Top = 364
    Width = 129
    Height = 25
    Caption = 'Save'
    Enabled = False
    TabOrder = 4
    OnClick = btnSaveClick
  end
  object btntQuit: TButton
    Left = 338
    Top = 364
    Width = 47
    Height = 25
    Cancel = True
    Caption = 'Quit'
    ModalResult = 2
    TabOrder = 5
    OnClick = btntQuitClick
  end
  object gbIPeth: TGroupBox
    Left = 200
    Top = 216
    Width = 185
    Height = 127
    Caption = 'Ethernet IP'
    Enabled = False
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'MS Sans Serif'
    Font.Style = []
    ParentFont = False
    TabOrder = 6
    object lbETH_Prefix: TLabel
      Left = 8
      Top = 48
      Width = 26
      Height = 13
      Caption = 'Prefix'
      Enabled = False
    end
    object lbETH_IP: TLabel
      Left = 8
      Top = 24
      Width = 10
      Height = 13
      Caption = 'IP'
      Enabled = False
    end
    object lbETH_Gate: TLabel
      Left = 8
      Top = 72
      Width = 42
      Height = 13
      Caption = 'Gateway'
      Enabled = False
    end
    object lbETH_DNS: TLabel
      Left = 8
      Top = 96
      Width = 23
      Height = 13
      Caption = 'DNS'
      Enabled = False
    end
    object edETH_IP: TEdit
      Left = 56
      Top = 24
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 0
      Text = '192.168.1.2'
      OnChange = SaveChange
    end
    object edETH_Prefix: TEdit
      Left = 56
      Top = 48
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 1
      Text = '24'
    end
    object edETH_Gate: TEdit
      Left = 56
      Top = 72
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 2
      Text = '192.168.1.1'
    end
    object edETH_DNS: TEdit
      Left = 56
      Top = 96
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      BiDiMode = bdLeftToRight
      Enabled = False
      ParentBiDiMode = False
      TabOrder = 3
      Text = '8.8.8.8'
    end
  end
  object gbIPwifi: TGroupBox
    Left = 8
    Top = 264
    Width = 185
    Height = 127
    Caption = 'WiFi IP'
    Enabled = False
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -11
    Font.Name = 'MS Sans Serif'
    Font.Style = []
    ParentFont = False
    TabOrder = 7
    object lbWIFI_Prefix: TLabel
      Left = 8
      Top = 48
      Width = 26
      Height = 13
      Caption = 'Prefix'
      Enabled = False
    end
    object lbWIFI_IP: TLabel
      Left = 8
      Top = 24
      Width = 10
      Height = 13
      Caption = 'IP'
      Enabled = False
    end
    object lbWIFI_Gate: TLabel
      Left = 8
      Top = 72
      Width = 42
      Height = 13
      Caption = 'Gateway'
      Enabled = False
    end
    object lbWIFI_DNS: TLabel
      Left = 8
      Top = 96
      Width = 23
      Height = 13
      Caption = 'DNS'
      Enabled = False
    end
    object edWIFI_IP: TEdit
      Left = 56
      Top = 24
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 0
      Text = '192.168.1.3'
      OnChange = SaveChange
    end
    object edWIFI_Prefix: TEdit
      Left = 56
      Top = 48
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 1
      Text = '24'
    end
    object edWIFI_Gate: TEdit
      Left = 56
      Top = 72
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      Enabled = False
      TabOrder = 2
      Text = '192.168.1.1'
    end
    object edWIFI_DNS: TEdit
      Left = 56
      Top = 96
      Width = 121
      Height = 21
      Anchors = [akLeft, akTop, akRight]
      BiDiMode = bdLeftToRight
      Enabled = False
      ParentBiDiMode = False
      TabOrder = 3
      Text = '8.8.8.8'
    end
  end
  object OpenDialog: TOpenDialog
    DefaultExt = 'pub'
    Filter = '*.pub|*.pub|All|*.*'
    Options = [ofReadOnly, ofEnableSizing]
    Title = 'SSH public key'
    Left = 144
    Top = 64
  end
end
