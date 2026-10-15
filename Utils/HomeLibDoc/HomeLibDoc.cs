// Copyright (c) 2026 MyHomeLib contributors. MIT license; see ../../LICENSE.
// DOC decoding is provided by pinned DocSharp.Binary libraries (MIT/BSD).
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
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
        try { return Run(args); }
        catch (Exception error)
        {
            Console.Error.WriteLine("DOC component: " + error.GetType().Name + ": " + error.Message);
            return 1;
        }
    }
    private static int Run(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        if (args.Length == 1 && args[0] == "--version")
        {
            Console.WriteLine("HomeLibDoc 3; DocSharp " + typeof(WordDocument).Assembly.GetName().Version +
                "; Common " + typeof(StructuredStorageReader).Assembly.GetName().Version +
                "; PPT " + typeof(DocSharp.Binary.PptFileFormat.PowerpointDocument).Assembly.GetName().Version +
                "; XLS " + typeof(DocSharp.Binary.Spreadsheet.XlsFileFormat.XlsDocument).Assembly.GetName().Version);
            return 0;
        }
        if (args.Length == 3 && args[0] == "--image-to-png") return RasterizeImage(args[1], args[2]);
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
            string extension = Path.GetExtension(inputPath).ToLowerInvariant();
            if (extension == ".ppt" || extension == ".pps" || extension == ".pot" || extension == ".xls" || extension == ".xlt")
            {
                using (var storage = new StructuredStorageReader(inputPath))
                using (var file = new FileStream(outputPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    ownsOutput = true;
                    using (var bounded = new BoundedDocOutput(file))
                    {
                        if (extension == ".ppt" || extension == ".pps" || extension == ".pot")
                        {
                            var document = new DocSharp.Binary.PptFileFormat.PowerpointDocument(storage);
                            using (var output = DocSharp.Binary.OpenXmlLib.PresentationML.PresentationDocument.Create(bounded, DocSharp.Binary.OpenXmlLib.PresentationDocumentType.Presentation))
                                DocSharp.Binary.PresentationMLMapping.Converter.Convert(document, output);
                        }
                        else
                        {
                            var document = new DocSharp.Binary.Spreadsheet.XlsFileFormat.XlsDocument(storage);
                            using (var output = DocSharp.Binary.OpenXmlLib.SpreadsheetML.SpreadsheetDocument.Create(bounded, DocSharp.Binary.OpenXmlLib.SpreadsheetDocumentType.Workbook))
                                DocSharp.Binary.SpreadsheetMLMapping.Converter.Convert(document, output);
                        }
                    }
                }
                Console.WriteLine("OK office=" + extension + " ms=" + watch.ElapsedMilliseconds);
                return 0;
            }
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

    private static int RasterizeImage(string input, string output)
    {
        input = Path.GetFullPath(input); output = Path.GetFullPath(output);
        if (String.Equals(input, output, StringComparison.OrdinalIgnoreCase) || File.Exists(output))
            throw new ArgumentException("Output must be a new file, separate from the original.");
        if (new FileInfo(input).Length > 16L * 1024 * 1024) throw new IOException("Embedded image exceeds 16 MiB.");
        bool ownsOutput = false;
        try
        {
            // GDI+ is a Windows component, not an Office installation. Only the
            // local image is decoded; no document, macro or external link runs.
            using (var stream = File.OpenRead(input))
            using (var image = Image.FromStream(stream, false, true))
            {
                int width = image.Width, height = image.Height;
                if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || (long)width * height > 16777216)
                    throw new IOException("Embedded image dimensions exceed the reader limit.");
                using (var bitmap = new Bitmap(width, height, PixelFormat.Format32bppPArgb))
                {
                    using (var graphics = Graphics.FromImage(bitmap)) graphics.DrawImage(image, 0, 0, width, height);
                    using (var file = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        ownsOutput = true;
                        using (var bounded = new BoundedDocOutput(file)) bitmap.Save(bounded, ImageFormat.Png);
                    }
                }
            }
            return 0;
        }
        catch { if (ownsOutput) { try { File.Delete(output); } catch { } } throw; }
    }
}
