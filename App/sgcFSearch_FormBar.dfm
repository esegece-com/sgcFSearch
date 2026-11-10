object sgcFSearchBarForm: TsgcFSearchBarForm
  Left = 0
  Top = 0
  BorderIcons = []
  BorderStyle = bsNone
  Caption = 'sgcFSearch'
  ClientHeight = 120
  ClientWidth = 760
  Color = clWindow
  DoubleBuffered = True
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  PixelsPerInch = 96
  Position = poDesigned
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnPaint = FormPaint
  TextHeight = 15
  object pbChips: TPaintBox
    Left = 10
    Top = 64
    Width = 740
    Height = 28
    OnMouseUp = pbChipsMouseUp
    OnPaint = pbChipsPaint
  end
  object pbStatus: TPaintBox
    Left = 16
    Top = 96
    Width = 728
    Height = 20
    OnMouseLeave = pbStatusMouseLeave
    OnMouseMove = pbStatusMouseMove
    OnMouseUp = pbStatusMouseUp
    OnPaint = pbStatusPaint
  end
  object pbPin: TPaintBox
    Left = 713
    Top = 19
    Width = 28
    Height = 28
    Cursor = crHandPoint
    Hint = 'Keep open'
    ParentShowHint = False
    ShowHint = True
    OnMouseEnter = pbPinMouseEnter
    OnMouseLeave = pbPinMouseLeave
    OnMouseUp = pbPinMouseUp
    OnPaint = pbPinPaint
  end
  object edtSearch: TEdit
    Left = 52
    Top = 20
    Width = 686
    Height = 27
    BorderStyle = bsNone
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -20
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    TabOrder = 0
    TextHint = 'Search files and folders'
    OnChange = edtSearchChange
    OnKeyDown = edtSearchKeyDown
    OnKeyPress = edtSearchKeyPress
  end
  object lstResults: TListBox
    Left = 10
    Top = 100
    Width = 740
    Height = 46
    Style = lbVirtualOwnerDraw
    BorderStyle = bsNone
    ItemHeight = 46
    TabOrder = 1
    TabStop = False
    Visible = False
    OnData = lstResultsData
    OnDblClick = lstResultsDblClick
    OnDrawItem = lstResultsDrawItem
    OnKeyDown = edtSearchKeyDown
    OnMouseUp = lstResultsMouseUp
  end
  object tmrRefresh: TTimer
    Enabled = False
    Interval = 250
    OnTimer = tmrRefreshTimer
    Left = 680
    Top = 8
  end
  object tmrStatus: TTimer
    Enabled = False
    Interval = 1000
    OnTimer = tmrStatusTimer
    Left = 720
    Top = 8
  end
end
