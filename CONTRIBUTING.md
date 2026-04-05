# Contributing to PayFlow Wallet

Thank you for helping improve this project. Contributions keep the learning path and production patterns accurate for everyone.

## Attribution — if you use this repository

If you use PayFlow Wallet as a **starting point**, **course material**, **portfolio fork**, or **substantial reuse** of its code or documentation, **please give credit** to the original work. A short notice is enough—for example in your README, syllabus, or video description:

- Name the project (**PayFlow Wallet**).
- Link to the source repository: **https://github.com/Ship-With-Zee/payflow-wallet**

That helps others find the upstream project and keeps expectations clear about what is original versus derived.

## How to contribute

- **Issues** — Bug reports, unclear docs, or deployment friction: open an issue with what you ran, what you expected, and logs or `validate.sh` output when relevant.
- **Pull requests** — Keep changes focused on one topic. Describe the problem and how your change fixes it.

## Before you open a PR

- Run **`./scripts/validate.sh`** (Docker Compose) after your change when it touches the app path or scripts.
- If you change Node dependencies, run **`npm install`** in the affected service directory so `package-lock.json` stays consistent.
- Match existing style in the files you touch; avoid unrelated refactors in the same PR.

## Questions

Use issues for questions that might help future readers (documentation gaps). For security-sensitive reports, contact maintainers privately if that process is published on the repository; otherwise open a private security advisory on GitHub if enabled.
