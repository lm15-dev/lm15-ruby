# Authentication

A provider accepts `api_key:` or `credential:`. A string is an API key shorthand. A callable returns a fresh string or canonical credential. For OAuth-only CLI providers, router API-key entries are not substitutes for the CLI's own login file. For xAI, an explicit credential takes precedence over stored subscription OAuth.

`LM15.explain_auth(provider, env: ..., files: ..., settings: ...)` performs offline discovery. With `files:` supplied, reads use the injected file map. Reports describe configured sources and do not prove that a network exchange will succeed. `LM15.explain_auth(router.resolve(model), config: router.config)` uses the router's account selection.

## Cloud sources

| Family | Native resolution order after provider-specific bearer/key variables |
|---|---|
| AWS | Environment access/secret keys; assume role; web identity; IAM Identity Center SSO; shared credentials; AWS login cache; `credential_process`; config-file keys; container credentials; IMDSv2 |
| Azure | Environment secret/certificate; workload identity; managed identity; Azure CLI; PowerShell; Azure Developer CLI. `AZURE_TOKEN_CREDENTIALS` narrows the chain. |
| GCP | Explicit ADC file; default ADC file; metadata identity; gcloud. ADC supports service accounts, authorized users, supported external-account sources, and service-account impersonation. |

Cloud operations use the same injectable HTTP transport as inference. AWS signing covers the final wire URL, headers, and body. Service accounts and Azure certificate credentials sign RS256 assertions with OpenSSL. Provider instances cache expiring cloud credentials; identity-selecting settings and environment changes invalidate the cached identity.

Examples:

```ruby
aws = LM15.adapter_for('bedrock-anthropic',
  settings: { 'region' => 'us-east-1' },
  credential: LM15::AwsCredentials.new(
    access_key_id: ENV.fetch('AWS_ACCESS_KEY_ID'),
    secret_access_key: ENV.fetch('AWS_SECRET_ACCESS_KEY'),
    session_token: ENV['AWS_SESSION_TOKEN']
  ))
azure = LM15.adapter_for('azure', settings: { 'resource' => 'my-resource' })
vertex = LM15.adapter_for('vertex', settings: { 'project' => 'my-project', 'location' => 'us-central1' })
```

Metadata endpoints and external-account executable sources are constrained by the reference chain's rules. Executable external accounts require `GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES=1`. Container credential HTTP URLs require an allowed local/metadata host; HTTPS sources are accepted. IAM role chains and impersonation recursion are bounded.

Unsupported credential sources fail explicitly: encrypted certificate/private-key files, Azure Service Fabric certificate identity, GCP GDCH credentials, and AWS-sourced GCP external-account federation. AWS event-stream framing for Bedrock streaming is also not implemented in this contract phase. CLI-based sources require their named CLI to be installed; the SDK does not install it.

## OAuth stores and locking

Default LM15 credential storage is `$LM15_CREDENTIALS_PATH`, otherwise `$XDG_CONFIG_HOME/lm15/credentials.json`, otherwise `~/.config/lm15/credentials.json`. Claude Code and Codex also read their CLI-owned files. xAI can read the compatible pi OAuth store as a fallback.

Refresh locks are advisory file locks in `$LM15_LOCK_DIR` or the LM15 cache lock directory. The lock name derives from the credential file's canonical path. Refresh re-reads the credential under the lock, preserves other providers and unknown CLI fields, and replaces the JSON file atomically with mode `0600`. Lock contention times out with `LockTimeoutError`; it never proceeds without the lock. This implementation has been exercised on Linux, not Windows.

```ruby
LM15.login('xai') # Displays a verification URL/code, polls, and persists tokens.
puts LM15.explain_auth('xai').describe
```

`Auth.start_xai_device_login` and `Auth.poll_xai_device_login` expose the device flow for custom interfaces. `LM15.generate_pkce` produces an S256 verifier/challenge pair. Other providers' login methods raise with the existing CLI or key configuration route.

No secret should be logged through `inspect` or auth reports. Explicit credential serialization and reading credential files naturally expose credential values to the caller; treat those outputs as secrets.
