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

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("1809", "ltsc2022", "ltsc2025")]
    [string]$OSVersion
)

$ErrorActionPreference = "Stop"

if ($OSVersion -ne "ltsc2025") {
    return
}

function Get-ServiceConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $configuration = & sc.exe qc $Name 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Required service '$Name' is unavailable: $($configuration -join [Environment]::NewLine)"
    }

    return $configuration
}

Get-ServiceConfiguration -Name "MRxSmb20" | Out-Null
$workstationConfiguration = Get-ServiceConfiguration -Name "LanmanWorkstation"
if (-not ($workstationConfiguration -match "START_TYPE\s+:\s+2\s+AUTO_START")) {
    throw "LanmanWorkstation is not configured for automatic startup."
}
