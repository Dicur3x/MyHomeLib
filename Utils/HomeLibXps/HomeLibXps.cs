// Copyright (c) 2026 MyHomeLib contributors. MIT; see ../../LICENSE.
// Render only the Windows XPS fixed-document subset, without a viewer or printer.
using System;
using System.IO;
using System.IO.Compression;
using System.IO.Packaging;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Xml;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Xps.Packaging;

internal static class HomeLibXps
{
    private const long MaxInput = 64L * 1024 * 1024, MaxTotal = 256L * 1024 * 1024;
    private const string XpsNamespace = "http://schemas.microsoft.com/xps/2005/06";
    private static readonly HashSet<string> StructureNodes = new HashSet<string>((
        "DocumentStructure DocumentStructure.Outline DocumentOutline OutlineEntry " +
        "Story StoryFragmentReference StoryFragments StoryFragment SectionStructure " +
        "ParagraphStructure FigureStructure NamedElement ListStructure ListItemStructure " +
        "TableStructure TableRowGroupStructure TableRowStructure TableCellStructure").Split(' '));
    private static readonly HashSet<string> Nodes = new HashSet<string>((
        "FixedDocumentSequence DocumentReference FixedDocument PageContent FixedPage Canvas Glyphs Path " +
        "FixedPage.Resources Canvas.Resources ResourceDictionary ResourceDictionary.MergedDictionaries " +
        "Path.Fill Path.Stroke Path.Data Path.Clip Path.RenderTransform Path.OpacityMask " +
        "Canvas.Clip Canvas.RenderTransform Canvas.OpacityMask Glyphs.Fill Glyphs.Clip Glyphs.RenderTransform Glyphs.OpacityMask " +
        "SolidColorBrush ImageBrush LinearGradientBrush RadialGradientBrush VisualBrush " +
        "ImageBrush.Transform LinearGradientBrush.Transform RadialGradientBrush.Transform VisualBrush.Transform " +
        "VisualBrush.Visual GradientStop LinearGradientBrush.GradientStops RadialGradientBrush.GradientStops " +
        "MatrixTransform PathGeometry PathGeometry.Transform PathGeometry.Figures PathFigure PathFigure.Segments " +
        "PolyLineSegment PolyBezierSegment PolyQuadraticBezierSegment ArcSegment " +
        "FixedPage.NavigateUri Canvas.NavigateUri Path.NavigateUri Glyphs.NavigateUri " +
        "FixedPage.LinkTargets LinkTarget").Split(new char[] {' '}, StringSplitOptions.RemoveEmptyEntries));

