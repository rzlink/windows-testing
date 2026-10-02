@echo off
rem Copyright 2026 The Kubernetes Authors.
rem
rem Licensed under the Apache License, Version 2.0 (the "License");
rem you may not use this file except in compliance with the License.
rem You may obtain a copy of the License at
rem
rem     http://www.apache.org/licenses/LICENSE-2.0
rem
rem Unless required by applicable law or agreed to in writing, software
rem distributed under the License is distributed on an "AS IS" BASIS,
rem WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
rem See the License for the specific language governing permissions and
rem limitations under the License.

rem RemoteFS is already present in older Nano Server releases. Installing the
rem capability is necessary only for LTSC 2025.
set "supportedOS="
if /I "%~1"=="1809" set "supportedOS=true"
if /I "%~1"=="ltsc2022" set "supportedOS=true"
if /I "%~1"=="ltsc2025" set "supportedOS=true"
if not defined supportedOS exit /b 87

if /I "%~2"=="install" goto install
if /I "%~2"=="configure" goto configure
exit /b 87

:install
if /I not "%~1"=="ltsc2025" exit /b 0

rem DISM returns 3010 when installation succeeds but requires a restart. A
rem container image build cannot restart Windows, so the following Docker
rem layer provides the servicing boundary.
dism.exe /online /add-capability /capabilityname:Microsoft.NanoServer.RemoteFS.Client /norestart /quiet
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" if not "%exitCode%"=="3010" exit /b %exitCode%
exit /b 0

:configure
if /I not "%~1"=="ltsc2025" exit /b 0

rem MRxSmb20 is installed by RemoteFS and is required by LanmanWorkstation.
sc.exe qc MRxSmb20 >nul
if errorlevel 1 exit /b %ERRORLEVEL%

sc.exe config LanmanWorkstation start= auto
exit /b %ERRORLEVEL%
