# C17 foundation prototype bootstrap implementation

Standalone synthetic Go/SQLite prototype, not an integrated Cortex build and not an autonomous coding/repair agent. No private Cortex source or credentials are published.

Run Start-C17FoundationPrototype.ps1 from an elevated Windows PowerShell 5.1 or later window on a dedicated disposable Windows Server 2022 AMD64 VM. No GitHub login is needed for this public repository. The launcher makes no interactive requests and retains its final report, source, command outputs, state and local checkpoints.

Go 1.27.1 is downloaded from official Go release metadata; its archive SHA-256 is checked before execution. modernc.org/sqlite is pinned to v1.56.0. Transitive dependencies are resolved, checksum-verified, recorded and vendored per run. The launcher builds supplied deterministic source, runs 24 acceptance test functions three times, and executes a separate-process intentional crash/recovery demonstration against an independently persisted mock external submission.

Default run storage uses E:\dev\tools\c17-foundation-prototype if E: exists, otherwise LocalAppData. Each invocation uses a unique directory. It refuses detected cortexd/cortextray processes, missing elevation, disabled firewall profiles, and credential-like environment variables. During acceptance it installs outbound-block firewall rules for its own Go, test and demo executable paths, and removes only its own rules on normal exit. Hard terminal closure may bypass cleanup. These controls do not independently prove hypervisor isolation or absence of credentials in the Windows profile.

No production service, Supabase schema, model, broker, private repository, Git push, or deployment is used. Automatic code repair is not implemented: failures produce an honest report rather than weakening requirements or asking questions. Checkpoints are same-drive copies, not off-device backups.

Return the single FINAL-REPORT.txt from the path printed at completion. No ZIP upload or intermediate console dump is needed.

Authoring validation: embedded-command integrity and SQLite schema/rollback/duplicate-submission checks using Python sqlite3. Go compilation, Go-driver integration, PowerShell parsing, Windows execution and firewall behavior were NOT tested in the authoring environment. Passing on the VM establishes only the bounded fixture coverage, not the entire original prototype brief, full fabrication resistance, integration correctness, or production readiness. Repository tools/verify.py is NOT run by this package.
