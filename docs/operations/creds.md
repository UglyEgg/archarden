# Credentials

Phase 1 intentionally avoids overcomplicated in-band admin bootstrap for every downstream service. Credential rotation is handled after the base system is reachable.

## Why

This was learned the hard way. Some services expose brittle or unstable first-boot automation paths. The professional move is not “automate everything no matter what,” but “automate what is stable, then make the rest explicit and recoverable.”
