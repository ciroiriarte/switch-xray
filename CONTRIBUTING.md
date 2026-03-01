# Contributing to switch-xray

Thank you for your interest in contributing! Here are some guidelines to help
you get started.

## Reporting Issues

- Search [existing issues](https://github.com/ciroiriarte/switch-xray/issues)
  before opening a new one.
- Include the output of `switch-xray.sh -v` and your OS/distro version.
- For SNMP-related problems, mention the switch platform and SNMP version used.

## Submitting Changes

1. Fork the repository and create a feature branch from `main`.
2. Keep commits focused — one logical change per commit.
3. Update documentation (README, man page) if your change affects usage.
4. Test against at least one switch platform (or describe your test setup in
   the PR).
5. Open a pull request with a clear description of the change and its purpose.

## Code Style

- The project is a single Bash script. Keep it that way — exhaust Bash
  capabilities before adding external dependencies.
- Use `snake_case` for variables and functions.
- Quote all variable expansions (`"$VAR"`, not `$VAR`).
- New platform support should follow the existing pattern: add a
  `filter_interfaces_<platform>()` function and a detection clause in
  `detect_platform()`.

## Adding a New Platform

1. Add a pattern match in `detect_platform()` for the platform's `sysDescr.0`.
2. Implement `filter_interfaces_<platform>()` returning the relevant interface
   name patterns.
3. Test with real SNMP data or provide sample `snmpbulkwalk` output for review.
4. Update the **Supported Platforms** table in `README.md` and `man/man8/switch-xray.8`.

## License

By contributing, you agree that your contributions will be licensed under the
[GNU General Public License v3.0](LICENSE).
