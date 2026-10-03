# test_images

Put the JPEG files you want to decode here and run `python3 scripts/decode.py` from the repository
root (see the main README). Any baseline JPEG works; progressive, 12-bit, lossless and
arithmetic-coded files are reported as unsupported.

`adapter.jpg` (3120x4160, 4:2:2, a photo by the project owner) is the source of every test file in
`tb/corpus/` (`scripts/make_corpus.py`); keep it if you regenerate the corpus.
