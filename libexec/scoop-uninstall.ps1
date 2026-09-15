# Usage: scoop uninstall <app> [options]
# Summary: Uninstall an app
# Help: e.g. scoop uninstall git
#
# To uninstall a specific version of an app (other installed versions are kept):
#      scoop uninstall 7zip@26.02
#
# Options:
#   -g, --global   Uninstall a globally installed app
#   -p, --purge    Remove all persistent data

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1" # 'Get-Manifest' 'Select-CurrentVersion' (indirectly)
. "$PSScriptRoot\..\lib\system.ps1"
. "$PSScriptRoot\..\lib\install.ps1"
. "$PSScriptRoot\..\lib\download.ps1" # url_filename
. "$PSScriptRoot\..\lib\shortcuts.ps1"
. "$PSScriptRoot\..\lib\psmodules.ps1"
. "$PSScriptRoot\..\lib\versions.ps1" # 'Select-CurrentVersion'

# options
$opt, $apps, $err = getopt $args 'gp' 'global', 'purge'

if ($err) {
    error "scoop uninstall: $err"
    exit 1
}

$global = $opt.g -or $opt.global
$purge = $opt.p -or $opt.purge

if (!$apps) {
    error '<app> missing'
    my_usage
    exit 1
}

if ($global -and !(is_admin)) {
    error 'You need admin rights to uninstall global apps.'
    exit 1
}

if ($apps -eq 'scoop') {
    & "$PSScriptRoot\..\bin\uninstall.ps1" $global $purge
    exit
}

$queries = @($apps)
$apps = Confirm-InstallationStatus $queries -Global:$global
if (!$apps) { exit 0 }

$installedGlobal = @{}
foreach ($item in $apps) {
    $installedGlobal[$item[0]] = $item[1]
}

