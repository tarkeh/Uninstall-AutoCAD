# Autodesk multi-version cleanup for Configuration Manager

## Policy

- Default **Audit** never changes installed software.
- **Execute** removes only a release with a later release installed in the *same family*.
- `-MinimumKeepYear 2025` means **preserve ALL 2025+ releases**, and also preserve the latest release in any family even if older. Use 2000 to keep *only* latest in each family.
- Supported families: AutoCAD, AutoCAD Electrical, AutoCAD Mechanical, AutoCAD Architecture, AutoCAD Map 3D, AutoCAD Plant 3D, AutoCAD LT, Civil 3D, and Vault Client. Treat all other products as untouched.
- Updates, localized content, shared components, licensing, add-ins, and Vault Server/ADMS are deliberately out of scope.
- Detection is a registry inventory, not a statement that an application works. Validate product family naming on representative devices before enabling Execute.

## Commands

Run using 64-bit Windows PowerShell 5.1, elevated or as Local SYSTEM:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AutodeskCleanup.ps1 -Mode Audit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AutodeskCleanup.ps1 -Mode Execute
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AutodeskCleanup.ps1 -Mode Execute -MinimumKeepYear 2025
```

If Configuration Manager invokes 32-bit PowerShell, launch the 64-bit executable via `%windir%\SysNative\WindowsPowerShell\v1.0\powershell.exe` (or configure the step to run a 64-bit process). The script refuses a 32-bit host.

### Results

`C:\ProgramData\AutodeskVersionCleanup\LatestPlan.csv` and `LatestSummary.json`, plus timestamped logs. The report stays on the client by default; do not assume ConfigMgr automatically collects it. Collect using hardware inventory extensions, status-message/custom reporting, CMPivot, or a protected file collection workflow of your choice.

Exit codes from Execute:

| Code | Meaning | ConfigMgr mapping |
|---|---|---|
| 0 | All selected removals completed, or none needed | Success |
| 3010 | Removals completed; reboot requested | Soft reboot |
| 1 | Unsupported command, blocked by running CAD/Vault, still registered, or failed | Failure / review log |

Windows Installer 1618 gets up to two retries by default (45 s between attempts). Do not set indefinite retries. CAD/Vault processes currently running cause a safe defer (exit 1).

## ConfigMgr rollout (preferred: Package/Program)

1. Create Package with these files, distribute content to DPs.
2. Program command line: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Invoke-AutodeskCleanup.ps1 -Mode Audit`
3. Run **whether or not a user is logged on**, with administrative rights; allow sufficient max run time (e.g. 180–240 minutes for large installations). Run from DP-cached package content, not interactive user context.
4. Deploy Audit to a small pilot collection; review client CSV/JSON logs and the family grouping. Test clients with AutoCAD 2019/2023/2025 + Electrical and Vault, plus devices with only one version.
5. Separate remediation Program with `-Mode Execute`; begin with hand-picked IT test devices, then 1%, 5%, 20%, rest, allowing monitoring between waves. Use maintenance windows and policy approval; communicate that CAD applications must be closed.
6. Avoid automatic device reboot in the script. Configure ConfigMgr for soft-reboot code 3010 and maintenance-window restart handling.
7. If Application model is required, use `Detect-AutodeskCleanup.ps1` as a custom detection script. It emits output **only if no eligible older versions remain**. Its `MinimumKeepYear` must match remediation policy; update the number in both scripts together. Note this detects cleanup compliance, not software presence.

## Classic 2019–2021

- Prefer the product's verified registry `UninstallString` if it contains **Setup.exe/Uninstall.exe**, `/P {actual GUID}`, `/R product-acronym`, and `/LANG locale`. The script adds `/Q /W` only after these are verified.
- If missing, obtain the product-specific *uninstall command* from the original Autodesk deployment image `SMS_SCCM` uninstall script or the corresponding local registry entry. Do **not** fabricate `/P` GUID or `/R` acronym, and do **not** replace an ODIS uninstall with `msiexec /x`.
- For an approved command use a CSV with **Family,Year,UninstallCommand** headers, e.g. `-LegacyOverridesCsv .\LegacyOverrides.csv`. It is validated for supported executables and required arguments.
- A product can be installed in multiple languages/editions within the same family; this initial policy groups by displayed family and major year. Review before enabling on a multilingual fleet.

## Security/operational cautions

- Registry-driven execution as SYSTEM trusts locally registered uninstall strings. Restrict local admin rights; review the audit export before deploying remediation.
- Ensure backups of CUIX, PGP, tool palettes, profiles, LISP, templates, plotting configurations and Vault integrations.
- Do not use `Win32_Product`, delete shared files, delete registry trees, or clean Autodesk licensing/ODIS globally.
- `Start-Process -Wait` waits for the launched process tree, but legacy installers and deferred removals may still need a reboot. The script checks uninstall registry registration after each completed command and flags ambiguity rather than claiming success.
- If previous-year AutoCAD is needed for a customer plugin or project, use an exclusion collection instead of running cleanup on it.

## Official references

- ODIS uninstall strings: https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Msiexec-exe-X-command-to-uninstall-Autodesk-software-installed-via-the-New-Installation-Experience-ODIS.html
- Silent ODIS: https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/Which-silent-command-line-should-be-used-with-the-2022-Autodesk-versions.html
- Classic Autodesk uninstall: https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/How-to-uninstall-Autodesk-Products-silently-along-with-the-updates-with-Classic-Installer.html
- Classic SCCM deployment scripts: https://www.autodesk.com/support/technical/article/caas/sfdcarticles/sfdcarticles/How-to-Uninstall-Autodesk-Products-Silently-Using-Batch-Scripts.html
- ConfigMgr exit codes: https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-applications
