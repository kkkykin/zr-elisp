# SPDX-License-Identifier: GPL-3.0-or-later
# Speak text using an installed Windows System.Speech voice.
[CmdletBinding()]
param(
    [string]$Text,
    [string]$Voice
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$speech = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
    if ($Voice) {
        $speech.SelectVoice($Voice)
    }
    $speech.Speak($Text)
} finally {
    $speech.Dispose()
}
