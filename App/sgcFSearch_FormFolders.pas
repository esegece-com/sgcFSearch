{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_FormFolders;

{$I sgcVer.inc}
// "Folders..." dialog: content roots, skip folders, drives and hotkey. Loads
// its own copy of config.json and saves it on OK (only when something
// changed); the caller then restarts the app so the engine reloads it.

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.CheckLst, Vcl.Dialogs,
  System.UITypes,
  // sgc
  sgcFSearch_Config, sgcFSearch_Crawler, sgcFSearch_Hotkey;

type
  TsgcFSearchFoldersForm = class(TForm)
    lblRoots: TLabel;
    lbRoots: TListBox;
    btnRootAdd: TButton;
    btnRootRemove: TButton;
    lblSkip: TLabel;
    lbSkip: TListBox;
    btnSkipAdd: TButton;
    btnSkipRemove: TButton;
    lblDrives: TLabel;
    clbDrives: TCheckListBox;
    lblHotkey: TLabel;
    edHotkey: TEdit;
    lblNote: TLabel;
    btnOK: TButton;
    btnCancel: TButton;
    procedure btnRootAddClick(Sender: TObject);
    procedure btnRootRemoveClick(Sender: TObject);
    procedure btnSkipAddClick(Sender: TObject);
    procedure btnSkipRemoveClick(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FConfig: TsgcFSearchConfig;
    FSignature: string;
    function DoSignature: string;
    procedure DoLoad;
    procedure DoAddFolder(List: TListBox);
    procedure DoRemove(List: TListBox);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    destructor Destroy; override;
    /// Shows the dialog; True when the settings were changed and saved.
    class function Execute: Boolean;
  end;

implementation

{$R *.dfm}

function DoListToArray(Items: TStrings): TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, Items.Count);
  for i := 0 to Items.Count - 1 do
    Result[i] := Items[i];
end;

function DoSamePath(const A, B: string): Boolean;
begin
  Result := SameText(IncludeTrailingPathDelimiter(A),
    IncludeTrailingPathDelimiter(B));
end;

class function TsgcFSearchFoldersForm.Execute: Boolean;
var
  vForm: TsgcFSearchFoldersForm;
begin
  vForm := TsgcFSearchFoldersForm.Create(nil);
  try
    vForm.FConfig := TsgcFSearchConfig.Create;
    vForm.FConfig.LoadFromFile(sgcFSearchConfigFileName);
    vForm.FSignature := vForm.DoSignature;
    vForm.DoLoad;
    Result := vForm.ShowModal = mrOk;
  finally
    vForm.Free;
  end;
end;

destructor TsgcFSearchFoldersForm.Destroy;
begin
  FreeAndNil(FConfig);
  inherited Destroy;
end;

procedure TsgcFSearchFoldersForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  // the main form is hidden: give the dialog its own taskbar button
  Params.ExStyle := Params.ExStyle or WS_EX_APPWINDOW;
end;

procedure TsgcFSearchFoldersForm.FormShow(Sender: TObject);
begin
  SetForegroundWindow(Handle);
end;

function TsgcFSearchFoldersForm.DoSignature: string;
begin
  Result := string.Join(#1, FConfig.Roots) + #2 + string.Join(#1, FConfig.Skip)
    + #2 + string.Join(#1, FConfig.Drives) + #2 + FConfig.Hotkey;
end;

procedure TsgcFSearchFoldersForm.DoLoad;
var
  vPath: string;
  i, vIndex: Integer;
begin
  lbRoots.Items.Clear;
  for vPath in FConfig.Roots do
    lbRoots.Items.Add(vPath);
  lbSkip.Items.Clear;
  for vPath in FConfig.Skip do
    lbSkip.Items.Add(vPath);
  clbDrives.Items.Clear;
  for vPath in TsgcFSearchCrawler.EnumFixedDrives do
    clbDrives.Items.Add(vPath);
  for vPath in FConfig.Drives do
  begin
    vIndex := -1;
    for i := 0 to clbDrives.Items.Count - 1 do
      if DoSamePath(clbDrives.Items[i], vPath) then
      begin
        vIndex := i;
        Break;
      end;
    if vIndex < 0 then
      vIndex := clbDrives.Items.Add(vPath);
    clbDrives.Checked[vIndex] := True;
  end;
  edHotkey.Text := FConfig.Hotkey;
end;

procedure TsgcFSearchFoldersForm.DoAddFolder(List: TListBox);
var
  vDialog: TFileOpenDialog;
  vPath: string;
begin
  vDialog := TFileOpenDialog.Create(Self);
  try
    vDialog.Title := 'Select a folder';
    vDialog.Options := [fdoPickFolders, fdoPathMustExist, fdoForceFileSystem];
    if not vDialog.Execute(Handle) then
      Exit;
    vPath := vDialog.FileName;
    if (Length(vPath) > 3) then
      vPath := ExcludeTrailingPathDelimiter(vPath);
    if vPath = '' then
      Exit;
    if List.Items.IndexOf(vPath) < 0 then
      List.Items.Add(vPath);
    List.ItemIndex := List.Items.IndexOf(vPath);
  finally
    vDialog.Free;
  end;
end;

procedure TsgcFSearchFoldersForm.DoRemove(List: TListBox);
var
  vIndex: Integer;
begin
  vIndex := List.ItemIndex;
  if vIndex < 0 then
    Exit;
  List.Items.Delete(vIndex);
  if vIndex >= List.Items.Count then
    vIndex := List.Items.Count - 1;
  List.ItemIndex := vIndex;
end;

procedure TsgcFSearchFoldersForm.btnRootAddClick(Sender: TObject);
begin
  DoAddFolder(lbRoots);
end;

procedure TsgcFSearchFoldersForm.btnRootRemoveClick(Sender: TObject);
begin
  DoRemove(lbRoots);
end;

procedure TsgcFSearchFoldersForm.btnSkipAddClick(Sender: TObject);
begin
  DoAddFolder(lbSkip);
end;

procedure TsgcFSearchFoldersForm.btnSkipRemoveClick(Sender: TObject);
begin
  DoRemove(lbSkip);
end;

procedure TsgcFSearchFoldersForm.btnOKClick(Sender: TObject);
var
  vModifiers, vKey: Cardinal;
  vDrives: TArray<string>;
  i: Integer;
begin
  if not sgcFSearchParseHotkey(edHotkey.Text, vModifiers, vKey) then
  begin
    MessageDlg('Invalid hotkey. Use one or more modifiers (Ctrl, Alt, ' +
      'Shift, Win) and one key (A to Z, 0 to 9, F1 to F24, Space), for ' +
      'example Alt+Shift+Space.', mtError, [mbOK], 0);
    edHotkey.SetFocus;
    Exit;
  end;
  vDrives := nil;
  for i := 0 to clbDrives.Items.Count - 1 do
    if clbDrives.Checked[i] then
      vDrives := vDrives + [clbDrives.Items[i]];
  FConfig.Roots := DoListToArray(lbRoots.Items);
  FConfig.Skip := DoListToArray(lbSkip.Items);
  FConfig.Drives := vDrives;
  FConfig.Hotkey := sgcFSearchHotkeyText(vModifiers, vKey);
  if DoSignature = FSignature then
  begin
    ModalResult := mrCancel;
    Exit;
  end;
  try
    FConfig.SaveToFile(sgcFSearchConfigFileName);
  except
    on E: Exception do
    begin
      MessageDlg('The settings could not be saved: ' + E.Message, mtError,
        [mbOK], 0);
      Exit;
    end;
  end;
  ModalResult := mrOk;
end;

end.
