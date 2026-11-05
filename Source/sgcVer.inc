{ ***************************************************************************
  sgcFSearch: compiler include, every unit includes it right after "unit".
  *************************************************************************** }

{$IFNDEF MSWINDOWS}
  {$MESSAGE FATAL 'sgcFSearch supports Windows only'}
{$ENDIF}
{$IFNDEF WIN64}
  {$MESSAGE FATAL 'sgcFSearch supports Win64 only'}
{$ENDIF}

{$DEFINE SGC_FSEARCH}

{$SCOPEDENUMS OFF}
{$POINTERMATH ON}
