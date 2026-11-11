# Security Policy

This policy covers BitTool Signer for iOS and the source code in this repository. BitTool Wallet and the Android signer are separate products and repositories.

## Report a vulnerability privately

Email **tomtan@bittool.com** with the subject **BitTool Signer iOS security report**. This is the project's security-reporting contact, handled by the BitTool team.

Please report suspected vulnerabilities privately before opening a public issue or publishing exploit details.

## What to include

- The affected app version and, if applicable, the source tag or commit.
- A description of the issue and its potential impact.
- Steps to reproduce it, preferably using synthetic data and an unfunded test wallet.
- Relevant iOS version and device model, if needed to reproduce the issue.

**Never send recovery phrases, private keys, passwords, real wallet backups, or other sensitive personal information.** Remove secrets and identifying information from logs, screenshots, and sample signing requests before sharing them. An initial report can describe the issue without an attachment.

## Review and disclosure

The BitTool team will review reports received at this address and may request additional information. Please coordinate public disclosure with us while we investigate and, where appropriate, prepare a fix. Include the affected version even if it is an older release; accepting a report does not establish a support or backport commitment for that release.

## Security limitations

BitTool Signer has **not undergone an independent third-party security audit**. Internal or AI-assisted reviews and automated tests are not a substitute for one.

The signer is designed to keep key handling and transaction signing on an offline device. It **does not make blockchain transactions private or anonymous**. Device and operating-system security remain part of its trust assumptions.

See [the security design](docs/Security.md) and [implementation status and known limitations](IMPLEMENTATION_STATUS.md) for further detail.
