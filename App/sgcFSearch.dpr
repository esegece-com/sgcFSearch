{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

program sgcFSearch;

{$I sgcVer.inc}
// sgcFSearch.exe: tray daemon (index, pipe server, global hotkey) and search
// bar. Arguments: --background (do not show the bar), --restarted (started
// by a previous instance that is closing).

uses
  Vcl.Forms,
  // sgc
  sgcFSearch_Main in 'sgcFSearch_Main.pas' {sgcFSearchMainForm} ,
  sgcFSearch_FormBar in 'sgcFSearch_FormBar.pas',
  sgcFSearch_FormFolders
    in 'sgcFSearch_FormFolders.pas' {sgcFSearchFoldersForm} ,
  sgcFSearch_Hotkey in 'sgcFSearch_Hotkey.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := False;
  Application.ShowMainForm := False;
  Application.Title := 'sgcFSearch';
  Application.CreateForm(TsgcFSearchMainForm, sgcFSearchMainForm);
  if sgcFSearchMainForm.Startup then
    Application.Run;

end.
