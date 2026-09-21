# Pictures of the pages at the smallest window size, for a person to look at:
# the layout test measures bounds, and cannot see a line of text cut off
# inside its label. Saved in the output folder, under shots\. Always passes.

$dir = Join-Path $TestOutput 'shots'
if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }

function Save-Shot {
    # the window draws itself, so it does not matter that it is off screen
    param([string]$Name)
    Wait-Pumped -Milliseconds 700
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save((Join-Path $dir ($Name + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Say ("saved shots\{0}.png" -f $Name)
}

if ($TestSerial) { Select-TestPhone }
$form.Size = $form.MinimumSize
Wait-Pumped -Milliseconds 800

$tabs.SelectedTab = $tabDevice;                                            Save-Shot 'min-device'
$tabs.SelectedTab = $tabTethering; $tabsTethering.SelectedTab = $tabShare; Save-Shot 'min-tethering'
$tabs.SelectedTab = $tabAdvanced; $tabsAdvanced.SelectedTab = $tabScrcpy;  Save-Shot 'min-mirroring'
$tabsAdvanced.SelectedTab = $tabMore;                                      Save-Shot 'min-more'
$tabsAdvanced.SelectedTab = $tabTools;                                     Save-Shot 'min-tools'
$tabsAdvanced.SelectedTab = $tabRoot;                                      Save-Shot 'min-root'
$tabs.SelectedTab = $tabCamera;                                            Save-Shot 'min-cam-mic'
$tabs.SelectedTab = $tabShellHost; $tabsShell.SelectedTab = $tabLogcat;    Save-Shot 'min-logcat'
$tabsShell.SelectedTab = $tabShell;                                        Save-Shot 'min-shell'
$tabs.SelectedTab = $tabAdvanced; $tabsAdvanced.SelectedTab = $tabAutomation; Save-Shot 'min-automation'
$tabsAdvanced.SelectedTab = $tabBackup;                                    Save-Shot 'min-backup'
