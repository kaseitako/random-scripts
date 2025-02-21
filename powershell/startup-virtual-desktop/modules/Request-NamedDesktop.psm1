# https://github.com/MScholtes/PSVirtualDesktop の Example.ps1 から引用
function Request-NamedDesktop {
	<#
		.SYNOPSIS
			Retrieves or creates (if non-existing) the virtual desktop with the given name.
		.INPUTS
			The desktop name can be piped into this function.
		.OUTPUTS
			A virtual desktop with the given name.
		.EXAMPLE
			Request-NamedDesktop "My Secret Desktop"
		.EXAMPLE
			"My Secret Desktop" | Request-NamedDesktop | Switch-Desktop
		.NOTES
			The function assumes that the PSVirtualDesktop module [0] is installed.
			[0]: https://github.com/MScholtes/PSVirtualDesktop
	#>
	param(
		<#
			The name of the virtual desktop to retrieve or create (if non-existing)
		#>
		[Parameter(Mandatory=$true, ValueFromPipeline=$true)]
		[ValidateNotNullOrEmpty()]
		[string]$name
	)

	$desktop = Get-DesktopList | Where-Object Name -eq $name | Select-Object -First 1

	# The if condition below is susceptible to a TOCTOU bug (https://en.wikipedia.org/wiki/Time-of-check_to_time-of-use).
	# But this is probably okay since virtual desktops aren't something that is created every second.
	if ($desktop) {
		Get-Desktop -Index $desktop.Number
	} else {
		$desktop = New-Desktop
		$desktop | Set-DesktopName -Name $name
		$desktop
	}
}
