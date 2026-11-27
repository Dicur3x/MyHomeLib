// Copyright (c) 2026 MyHomeLib contributors. MIT license; see ../../LICENSE.
// DOC decoding is provided by pinned DocSharp.Binary libraries (MIT/BSD).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Xml;
using System.Xml.Linq;
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
    private const int MaxRasterDimension = 16384;
    private const long MaxRasterPixels = 16L * 1024 * 1024;
    private static readonly XNamespace Word = OpenXmlNamespaces.WordprocessingML;

    [StructLayout(LayoutKind.Sequential)]
    private struct MetafilePicture
    {
        internal int MappingMode, Width, Height;
        internal IntPtr Handle;
    }

    [DllImport("gdi32.dll")]
    private static extern IntPtr SetWinMetaFileBits(uint length, byte[] data, IntPtr reference, ref MetafilePicture picture);
    [DllImport("gdi32.dll")]
    private static extern uint GetEnhMetaFileHeader(IntPtr handle, uint length, [Out] byte[] header);
    [DllImport("gdi32.dll")]
    private static extern bool DeleteEnhMetaFile(IntPtr handle);
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
            Console.WriteLine("HomeLibDoc 7; DocSharp " + typeof(WordDocument).Assembly.GetName().Version +
                "; Common " + typeof(StructuredStorageReader).Assembly.GetName().Version +
                "; PPT " + typeof(DocSharp.Binary.PptFileFormat.PowerpointDocument).Assembly.GetName().Version +
                "; XLS " + typeof(DocSharp.Binary.Spreadsheet.XlsFileFormat.XlsDocument).Assembly.GetName().Version);
            return 0;
        }
        if (args.Length == 3 && args[0] == "--image-to-png") return RasterizeImage(args[1], args[2]);
        if (args.Length == 2 && args[0] == "--image-to-png-stream") return RasterizeStream(args[1], false);
        if (args.Length == 3 && args[0] == "--drawingml-to-png") return RasterizeDrawing(args[1], args[2]);
        if (args.Length == 2 && args[0] == "--drawingml-to-png-stream") return RasterizeStream(args[1], true);
        if (args.Length == 3 && args[0] == "--drawingml-to-png-batch") return DrawingMlFigures.RenderBatch(args[1], args[2]);
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
                SupplyParagraphPropertiesForCharacterStyles(document);
                RemoveNoteReferenceTerminator(document.FootnoteReferencePlex, fib.lcbPlcffndRef);
                RemoveNoteReferenceTerminator(document.EndnoteReferencePlex, fib.lcbPlcfendRef);
                using (var file = new FileStream(outputPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    ownsOutput = true;
                    using (var bounded = new BoundedDocOutput(file))
                    using (var output = WordprocessingDocument.Create(bounded, WordprocessingDocumentType.Document))
                        Converter.Convert(document, output);
                }
                RestoreNoteRanges(outputPath, document);
                DocVmlFigures.Reflow(outputPath, document);
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

    private static void RemoveNoteReferenceTerminator(Plex<short> references, uint size)
    {
        // DocSharp looks up every CP in this list, including the final CP that
        // MS-DOC says to ignore. An absent PLC can also produce a single CP
        // from an unrelated table. Neither position represents a note.
        if (size == 0) references.CharacterPositions.Clear();
        else if (references.CharacterPositions.Count == references.Elements.Count + 1)
            references.CharacterPositions.RemoveAt(references.CharacterPositions.Count - 1);
    }

    private static void RestoreNoteRanges(string path, WordDocument document)
    {
        var fib = document.FIB;
        var hasFootnotes = fib.ccpFtn > 0 || document.FootnoteReferencePlex.Elements.Count > 0;
        var hasEndnotes = fib.ccpEdn > 0 || document.EndnoteReferencePlex.Elements.Count > 0;
        if (!hasFootnotes && !hasEndnotes) return;
        var replacements = new Dictionary<string, XDocument>();
        using (var file = File.OpenRead(path))
        using (var archive = new ZipArchive(file, ZipArchiveMode.Read))
        {
            var referenceIds = new Dictionary<string, List<string>> {
                { "footnote", new List<string>() }, { "endnote", new List<string>() }
            };
            using (var content = archive.GetEntry("word/document.xml").Open())
            using (var reader = XmlReader.Create(content, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit }))
                while (reader.Read())
                    if (reader.NodeType == XmlNodeType.Element && reader.NamespaceURI == Word.NamespaceName &&
                        (reader.LocalName == "footnoteReference" || reader.LocalName == "endnoteReference"))
                    {
                        var family = reader.LocalName == "footnoteReference" ? "footnote" : "endnote";
                        referenceIds[family].Add(reader.GetAttribute("id", Word.NamespaceName));
                    }
            if (hasFootnotes)
                RestoreNotePart(archive, document, "footnote", fib.ccpText, fib.ccpFtn,
                    fib.fcPlcffndTxt, fib.lcbPlcffndTxt, document.FootnoteReferencePlex, referenceIds["footnote"], replacements);
            if (hasEndnotes)
                RestoreNotePart(archive, document, "endnote", (long)fib.ccpText + fib.ccpFtn + fib.ccpHdr + fib.ccpAtn,
                    fib.ccpEdn, fib.fcPlcfendTxt, fib.lcbPlcfendTxt, document.EndnoteReferencePlex, referenceIds["endnote"], replacements);
        }
        if (replacements.Count == 0) return;
        // This is the helper's own new DOCX. The caller publishes it only
        // after the process succeeds, so no user's source archive is edited.
        using (var file = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        using (var archive = new ZipArchive(file, ZipArchiveMode.Update))
            foreach (var replacement in replacements)
            {
                archive.GetEntry(replacement.Key).Delete();
                using (var content = archive.CreateEntry(replacement.Key, CompressionLevel.Optimal).Open())
                    replacement.Value.Save(content, SaveOptions.DisableFormatting);
            }
    }

    private static void RestoreNotePart(ZipArchive archive, WordDocument document, string family, long storyStart,
        int storyLength, uint rangeOffset, uint rangeSize, Plex<short> references, List<string> ids,
        Dictionary<string, XDocument> replacements)
    {
        var count = references.Elements.Count;
        var name = "word/" + family + "s.xml";
        var entry = archive.GetEntry(name);
        var repaired = count > 0 && storyLength > 1 && storyStart >= 0 && storyStart + storyLength <= document.Text.Count &&
            rangeSize == ((long)count + 2) * 4 && (long)rangeOffset + rangeSize <= document.TableStream.Length &&
            entry != null && entry.Length <= MaximumBytes && ids.Count == count &&
            ids.Select((id, index) => id == index.ToString(CultureInfo.InvariantCulture)).All(matches => matches);
        if (repaired)
        {
            var positions = new Plex<byte>(0, document.TableStream, rangeOffset, rangeSize).CharacterPositions;
            XDocument part;
            using (var data = entry.Open()) part = XDocument.Load(data, LoadOptions.PreserveWhitespace);
            repaired = GroupNoteParagraphs(part, document, family, (int)storyStart, storyLength, positions, count);
            if (repaired) replacements.Add(name, part);
        }
        if (!repaired) Console.WriteLine("NOTE_LAYOUT " + family);
    }

    private static bool GroupNoteParagraphs(XDocument part, WordDocument document, string family,
        int storyStart, int storyLength, List<int> positions, int count)
    {
        if (part.Root == null || part.Root.Name != Word + (family + "s") || positions.Count != count + 2 ||
            positions[0] != 0 || positions[count] != storyLength - 1) return false;
        var paragraphs = part.Root.Elements().ToArray();
        var grouped = new List<XElement>();
        var cursor = 0;
        var sectionStarts = new HashSet<int>(document.SectionPlex.CharacterPositions);
        for (int i = 0; i < count; i++)
        {
            var first = positions[i];
            var end = positions[i + 1];
            if (end <= first || end >= storyLength) return false;
            var note = new XElement(Word + family, new XAttribute(Word + "id", i));
            for (int offset = first; offset < end; offset++)
            {
                var cp = storyStart + offset;
                var mark = document.Text[cp];
                var boundary = mark == TextMark.ParagraphEnd || mark == TextMark.CellOrRowMark ||
                    (mark == TextMark.PageBreakOrSectionMark && sectionStarts.Contains(cp + 1));
                if (!boundary)
                {
                    if (offset == end - 1) return false;
                    continue;
                }
                if (cursor == paragraphs.Length && offset == storyLength - 2 && mark == TextMark.ParagraphEnd &&
                    (offset == first || document.Text[cp - 1] == TextMark.ParagraphEnd))
                {
                    // DocSharp stops before this final empty paragraph.
                    note.Add(new XElement(Word + "p"));
                    continue;
                }
                if (cursor >= paragraphs.Length) return false;
                var wrapper = paragraphs[cursor];
                var content = wrapper.Elements().ToArray();
                if (wrapper.Name != Word + family || (int?)wrapper.Attribute(Word + "id") != cursor ||
                    content.Length != 1 || content[0].Name != Word + "p") return false;
                var paragraph = new XElement(content[0]);
                var previousMarker = Word + (family == "footnote" ? "endnoteRef" : "footnoteRef");
                foreach (var marker in paragraph.Descendants(previousMarker)) marker.Name = Word + (family + "Ref");
                note.Add(paragraph);
                cursor++;
            }
            grouped.Add(note);
        }
        if (cursor != paragraphs.Length) return false;
        part.Root.ReplaceNodes(grouped);
        return true;
    }

    private static void SupplyParagraphPropertiesForCharacterStyles(WordDocument document)
    {
        // Some DOCs reference a character style from a paragraph. DocSharp
        // consults its paragraph properties for text direction. Preserve the
        // style and direct formatting, and supply the missing property list.
        var styles = document.Styles == null ? null : document.Styles.Styles;
        if (styles == null) return;
        foreach (var paragraph in document.AllPapx.Values)
        {
            if (paragraph.istd >= styles.Count) continue;
            var style = styles[paragraph.istd];
            if (style != null && style.stk == StyleSheetDescription.StyleKind.character && style.papx == null)
                style.papx = new ParagraphPropertyExceptions();
        }
    }

    private static int RasterizeDrawing(string input, string destination)
    {
        var drawing = DrawingMlFigures.Render(input);
        if (drawing == null) return 3;
        using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            output.Write(drawing, 0, drawing.Length);
        return 0;
    }

    private static int RasterizeStream(string directory, bool drawing)
    {
        // The caller owns a private, per-book directory. The stream cannot
        // supply paths or run commands, and one image is decoded at a time.
        directory = Path.GetFullPath(directory);
        if (!Directory.Exists(directory)) throw new DirectoryNotFoundException(directory);
        string input = Path.Combine(directory, "picture.bin");
        string output = Path.Combine(directory, "picture.png");
        Console.WriteLine("READY 1");
        for (int command; (command = Console.In.Read()) != -1;)
        {
            if (command != 'R') return 1;
            try
            {
                int result = drawing ? RasterizeDrawing(input, output) : RasterizeImage(input, output);
                Console.WriteLine(result == 0 ? "OK" : "ERROR");
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("Office image: " + error.GetType().Name + ": " + error.Message);
                Console.WriteLine("ERROR");
            }
        }
        return 0;
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
                if (!FitsRaster(width, height) && image is Metafile && width > 0 && height > 0)
                {
                    var header = ((Metafile)image).GetMetafileHeader();
                    if (HasStandardWmfHeader(stream))
                    {
                        // GDI+ can describe a standard WMF as an EMF with oversized device bounds.
                        // Use the same physical frame as the native reader instead of parsing WMF bytes as EMF.
                        using (var converted = ConvertStandardWmf(stream, out width, out height))
                            WriteRaster(converted, width, height, output, ref ownsOutput, true);
                        return 0;
                    }
                    else if (header.IsWmfPlaceable())
                    {
                        // A placeable WMF reports its drawing units, often over 2,000 per inch.
                        double physicalWidth = Math.Ceiling(width * 192.0 / image.HorizontalResolution);
                        double physicalHeight = Math.Ceiling(height * 192.0 / image.VerticalResolution);
                        if (physicalWidth >= 1 && physicalWidth <= MaxRasterDimension &&
                            physicalHeight >= 1 && physicalHeight <= MaxRasterDimension)
                        {
                            width = (int)physicalWidth;
                            height = (int)physicalHeight;
                        }
                    }
                    else if (header.IsEmfOrEmfPlus())
                    {
                        // Render the vector directly into a uniformly smaller canvas.
                        // Keep the same limits without discarding a high-DPI diagram.
                        if (!HasCompleteEmf(stream)) throw new InvalidDataException("Incomplete embedded EMF.");
                        double scale = Math.Min((double)MaxRasterDimension / Math.Max(width, height),
                                                Math.Sqrt(MaxRasterPixels / ((double)width * height)));
                        width = Math.Max(1, (int)Math.Floor(width * scale));
                        height = Math.Max(1, (int)Math.Floor(height * scale));
                    }
                }
                WriteRaster(image, width, height, output, ref ownsOutput);
            }
            return 0;
        }
        catch { if (ownsOutput) { try { File.Delete(output); } catch { } } throw; }
    }

    private static bool FitsRaster(int width, int height)
    {
        return width > 0 && height > 0 && width <= MaxRasterDimension && height <= MaxRasterDimension &&
            (long)width * height <= MaxRasterPixels;
    }

    private static void WriteRaster(Image image, int width, int height, string output, ref bool ownsOutput,
                                    bool trimDeviceFrame = false)
    {
        if (!FitsRaster(width, height))
            throw new IOException("Embedded image dimensions exceed the reader limit.");
        using (var bitmap = new Bitmap(width, height, PixelFormat.Format32bppPArgb))
        {
            using (var graphics = Graphics.FromImage(bitmap)) graphics.DrawImage(image, 0, 0, width, height);
            var frame = new Rectangle(0, 0, width, height);
            var ink = trimDeviceFrame ? PaintedBounds(bitmap) : frame;
            if (ink.IsEmpty) throw new InvalidDataException("Embedded WMF contains no visible drawing.");
            // Discard spurious transparent device margins without cutting any painted pixels.
            using (var cropped = ink == frame ? null : bitmap.Clone(ink, PixelFormat.Format32bppPArgb))
            using (var file = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                ownsOutput = true;
                using (var bounded = new BoundedDocOutput(file)) (cropped ?? bitmap).Save(bounded, ImageFormat.Png);
            }
        }
    }

    private static Rectangle PaintedBounds(Bitmap bitmap)
    {
        var frame = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var pixels = bitmap.LockBits(frame, ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        try
        {
            var row = new int[frame.Width];
            int left = frame.Right, right = 0, top = frame.Bottom, bottom = 0;
            for (int y = 0; y < frame.Height; y++)
            {
                Marshal.Copy(IntPtr.Add(pixels.Scan0, y * pixels.Stride), row, 0, row.Length);
                for (int x = 0; x < row.Length; x++)
                {
                    if ((row[x] >> 24) == 0) continue;
                    left = Math.Min(left, x); right = Math.Max(right, x + 1);
                    top = Math.Min(top, y); bottom = y + 1;
                }
            }
            return right > left ? Rectangle.FromLTRB(left, top, right, bottom) : Rectangle.Empty;
        }
        finally { bitmap.UnlockBits(pixels); }
    }

    private static bool HasStandardWmfHeader(Stream stream)
    {
        if (stream.Length < 18) return false;
        long savedPosition = stream.Position;
        try
        {
            stream.Position = 0;
            using (var reader = new BinaryReader(stream, Encoding.UTF8, true))
            {
                ushort type = reader.ReadUInt16();
                ushort words = reader.ReadUInt16();
                ushort version = reader.ReadUInt16();
                return (type == 1 || type == 2) && words == 9 && (version == 0x0100 || version == 0x0300);
            }
        }
        finally { stream.Position = savedPosition; }
    }

    private static Metafile ConvertStandardWmf(Stream stream, out int width, out int height)
    {
        const int HeaderSize = 18, MinimumRecord = 3;
        const ushort Escape = 0x0626, Comment = 15;
        // Check the original standard WMF records and disallow printer commands, as the native reader does.
        stream.Position = 6;
        using (var reader = new BinaryReader(stream, Encoding.UTF8, true))
        {
            uint declaredWords = reader.ReadUInt32();
            reader.ReadUInt16();
            uint largestRecord = reader.ReadUInt32();
            long length = declaredWords * 2L;
            if (length < HeaderSize + 6 || length > stream.Length || largestRecord < MinimumRecord || largestRecord > declaredWords - 9)
                throw new InvalidDataException("Incomplete embedded WMF.");
            long offset = HeaderSize;
            bool ended = false;
            while (offset + 6 <= length)
            {
                stream.Position = offset;
                uint words = reader.ReadUInt32();
                ushort type = reader.ReadUInt16();
                if (words < MinimumRecord || words > largestRecord || words * 2L > length - offset) break;
                if (type == Escape && (words < 5 || reader.ReadUInt16() != Comment)) break;
                offset += words * 2L;
                if (type != 0) continue;
                ended = words == MinimumRecord && offset == length;
                break;
            }
            if (!ended) throw new InvalidDataException("Incomplete or unsupported embedded WMF.");
            stream.Position = 0;
            byte[] bytes = reader.ReadBytes((int)length);
            var picture = new MetafilePicture { MappingMode = 8 }; // MM_ANISOTROPIC
            IntPtr handle = SetWinMetaFileBits((uint)bytes.Length,bytes,IntPtr.Zero,ref picture);
            if (handle == IntPtr.Zero) throw new InvalidDataException("Could not decode embedded WMF.");
            try
            {
                var header = new byte[108];
                if (GetEnhMetaFileHeader(handle,(uint)header.Length,header) < 40)
                    throw new InvalidDataException("Could not read the embedded WMF frame.");
                // ENHMETAHEADER.rclFrame uses hundredths of a millimetre.
                long widthFrame = (long)BitConverter.ToInt32(header,32) - BitConverter.ToInt32(header,24);
                long heightFrame = (long)BitConverter.ToInt32(header,36) - BitConverter.ToInt32(header,28);
                if (widthFrame <= 0 || heightFrame <= 0) throw new InvalidDataException("Invalid embedded WMF frame.");
                double scale = Math.Min(96.0/2540,Math.Min((double)MaxRasterDimension/Math.Max(widthFrame,heightFrame),
                    Math.Sqrt(MaxRasterPixels/((double)widthFrame*heightFrame))));
                width = Math.Max(1,(int)Math.Floor(widthFrame*scale));
                height = Math.Max(1,(int)Math.Floor(heightFrame*scale));
                var metafile = new Metafile(handle,true);
                handle = IntPtr.Zero;
                return metafile;
            }
            finally { if (handle != IntPtr.Zero) DeleteEnhMetaFile(handle); }
        }
    }

    internal static bool HasCompleteEmf(Stream stream)
    {
        const uint Header = 1, EndOfFile = 14, Signature = 0x464D4520;
        const int MinHeaderBytes = 88, MinEndBytes = 20;
        long savedPosition = stream.Position;
        try
        {
            if (stream.Length < MinHeaderBytes + MinEndBytes) return false;
            using (var reader = new BinaryReader(stream, Encoding.UTF8, true))
            {
                stream.Position = 40; // EMR_HEADER signature, version, byte and record counts.
                if (reader.ReadUInt32() != Signature) return false;
                reader.ReadUInt32();
                uint bytes = reader.ReadUInt32();
                uint records = reader.ReadUInt32();
                if (bytes < MinHeaderBytes + MinEndBytes || bytes > stream.Length ||
                    records < 2 || records > bytes / 8) return false;
                long offset = 0;
                for (uint index = 0; index < records && offset + 8 <= bytes; index++)
                {
                    stream.Position = offset;
                    uint type = reader.ReadUInt32();
                    uint size = reader.ReadUInt32();
                    if (size < 8 || (size & 3) != 0 || offset + size > bytes) return false;
                    if (index == 0 && (type != Header || size < MinHeaderBytes)) return false;
                    offset += size;
                    if (type == EndOfFile)
                        return size >= MinEndBytes && index + 1 == records && offset == bytes;
                }
                return false;
            }
        }
        finally { stream.Position = savedPosition; }
    }
}
