# Delphi Community profile repair

The installed Delphi 13 Community Edition licence was still registered and the
License Manager reported an expiry of 2027-10-24. Its original activation file
was present. This was not evidence of an expired trial or a missing serial.

Both an ordinary IDE launch and AutoBuild nevertheless opened registration.
Reimporting the existing activation file did not resolve the launch. The normal
License Manager Update operation found no licence updates.

An isolated profile, using the documented `-r` and `-pDelphi` options, opened the
same installed executable as Delphi 13 Community Edition without registration.
Comparison with that working profile and the installation's machine settings
identified three inconsistencies in the usual current-user profile:

- root `Edition` was absent; the installed value is `Starter`;
- `Personalities/Delphi.Win32` was absent; the installed value is `Delphi 13`;
- `Globals/Personalities` was 3; the installed and working-profile value is 1.

With the IDE closed, the complete original current-user key was exported to a
local backup outside the repository. These three values were restored from the
installed machine settings. The ordinary profile then opened the Community IDE
without registration and completed its initial settings screen.

Opening the actual Win64 project and AutoBuild still stalled before a build log.
The same project opened normally in the isolated profile. The usual profile's
registered package lists were incomplete: in particular, the installed
`delphiwin64370.bpl` module was missing. After a second local registry backup,
installed entries were restored from the machine's `Known IDE Packages`,
`Known IDE Packages x64` and `Known Packages` lists (30, 22 and 37 changed or
missing entries, respectively). Custom entries outside those installed lists
were retained. This partial repair still did not open the project normally.
Three diagnostic AutoBuild attempts were explicitly stopped before any completed
log; none is passing compiler evidence.

At the user's request to remove interfering settings, the ordinary current-user
registry profile and its roaming profile directory were preserved under
`37.0-before-clean-20261114`. The verified isolated Community profile was copied
into the ordinary `BDS/37.0` locations. Source and backup directories were checked
as exact directories under the intended Embarcadero profile roots before moving
anything. No projects in Documents or the workspace were moved or removed.

Original profile files and activation data were not deleted. Activation-file/
cache copies were also saved locally before the import attempt. No serial or
account secret is recorded in this audit.

The cause of the missing settings has not been established. The repository's
build helper now explicitly selects the Delphi personality with `-pDelphi` and
continues using the documented licensed IDE AutoBuild interface. No licence
checks, edition binaries or compiler restrictions were modified.

Fresh Win64 AutoBuild completed successfully after the complete profile repair:

- project: `tools/ui/tests/CompressionRecovery.local.dproj`;
- log: `CompressionRecovery.local-Win64-53edf9ab2b23.err`;
- executable: 26,183,168 bytes;
- SHA-256: `a20b474371b5d587bd60e3eaf182542a0fa45f170a3356c563a18d733e5dc82a`;
- the project remained unchanged and the executable architecture was checked.

This compiles the current application code and expanded compression fixture. It
is not a final distribution build or a passing application scenario by itself.
Do not restore the incomplete old package lists as a startup optimisation.
