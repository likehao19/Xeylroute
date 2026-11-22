!macro NSIS_HOOK_PREUNINSTALL
  ; WinDivert can retain its driver image until reboot after the final handle closes.
  ClearErrors
  Delete /REBOOTOK "$INSTDIR\WinDivert64.sys"
  IfErrors 0 +2
    Abort "Could not schedule removal of the WinDivert driver file."
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  IfRebootFlag 0 +2
    RMDir /REBOOTOK "$INSTDIR"
!macroend