    [STAThread]
    private static int Main(string[] args)
    {
        string output = null; bool ownsOutput = false;
        try
        {
            if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("HomeLibXps 1; Windows XPS/.NET Framework"); return 0; }
            if (args.Length == 3 && args[0] == "--image-pages") return ImagePages(args[1], args[2]);
            if (args.Length != 2) throw new ArgumentException("Expected XPS and a new page ZIP.");
            string input = Path.GetFullPath(args[0]); output = Path.GetFullPath(args[1]);
            if (String.Equals(input, output, StringComparison.OrdinalIgnoreCase) || File.Exists(output)) throw new IOException("Output must be new.");
            long length = new FileInfo(input).Length;
            if (length <= 0 || length > MaxInput) throw new IOException("XPS size exceeds 64 MB or is empty.");
            Validate(input);
            using (var document = new XpsDocument(input, FileAccess.Read))
            {
                FixedDocumentSequence sequence = document.GetFixedDocumentSequence();
                if (sequence == null) throw new IOException("No fixed document sequence.");
                DocumentPaginator paginator = sequence.DocumentPaginator;
                paginator.ComputePageCount(); int count = paginator.PageCount;
                if (count <= 0 || count > 5000) throw new IOException("Invalid XPS page count.");
                using (var file = new FileStream(output, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    ownsOutput = true; long total = 0;
                    using (var archive = new ZipArchive(file, ZipArchiveMode.Create, true))
                    for (int i = 0; i < count; i++)
                    using (DocumentPage page = paginator.GetPage(i))
                    {
                        double width = page.Size.Width, height = page.Size.Height;
                        if (Double.IsNaN(width) || Double.IsNaN(height) || Double.IsInfinity(width) || Double.IsInfinity(height) ||
                            width < 1 || height < 1 || width > 100000 || height > 100000) throw new IOException("Invalid XPS page dimensions.");
                        double scale = Math.Min(2.0, 1600.0 / Math.Max(width, height));
                        int pixelsX = Math.Max(1, (int)Math.Ceiling(width * scale)), pixelsY = Math.Max(1, (int)Math.Ceiling(height * scale));
                        var visual = new DrawingVisual();
                        using (DrawingContext drawing = visual.RenderOpen())
                        {
                            drawing.DrawRectangle(Brushes.White, null, new Rect(0, 0, width, height));
                            var brush = new VisualBrush(page.Visual) { Stretch = Stretch.Fill, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top };
                            drawing.DrawRectangle(brush, null, new Rect(0, 0, width, height));
                        }
                        var bitmap = new RenderTargetBitmap(pixelsX, pixelsY, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
                        bitmap.Render(visual);
                        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                        using (var bytes = new MemoryStream())
                        {
                            encoder.Save(bytes); total += bytes.Length;
                            if (bytes.Length > 16 * 1024 * 1024 || total > MaxTotal) throw new IOException("Rendered XPS exceeds the image limit.");
                            bytes.Position = 0;
                            var entry = archive.CreateEntry((i + 1).ToString("D5") + ".png", CompressionLevel.NoCompression);
                            using (Stream destination = entry.Open()) bytes.CopyTo(destination);
                        }
                        Console.WriteLine("PAGE " + (i + 1) + " " + count); Console.Out.Flush();
                    }
                    file.Flush(true);
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            if (ownsOutput) { try { File.Delete(output); } catch { } }
            Console.Error.WriteLine("XPS: " + error.GetType().Name + ": " + error.Message); return 1;
        }
    }

    private static int ImagePages(string source, string destination)
    {
        string input = Path.GetFullPath(source), output = Path.GetFullPath(destination); bool owns = false;
        if (String.Equals(input, output, StringComparison.OrdinalIgnoreCase) || File.Exists(output)) throw new IOException("Output must be new.");
        long length = new FileInfo(input).Length;
        if (length <= 0 || length > MaxInput) throw new IOException("Image size exceeds 64 MB or is empty.");
        try
        {
            using (var stream = File.OpenRead(input))
            {
                BitmapDecoder decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
                int count = decoder.Frames.Count;
                if (count <= 0 || count > 5000) throw new IOException("Invalid image page count.");
                using (var file = new FileStream(output, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    owns = true; long total = 0;
                    using (var archive = new ZipArchive(file, ZipArchiveMode.Create, true))
                    for (int i = 0; i < count; i++)
                    {
                        BitmapFrame frame = decoder.Frames[i];
                        if (frame.PixelWidth <= 0 || frame.PixelHeight <= 0 || frame.PixelWidth > 16384 || frame.PixelHeight > 16384 ||
                            (long)frame.PixelWidth * frame.PixelHeight > 16777216) throw new IOException("Image page dimensions exceed the reader limit.");
                        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(frame));
                        using (var bytes = new MemoryStream())
                        {
                            encoder.Save(bytes); total += bytes.Length;
                            if (bytes.Length > 16 * 1024 * 1024 || total > MaxTotal) throw new IOException("Image pages exceed the reader limit.");
                            bytes.Position = 0;
                            using (Stream target = archive.CreateEntry((i+1).ToString("D5") + ".png", CompressionLevel.NoCompression).Open()) bytes.CopyTo(target);
                        }
                        Console.WriteLine("PAGE " + (i+1) + " " + count); Console.Out.Flush();
                    }
                    file.Flush(true);
                }
            }
            return 0;
        }
        catch { if (owns) { try { File.Delete(output); } catch { } } throw; }
    }

    private static void Validate(string path)
    {
        var fixedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (Package package = Package.Open(path, FileMode.Open, FileAccess.Read))
        foreach (PackagePart part in package.GetParts())
            if (part.ContentType.StartsWith("application/vnd.ms-package.xps-", StringComparison.OrdinalIgnoreCase) && part.ContentType.EndsWith("+xml", StringComparison.OrdinalIgnoreCase))
                fixedNames.Add(Uri.UnescapeDataString(part.Uri.OriginalString).TrimStart('/'));
        using (var file = File.OpenRead(path))
        using (var archive = new ZipArchive(file, ZipArchiveMode.Read))
        {
            long total = 0; var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (archive.Entries.Count > 20000) throw new IOException("Too many XPS parts.");
            foreach (var part in archive.Entries)
            {
                string name = part.FullName; total += part.Length;
                if (!names.Add(name) || name.IndexOf('\\') >= 0 || name.StartsWith("/") || name.IndexOf(':') >= 0 ||
                    Array.IndexOf(name.Split('/'), "..") >= 0 || part.Length > MaxInput || total > MaxTotal) throw new IOException("Invalid XPS package.");
                bool fixedPart = fixedNames.Contains(name) || Regex.IsMatch(name, @"\.(fpage|fdoc|fdseq|dict)$", RegexOptions.IgnoreCase);
                if (!fixedPart && !name.EndsWith(".rels", StringComparison.OrdinalIgnoreCase)) continue;
                if (part.Length > 16 * 1024 * 1024) throw new IOException("XPS XML exceeds 16 MB.");
                using (Stream bytes = part.Open())
                using (XmlReader xml = XmlReader.Create(bytes, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 16 * 1024 * 1024 }))
                {
                    int nodes = 0;
                    while (xml.Read())
                    {
                        if (++nodes > 500000 || xml.Depth > 128) throw new IOException("XPS XML is too complex.");
                        if (xml.NodeType != XmlNodeType.Element) continue;
                        if (fixedPart && !((xml.NamespaceURI == XpsNamespace && Nodes.Contains(xml.LocalName)) ||
                            (xml.NamespaceURI == XpsNamespace + "/documentstructure" && StructureNodes.Contains(xml.LocalName))))
                            throw new IOException("Unsupported XPS fixed markup: " + xml.LocalName);
                        if (!fixedPart && xml.LocalName == "Relationship" && xml.GetAttribute("TargetMode") == "External") throw new IOException("External XPS relationships are not loaded.");
                        if (xml.MoveToFirstAttribute()) do
                        {
                            string value = Uri.UnescapeDataString(xml.Value).Trim();
                            if (fixedPart && value.StartsWith("{") && !Regex.IsMatch(value, @"^\{StaticResource [^{}]+\}$|^\{ColorConvertedBitmap [^{}]+\}$"))
                                throw new IOException("Unsupported XPS markup extension.");
                            if (xml.LocalName == "Source" || xml.LocalName == "ImageSource" || xml.LocalName == "FontUri" || xml.LocalName == "ColorContext")
                            {
                                if (Regex.IsMatch(value, @"[a-zA-Z][a-zA-Z0-9+.-]*:|\\|^//")) throw new IOException("External XPS resources are not loaded.");
                            }
                            if (fixedPart && xml.NamespaceURI.Length != 0 && xml.NamespaceURI != "http://www.w3.org/XML/1998/namespace" &&
                                xml.NamespaceURI != "http://schemas.microsoft.com/winfx/2006/xaml" && xml.NamespaceURI != "http://www.w3.org/2000/xmlns/")
                                throw new IOException("Unsupported XPS attribute namespace.");
                            if (fixedPart && xml.NamespaceURI == "http://schemas.microsoft.com/winfx/2006/xaml" && xml.LocalName != "Key" && xml.LocalName != "Name")
                                throw new IOException("Unsupported XPS markup directive.");
                        } while (xml.MoveToNextAttribute());
                        xml.MoveToElement();
                    }
                }
            }
        }
    }
}
