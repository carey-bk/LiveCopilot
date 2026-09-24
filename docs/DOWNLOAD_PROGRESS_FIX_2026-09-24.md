# Download progress callback repair

The previous URLSession async download(from:) path returned files without didWriteData notifications in a throttled loopback reproduction, even with an explicit task delegate. Replaced it with downloadTask(with:) / downloadTask(withResumeData:) bridged through a cancellation-aware continuation. Temporary files are retained before didFinishDownloadingTo returns; didCompleteWithError resolves the continuation. The same path handles BGE, Paraformer and Laya Python bootstrap.

Real loopback transfer: 2,097,152 bytes, intermediate 16%, 28%, 41%, 53%, 66%, 78%, 91%, 100%; about 1.2 MB/s. Automated tests compile the actual observer from the application source, then verify intermediate percentages, unknown-length byte/speed updates, and cancellation. Three tests passed. Fourteen Laya downloader tests passed. No installed model files were deleted.

Run: python3 -m unittest discover -s StealthApp/Tests -p test_download_progress.py
