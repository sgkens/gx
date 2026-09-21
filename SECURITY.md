# Security policy

Do not open a public issue containing a token, credential-bearing remote URL, private repository name, or trace log with sensitive data.

Report a suspected credential leak privately to the repository owner through GitLab. Revoke or rotate exposed credentials before investigating because removing a value from Git configuration or history does not invalidate it.

The commit guard is a defense-in-depth pattern scanner. It is not a complete secret scanner and does not replace provider-side secret detection or credential rotation.
