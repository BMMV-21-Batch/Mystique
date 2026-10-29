-- 009: receipts up to 5 MB per file (was 2 MB in 007). Most buyers upload bank PDFs, which the
-- client can't shrink; images are still re-encoded to ~500 KB before upload (spec §12.4).
-- The 10-uploads-per-24 h limit (SD-2) is unchanged; worst case per account is now 50 MB/day.
update storage.buckets set file_size_limit = 5242880 where id = 'receipts';
