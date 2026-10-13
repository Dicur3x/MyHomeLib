// Copyright (c) 2026 MyHomeLib contributors. MIT license; see ../../LICENSE.
// DOC decoding is provided by pinned DocSharp.Binary libraries (MIT/BSD).
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using DocSharp.Binary.DocFileFormat;
using DocSharp.Binary.StructuredStorage.Reader;
using DocSharp.Binary.OpenXmlLib;
using DocSharp.Binary.OpenXmlLib.WordprocessingML;
using DocSharp.Binary.WordprocessingMLMapping;

internal sealed class BoundedDocOutput : Stream
{
    private readonly Stream inner;
    internal BoundedDocOutput(Stream stream) { inner = stream; }
    public override bool CanRead { get { return false; } }
    public override bool CanSeek { get { return inner.CanSeek; } }
    public override bool CanWrite { get { return true; } }
    public override long Length { get { return inner.Length; } }
    public override long Position { get { return inner.Position; } set { inner.Position = value; } }
    public override void Flush() { inner.Flush(); }
    public override long Seek(long offset, SeekOrigin origin) { return inner.Seek(offset, origin); }
    public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override void SetLength(long value)
    {
        if (value < 0 || value > HomeLibDoc.MaximumBytes) throw new IOException("DOC output exceeds the reader limit.");
        inner.SetLength(value);
    }
    public override void Write(byte[] buffer, int offset, int count)
    {
        if (count < 0 || Position > HomeLibDoc.MaximumBytes - count) throw new IOException("DOC output exceeds the reader limit.");
        inner.Write(buffer, offset, count);
    }
    protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
}

internal static class HomeLibDoc
{
    internal const long MaximumBytes = 64L * 1024 * 1024;
    internal const int MaximumCharacters = 16 * 1024 * 1024;
    private static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("HomeLibDoc 1; DocSharp 0.21.0"); return 0; }
        bool ownsOutput = false;
        string outputPath = null;
        string errorCode = "INVALID";
        try
        {
            if (args.Length != 2) throw new ArgumentException("Expected source DOC and new output DOCX.");
            string inputPath = Path.GetFullPath(args[0]); outputPath = Path.GetFullPath(args[1]);
            if (String.Equals(inputPath, outputPath, StringComparison.OrdinalIgnoreCase) || File.Exists(outputPath))
                throw new ArgumentException("Output must be a new file, separate from the original.");
            var inputInfo = new FileInfo(inputPath);
            if (inputInfo.Length < 512 || inputInfo.Length > MaximumBytes) throw new IOException("DOC size is outside the reader limit.");
            var watch = Stopwatch.StartNew();
            using (var storage = new StructuredStorageReader(inputPath))
            {
                var fib = new FileInformationBlock(new VirtualStreamReader(storage.GetStream("WordDocument")));
                if (fib.fEncrypted) { errorCode = "PASSWORD"; throw new NotSupportedException("Password-protected DOC is unsupported."); }
                if ((int)fib.nFib < 0xC1 && (int)fib.nFibNew < 0xC1)
                { errorCode = "OLD"; throw new NotSupportedException("DOC predates Word 97."); }
                if (fib.ccpText < 0 || fib.ccpText > MaximumCharacters) throw new IOException("DOC text length is outside the reader limit.");
                var document = new WordDocument(storage);
                using (var file = new FileStream(outputPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    ownsOutput = true;
                    using (var bounded = new BoundedDocOutput(file))
                    using (var output = WordprocessingDocument.Create(bounded, WordprocessingDocumentType.Document))
                        Converter.Convert(document, output);
                }
                // Document mode never copies or executes VBA. The reader consumes
                // text and local images only; Office automation is not involved.
                Console.WriteLine("OK chars=" + fib.ccpText + " ms=" + watch.ElapsedMilliseconds);
            }
            return 0;
        }
        catch (Exception error)
        {
            if (ownsOutput) { try { File.Delete(outputPath); } catch { } }
            Console.WriteLine("ERROR " + errorCode);
            Console.Error.WriteLine("DOC: " + error.GetType().Name + ": " + error.Message);
            return 1;
        }
    }
}
