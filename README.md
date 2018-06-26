# PostgreSQL Release Notes Parser

This script generates a giant HTML document from the release notes for all PostgreSQL versions, generating a matrix of different features.

It is primarily used to update the contents of the `https://bucardo.org/postgres_all_versions.html` file.

# Usage

```shell-session
$ perl postgres_release_notes.pl
# writes to /tmp/cache/postgres_all_versions.html
```

# Author

Greg Sabino Mullane <greg@turnstep.com>