:app_loop foreach ($query in ($queries | Select-Object -Unique)) {
    $app, $null, $specifiedVersion = parse_app $query
    if (-not $installedGlobal.ContainsKey($app)) { continue }
    $global = $installedGlobal[$app]

    $appDir = appdir $app $global
    $currentVersion = Select-CurrentVersion -AppName $app -Global:$global
    $installedVersions = @(Get-InstalledVersion -AppName $app -Global:$global)

    # Uninstall only the specified version when other versions remain
    if ($specifiedVersion) {
        if ($specifiedVersion -notin $installedVersions) {
            error "'$app' ($specifiedVersion) isn't installed."
            continue
        }

        $remainingVersions = @($installedVersions | Where-Object { $_ -ne $specifiedVersion })
        if ($remainingVersions.Count -gt 0) {
            Write-Host "Uninstalling '$app' ($specifiedVersion)."

            $dir = versiondir $app $specifiedVersion $global
            $persist_dir = persistdir $app $global
            $manifest = installed_manifest $app $specifiedVersion $global
            $install = install_info $app $specifiedVersion $global
            $architecture = $install.architecture
            $bucket = $install.bucket
            $isCurrent = $specifiedVersion -eq $currentVersion

            if ($isCurrent) {
                Invoke-HookScript -HookType 'pre_uninstall' -Manifest $manifest -Arch $architecture

                #region Workaround for #2952
                if (test_running_process $app $global) {
                    continue
                }
                #endregion Workaround for #2952

                try {
                    Test-Path $dir -ErrorAction Stop | Out-Null
                } catch [UnauthorizedAccessException] {
                    error "Access denied: $dir. You might need to restart."
                    continue
                }

                Invoke-Installer -Path $dir -Manifest $manifest -ProcessorArchitecture $architecture -Global:$global -Uninstall
                rm_shims $app $manifest $global $architecture
                rm_startmenu_shortcuts $manifest $global $architecture
                if (get_config UNINSTALL_SHORTCUT) {
                    rm_uninstall_shortcuts $app $global
                }
                $refdir = unlink_current $dir
                uninstall_psmodule $manifest $refdir $global
                env_rm_path $manifest $refdir $global $architecture
                env_rm $manifest $global $architecture
            }

            try {
                unlink_persist_data $manifest $dir
                Remove-Item $dir -Recurse -Force -ErrorAction Stop
            } catch {
                if (Test-Path $dir) {
                    error "Couldn't remove '$(friendly_path $dir)'; it may be in use."
                    continue
                }
            }

            if ($isCurrent) {
                Invoke-HookScript -HookType 'post_uninstall' -Manifest $manifest -Arch $architecture

                # Keep the app usable by switching current to the latest remaining version
                $nextVersion = $remainingVersions[-1]
                Write-Host "Resetting $app ($nextVersion)."

                $manifest = installed_manifest $app $nextVersion $global
                $install = install_info $app $nextVersion $global
                $architecture = $install.architecture
                $bucket = $install.bucket
                $dir = Convert-Path (versiondir $app $nextVersion $global)
                $original_dir = $dir
                $persist_dir = persistdir $app $global

                $dir = link_current $dir
                create_shims $manifest $dir $global $architecture
                create_startmenu_shortcuts $manifest $dir $global $architecture
                if (get_config UNINSTALL_SHORTCUT) {
                    create_uninstall_shortcuts $app $manifest $bucket $nextVersion $dir $global $architecture
                }
                install_psmodule $manifest $dir $global
                env_add_path $manifest $dir $global $architecture
                env_set $manifest $global $architecture
                unlink_persist_data $manifest $original_dir
                persist_data $manifest $original_dir $persist_dir
                persist_permission $manifest $global
            }

            if ($purge) {
                warn "Persisted data is kept because other versions of '$app' are still installed."
            }

            success "'$app' ($specifiedVersion) was uninstalled."
            continue
        }
    }

    $version = $currentVersion
    if ($version) {
        Write-Host "Uninstalling '$app' ($version)."

        $dir = versiondir $app $version $global
        $persist_dir = persistdir $app $global

        $manifest = installed_manifest $app $version $global
        $install = install_info $app $version $global
        $architecture = $install.architecture
        $bucket = $install.bucket

        Invoke-HookScript -HookType 'pre_uninstall' -Manifest $manifest -Arch $architecture

        #region Workaround for #2952
        if (test_running_process $app $global) {
            continue
        }
        #endregion Workaround for #2952

        try {
            Test-Path $dir -ErrorAction Stop | Out-Null
        } catch [UnauthorizedAccessException] {
            error "Access denied: $dir. You might need to restart."
            continue
        }

        Invoke-Installer -Path $dir -Manifest $manifest -ProcessorArchitecture $architecture -Global:$global -Uninstall
        rm_shims $app $manifest $global $architecture
        rm_startmenu_shortcuts $manifest $global $architecture
        if (get_config UNINSTALL_SHORTCUT) {
            rm_uninstall_shortcuts $app $global
        }
        # If a junction was used during install, that will have been used
        # as the reference directory. Otherwise it will just be the version
        # directory.
        $refdir = unlink_current $dir

        uninstall_psmodule $manifest $refdir $global

        env_rm_path $manifest $refdir $global $architecture
        env_rm $manifest $global $architecture

        try {
            # unlink all potential old link before doing recursive Remove-Item
            unlink_persist_data $manifest $dir
            Remove-Item $dir -Recurse -Force -ErrorAction Stop
        } catch {
            if (Test-Path $dir) {
                error "Couldn't remove '$(friendly_path $dir)'; it may be in use."
                continue
            }
        }

        Invoke-HookScript -HookType 'post_uninstall' -Manifest $manifest -Arch $architecture
    }
    # remove older versions
    $oldVersions = @(Get-ChildItem $appDir -Name -Exclude 'current')
    foreach ($version in $oldVersions) {
        Write-Host "Removing older version ($version)."
        $dir = versiondir $app $version $global
        try {
            # unlink all potential old link before doing recursive Remove-Item
            unlink_persist_data $manifest $dir
            Remove-Item $dir -Recurse -Force -ErrorAction Stop
        } catch {
            error "Couldn't remove '$(friendly_path $dir)'; it may be in use."
            continue app_loop
        }
    }
    if (Test-Path ($currentDir = Join-Path $appDir 'current')) {
        attrib $currentDir -R /L
        Remove-Item $currentDir -ErrorAction Stop -Force
    }
    if (!(Get-ChildItem $appDir)) {
        try {
            # if last install failed, the directory seems to be locked and this
            # will throw an error about the directory not existing
            Remove-Item $appdir -Recurse -Force -ErrorAction Stop
        } catch {
            if ((Test-Path $appdir)) { throw } # only throw if the dir still exists
        }
    }

    # purge persistant data
    if ($purge) {
        Write-Host 'Removing persisted data.'
        $persist_dir = persistdir $app $global

        if (Test-Path $persist_dir) {
            try {
                Remove-Item $persist_dir -Recurse -Force -ErrorAction Stop
            } catch {
                error "Couldn't remove '$(friendly_path $persist_dir)'; it may be in use."
                continue
            }
        }
    }

    success "'$app' was uninstalled."
}

exit 0
