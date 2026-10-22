# Evidence

Saved output of `verify-access.sh`, run as an admin after each deployment:

```bash
./verify-access.sh | tee evidence/verify-access-$(date +%Y%m%d).txt
```

Then copy [Evidence-Report-Template.md](Evidence-Report-Template.md) to `Evidence-Report-YYYYMMDD.md` and fill it in from that output. It lists the expected result for each of the ten sections, so the Head of Security can see at a glance what passed.

| File | What it is |
|---|---|
| `Evidence-Report-Template.md` | Blank report: expected results, paste boxes, pass/fail, sign-off |
| `verify-access-YYYYMMDD.txt` | Raw script output from one run |
| `Evidence-Report-YYYYMMDD.md` | Completed report for that run |

The script never prints secret values. Review each file before committing it anyway.
