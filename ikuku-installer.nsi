; ikuku-installer.nsi — NSIS installer for Frappe apps on Windows
; Build: makensis /DVARIANT=lite|full ikuku-installer.nsi

!include "MUI2.nsh"

!ifndef VARIANT
    !define VARIANT "lite"
!endif

Name "ikuku — Frappe on Windows"
OutFile "ikuku-${VARIANT}.exe"
InstallDir "$PROGRAMFILES\ikuku"
RequestExecutionLevel admin

!insertmacro MUI_PAGE_WELCOME
Page custom AppsPage AppsPageLeave
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "English"

Var WikiCheck
Var LmsCheck
Var ErpNextCheck
Var CrmCheck
Var CustomApp
Var SelectedApps

Function AppsPage
    nsDialogs::Create 1018
    Pop $0

    ${NSD_CreateLabel} 0 0 100% 20u "Select Frappe apps to install (all share one port):"

    ${NSD_CreateCheckbox} 20u 30u 200u 12u "Wiki — documentation & knowledge base"
    Pop $WikiCheck
    ${NSD_Check} $WikiCheck

    ${NSD_CreateCheckbox} 20u 50u 200u 12u "LMS — learning management system"
    Pop $LmsCheck

    ${NSD_CreateCheckbox} 20u 70u 200u 12u "ERPNext — enterprise resource planning"
    Pop $ErpNextCheck

    ${NSD_CreateCheckbox} 20u 90u 200u 12u "CRM — customer relationship management"
    Pop $CrmCheck

    ${NSD_CreateLabel} 0 115u 100% 12u "Custom Frappe app (GitHub URL or name):"
    ${NSD_CreateText} 20u 130u 350u 12u ""
    Pop $CustomApp

    ${NSD_CreateLabel} 0 155u 100% 12u "All apps accessible at http://localhost:8000"

    nsDialogs::Show
FunctionEnd

Function AppsPageLeave
    StrCpy $SelectedApps ""
    ${NSD_GetState} $WikiCheck $0
    ${If} $0 == ${BST_CHECKED}
        StrCpy $SelectedApps "wiki"
    ${EndIf}
    ${NSD_GetState} $LmsCheck $0
    ${If} $0 == ${BST_CHECKED}
        ${If} $SelectedApps != ""
            StrCpy $SelectedApps "$SelectedApps,lms"
        ${Else}
            StrCpy $SelectedApps "lms"
        ${EndIf}
    ${EndIf}
    ${NSD_GetState} $ErpNextCheck $0
    ${If} $0 == ${BST_CHECKED}
        ${If} $SelectedApps != ""
            StrCpy $SelectedApps "$SelectedApps,erpnext"
        ${Else}
            StrCpy $SelectedApps "erpnext"
        ${EndIf}
    ${EndIf}
    ${NSD_GetState} $CrmCheck $0
    ${If} $0 == ${BST_CHECKED}
        ${If} $SelectedApps != ""
            StrCpy $SelectedApps "$SelectedApps,crm"
        ${Else}
            StrCpy $SelectedApps "crm"
        ${EndIf}
    ${EndIf}
    ; Custom app (URL or name)
    ${NSD_GetText} $CustomApp $0
    ${If} $0 != ""
        ${If} $SelectedApps != ""
            StrCpy $SelectedApps "$SelectedApps,$0"
        ${Else}
            StrCpy $SelectedApps "$0"
        ${EndIf}
    ${EndIf}
    ${If} $SelectedApps == ""
        MessageBox MB_OK "Please select at least one app."
        Abort
    ${EndIf}
FunctionEnd

Section "Install"
    SetOutPath $INSTDIR

    ; Core scripts
    File "install.ps1"
    File "ikuku-service.ps1"
    File "start.ps1"
    File "stop.ps1"
    File "uninstall.ps1"
    File "update-portproxy.ps1"
    File "docker-compose.yml"
    File "init.sh"

    ; Shared scripts
    SetOutPath "$INSTDIR\shared"
    File "shared\wsl-setup.ps1"
    File "shared\service-setup.ps1"
    SetOutPath $INSTDIR

    ; Bundle: if full variant, copy bundle from launch dir (shipped alongside exe)
    !if "${VARIANT}" == "full"
        ; Bundle is expected next to the exe, copy to install dir
        nsExec::ExecToLog 'xcopy "$EXEDIR\bundle" "$INSTDIR\bundle\" /E /I /Y'
    !endif

    ; Run installer with selected apps
    nsExec::ExecToLog 'powershell -ExecutionPolicy Bypass -File "$INSTDIR\install.ps1" -Apps "$SelectedApps"'

    ; Start Menu
    CreateDirectory "$SMPROGRAMS\ikuku"
    CreateShortcut "$SMPROGRAMS\ikuku\Open.lnk" "http://localhost:8000"
    CreateShortcut "$SMPROGRAMS\ikuku\Start.lnk" "powershell.exe" '-ExecutionPolicy Bypass -File "$INSTDIR\start.ps1"'
    CreateShortcut "$SMPROGRAMS\ikuku\Stop.lnk" "powershell.exe" '-ExecutionPolicy Bypass -File "$INSTDIR\stop.ps1"'

    ; Uninstaller + Add/Remove Programs
    WriteUninstaller "$INSTDIR\uninstall.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ikuku" "DisplayName" "ikuku — Frappe on Windows"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ikuku" "UninstallString" "$INSTDIR\uninstall.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ikuku" "Publisher" "ikuku"
SectionEnd

Section "Uninstall"
    nsExec::ExecToLog 'powershell -ExecutionPolicy Bypass -File "$INSTDIR\uninstall.ps1"'
    RMDir /r "$SMPROGRAMS\ikuku"
    RMDir /r "$INSTDIR"
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ikuku"
SectionEnd
