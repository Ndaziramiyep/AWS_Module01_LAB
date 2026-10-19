# Evidence

Saved output of `verify-access.sh`, run as an admin after each deployment:

```bash
./verify-access.sh | tee evidence/verify-access-$(date +%Y%m%d).txt
```

The script never prints secret values. Review each file before committing it anyway.
