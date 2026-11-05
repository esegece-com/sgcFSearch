{ ***************************************************************************
  sgcFSearch component

  written by eSeGeCe
  copyright © 2026
  Email : info@esegece.com
  Web : https://www.esegece.com
  *************************************************************************** }

unit sgcFSearch_Hotkey;

{$I sgcVer.inc}
// Global hotkey text parser: 'Mod+Mod+Key', case insensitive, spaces ignored.
// Modifiers: Ctrl (Control), Alt, Shift, Win (Windows). At least one is
// required. Key: a letter, a digit, F1..F24 or Space.

interface

uses
  Winapi.Windows, System.SysUtils;

const
  SGCFS_HOTKEY_FALLBACK_1 = 'Win+Shift+F';
  SGCFS_HOTKEY_FALLBACK_2 = 'Ctrl+Alt+F';
  SGCFS_MOD_NOREPEAT = $4000;

  // True when Text is a valid hotkey; Modifiers = MOD_* mask (no
  // MOD_NOREPEAT), Key = virtual key code
function sgcFSearchParseHotkey(const Text: string;
  out Modifiers, Key: Cardinal): Boolean;
// canonical text, order Win, Ctrl, Alt, Shift, Key ('Alt+Shift+Space')
function sgcFSearchHotkeyText(Modifiers, Key: Cardinal): string;

implementation

function sgcFSearchParseHotkey(const Text: string;
  out Modifiers, Key: Cardinal): Boolean;
var
  vParts: TArray<string>;
  i, vNum: Integer;
  vPart: string;
begin
  Result := False;
  Modifiers := 0;
  Key := 0;
  vParts := StringReplace(Text, ' ', '', [rfReplaceAll]).Split(['+']);
  if Length(vParts) < 2 then
    Exit;
  for i := 0 to High(vParts) - 1 do
  begin
    vPart := UpperCase(vParts[i]);
    if (vPart = 'CTRL') or (vPart = 'CONTROL') then
      Modifiers := Modifiers or MOD_CONTROL
    else if vPart = 'ALT' then
      Modifiers := Modifiers or MOD_ALT
    else if vPart = 'SHIFT' then
      Modifiers := Modifiers or MOD_SHIFT
    else if (vPart = 'WIN') or (vPart = 'WINDOWS') then
      Modifiers := Modifiers or MOD_WIN
    else
      Exit;
  end;
  vPart := UpperCase(vParts[High(vParts)]);
  if vPart = 'SPACE' then
    Key := VK_SPACE
  else if (Length(vPart) = 1) and CharInSet(vPart[1], ['A' .. 'Z', '0' .. '9'])
  then
    Key := Ord(vPart[1])
  else if (Length(vPart) >= 2) and (Length(vPart) <= 3) and (vPart[1] = 'F') and
    TryStrToInt(Copy(vPart, 2, 2), vNum) and (vNum >= 1) and (vNum <= 24) and
    (Copy(vPart, 2, 1) <> '0') then
    Key := VK_F1 + Cardinal(vNum) - 1
  else
    Exit;
  Result := Modifiers <> 0;
end;

function sgcFSearchHotkeyText(Modifiers, Key: Cardinal): string;
begin
  Result := '';
  if Modifiers and MOD_WIN <> 0 then
    Result := Result + 'Win+';
  if Modifiers and MOD_CONTROL <> 0 then
    Result := Result + 'Ctrl+';
  if Modifiers and MOD_ALT <> 0 then
    Result := Result + 'Alt+';
  if Modifiers and MOD_SHIFT <> 0 then
    Result := Result + 'Shift+';
  if Key = VK_SPACE then
    Result := Result + 'Space'
  else if (Key >= VK_F1) and (Key <= VK_F24) then
    Result := Result + 'F' + IntToStr(Key - VK_F1 + 1)
  else if Key <> 0 then
    Result := Result + Char(Key);
end;

end.
