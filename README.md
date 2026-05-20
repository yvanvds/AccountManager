# Arcadia Account Manager

[![CI](https://github.com/yvanvds/AccountManager/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/yvanvds/AccountManager/actions/workflows/ci.yml)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_AccountManager&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=yvanvds_AccountManager)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_AccountManager&metric=coverage)](https://sonarcloud.io/summary/new_code?id=yvanvds_AccountManager)

Synchronises user accounts and class groups between WISA, Smartschool, and Azure AD / Office 365 for a Belgian secondary-school group.

This repository is in transition from a WPF / .NET Framework 4.8 desktop application to a **Flutter / Dart** application.

- **Project goal, layout, port order:** [CLAUDE.md](CLAUDE.md)
- **Architectural reference:** [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md)
- **Spec for the port:** [docs/domain-model.md](docs/domain-model.md)
- **Legacy WPF code (read-only reference):** [legacy-wpf/](legacy-wpf/)

The SonarCloud badges above will activate once the operator finishes the SonarCloud project setup — see [.github/workflows/ci.yml](.github/workflows/ci.yml) for the steps.
