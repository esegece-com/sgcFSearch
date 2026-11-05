object sgcFSearchFoldersForm: TsgcFSearchFoldersForm
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'sgcFSearch Folders'
  ClientHeight = 548
  ClientWidth = 520
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnShow = FormShow
  TextHeight = 15
  object lblRoots: TLabel
    Left = 12
    Top = 12
    Width = 320
    Height = 15
    Caption = 'Content folders (the text of their files is indexed)'
  end
  object lblSkip: TLabel
    Left = 12
    Top = 146
    Width = 220
    Height = 15
    Caption = 'Skip folders (never indexed)'
  end
  object lblDrives: TLabel
    Left = 12
    Top = 280
    Width = 280
    Height = 15
    Caption = 'Drives (none checked = all fixed drives)'
  end
  object lblHotkey: TLabel
    Left = 12
    Top = 414
    Width = 320
    Height = 15
    Caption = 'Search bar hotkey (for example Alt+Shift+Space)'
  end
  object lblNote: TLabel
    Left = 12
    Top = 470
    Width = 400
    Height = 15
    Caption = 'Saving restarts sgcFSearch in the background to apply the changes.'
  end
  object lbRoots: TListBox
    Left = 12
    Top = 32
    Width = 400
    Height = 100
    ItemHeight = 15
    TabOrder = 0
  end
  object btnRootAdd: TButton
    Left = 420
    Top = 32
    Width = 88
    Height = 26
    Caption = 'Add...'
    TabOrder = 1
    OnClick = btnRootAddClick
  end
  object btnRootRemove: TButton
    Left = 420
    Top = 64
    Width = 88
    Height = 26
    Caption = 'Remove'
    TabOrder = 2
    OnClick = btnRootRemoveClick
  end
  object lbSkip: TListBox
    Left = 12
    Top = 166
    Width = 400
    Height = 100
    ItemHeight = 15
    TabOrder = 3
  end
  object btnSkipAdd: TButton
    Left = 420
    Top = 166
    Width = 88
    Height = 26
    Caption = 'Add...'
    TabOrder = 4
    OnClick = btnSkipAddClick
  end
  object btnSkipRemove: TButton
    Left = 420
    Top = 198
    Width = 88
    Height = 26
    Caption = 'Remove'
    TabOrder = 5
    OnClick = btnSkipRemoveClick
  end
  object clbDrives: TCheckListBox
    Left = 12
    Top = 300
    Width = 400
    Height = 100
    ItemHeight = 17
    TabOrder = 6
  end
  object edHotkey: TEdit
    Left = 12
    Top = 434
    Width = 400
    Height = 23
    TabOrder = 7
  end
  object btnOK: TButton
    Left = 332
    Top = 508
    Width = 88
    Height = 28
    Caption = 'OK'
    Default = True
    TabOrder = 8
    OnClick = btnOKClick
  end
  object btnCancel: TButton
    Left = 420
    Top = 508
    Width = 88
    Height = 28
    Cancel = True
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 9
  end
end
