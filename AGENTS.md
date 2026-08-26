# AGENTS.md

Single-file Perl tool (`read_dvd.pl`) that parses the IFO files of a ripped DVD's `VIDEO_TS/` directory, picks titles, and transcodes them to AV1 MKV by piping raw VOB sectors to ffmpeg. Part of its purpose is to tolerate broken DVDs that violate the spec in ways we can detect and work around. No build system, no test suite, no CI. GPL-3.0.

## Running

```sh
perl read_dvd.pl [options] /path/to/dvd/
```

- The argument is a DVD directory containing `VIDEO_TS/`; it must contain `VIDEO_TS/VIDEO_TS.IFO` (falls back to `.BUP`). There are no sample DVDs or fixtures in the repo, so the tool cannot be exercised end-to-end here.
- Runtime binaries must be on `PATH`: `ffmpeg` (spawned via pipe-open, fed VOB data on stdin) and `mediainfo` (backticked to detect interlacing / channel count). The encode profile needs a ffmpeg with `libsvtav1` and `libopus`.
- Non-core CPAN module required: `Devel::StackTrace` (used in the `read_*` byte helpers). Everything else (`Getopt::Long`, `Data::Dumper`, `Fcntl`, `feature`) is core.
- `--debug` prints the ffmpeg command and cell plan without encoding — the main way to sanity-check changes without a long transcode.
- Defaults that matter: titles shorter than `--min-runtime` (default 300 s) are skipped; output is `$DEST/$Name.<title-index>.av1.mkv`; `$Name` auto-detects from the directory name (trailing `/VIDEO_TS` stripped) unless `--name` is given.
- `Getopt::Long::Configure("bundling")` is on, so short options (`-d`, `-n`) work and long options accept single-dash forms.

## Verification

`perl -c read_dvd.pl` is the only available check (needs perl ≥ 5.20 for `use feature 'signatures'`). There are no tests, linters, or CI.

## Architecture notes

- `read_vmg()` is the entrypoint: parses the VMG descriptor, then each `VTS_xx_0.IFO`, computes per-title playtimes from the PGC/cell tables, and selects titles. Titles are sorted by ascending playtime and cell sets are deduped (`already_seen`) so "Play All" titles don't re-rip the same episodes.
- All IFO parsing is raw binary reads with hardcoded spec offsets; VOB/cell addresses are 2048-byte sectors (`*2048`). The doc links at the top of the script (dvd.sourceforge.net/dvdinfo, wikibooks "Inside DVD-Video/IFO Files") are the reference — read those before touching any `read_*` function or offset.
- Broken-DVD tolerance is deliberate: `read_vts_title_program_chain_table` already contains a fallback for corrupt PGC table offsets (reads at the current position when `offset >= end_address`). When adding new parsing, keep the same "detect the violation and work around it" approach.
- VOB files are matched with `VTS_%02d_[1-9].VOB`; the `_0.VOB` menu VOB is intentionally skipped.
- Chapters are passed to ffmpeg as an FFMETADATA1 file (`;FFMETADATA1` + `[CHAPTER]` blocks) written to `/tmp/dvd.$$.chapters.txt`, mapped via `-map_chapters 1`.
- Current encode profile: libsvtav1 (crf 32, preset 5, yuv420p10le, GOP 240), Opus 160k audio (or `-c:a copy` when mediainfo reports >2 channels), subtitles copied, optional `yadif=1:-1:0` deinterlacing. `--simple-mapping` switches from `-map 0:v -map 0:a? -map 0:s?` to a plain `-map 0`.
- `read_vobu_address_table` and `min()` are dead code (defined but never called).

## Code quality

- Comments should explain the *purpose* of the code, not restate what it does.
- Every function should have a comment header explaining its purpose within the code and when to use it.
- All functions and variables should have helpfully descriptive names.
