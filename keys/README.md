# Release Keys

This folder is for your support team's public key(s) that will be shipped to customers.

- Create `support.pub` (one or multiple lines, OpenSSH public keys).
- Keep the corresponding private key(s) on the support side only.

Then build the customer zips:

```bash
./scripts/build-release-zips.sh
```

