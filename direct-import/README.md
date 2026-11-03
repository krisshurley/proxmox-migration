# Offline direct-import payloads

These are unchanged vendor files exported from the reviewed
`virtio-win-guest-tools.exe` (0.1.271-1). Copyright and licensing remain with
the original authors; the NetKVM Readme files and vendor INF notices are retained.

Copy this complete directory with the migration scripts for direct ESXi import.
Do not replace individual files. `Migration.DirectImport.ps1` verifies a pinned
manifest and every payload's SHA-256 before use.

The Veeam/Firstboot workflow does not use this directory.

Reproduce/verify from the repository root with:

```sh
python3 tools/export_direct_import_payloads.py
python3 tools/export_direct_import_payloads.py --check
```
