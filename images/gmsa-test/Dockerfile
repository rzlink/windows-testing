# escape=`

# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG BASE_IMAGE
ARG OS_VERSION

FROM ${BASE_IMAGE}

ARG OS_VERSION

USER ContainerAdministrator

COPY install-remotefs.cmd /install-remotefs.cmd

# Nano Server LTSC 2025 does not include the SMB redirector required by
# LanmanWorkstation. Keep installation and verification in separate layers
# because DISM returns 3010 and the servicing changes become visible only to a
# subsequent container layer.
RUN %SystemDrive%\install-remotefs.cmd %OS_VERSION% install
RUN %SystemDrive%\install-remotefs.cmd %OS_VERSION% configure && del %SystemDrive%\install-remotefs.cmd

COPY verify.ps1 /verify.ps1
RUN pwsh.exe -NoLogo -NoProfile -NonInteractive -File %SystemDrive%\verify.ps1 -OSVersion %OS_VERSION% && del %SystemDrive%\verify.ps1
