# Bloom secure path canary fixture

This project is intentionally non-production. It models a Composer and npm application with a
SQLite migration, built browser assets, persistent workspace state, and four supervised services.
The dependency locks are fixtures. Setup creates deterministic local package substitutes and never
contacts a package registry.

The service graph is `app`, then `queue` and `realtime`, then `assets`. Every process writes only
secret names, SHA-256 digests and non-sensitive lifecycle evidence beneath `.bloom-canary/`.
Plaintext credentials are never written to the workspace.
